//
//  OfflineTileOverlay.swift
//  PathyApp
//

import Foundation
import MapKit
import UIKit

final class OfflineTileOverlay: MKTileOverlay {
    private typealias TileCompletion = (Data?, Error?) -> Void
    private let cacheDirectory: URL
    private let session: URLSession
    private let template = "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
    private let cacheSizeLimitBytes: Int64 = 400 * 1024 * 1024
    private let requestThrottleSeconds: TimeInterval = 0.35
    private let prefetchThrottleSeconds: TimeInterval = 2.0
    private let stateQueue = DispatchQueue(label: "PathyApp.OfflineTileOverlay.state")
    private var pendingPaths: [MKTileOverlayPath] = []
    private var pendingPathKeys: Set<String> = []
    private var inFlightPathKeys: Set<String> = []
    private var completionHandlers: [String: [TileCompletion]] = [:]
    private var lastDispatchAt: Date = .distantPast
    private var lastPrefetchEnqueueAt: Date = .distantPast

    override init(urlTemplate: String?) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDirectory = caches.appendingPathComponent("tile-cache", isDirectory: true)
        session = URLSession(configuration: .default)
        super.init(urlTemplate: urlTemplate)
        canReplaceMapContent = true
        minimumZ = 1
        maximumZ = 18
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        // This URL is never fetched directly by MKTileOverlay.
        URL(string: template
            .replacingOccurrences(of: "{z}", with: "\(path.z)")
            .replacingOccurrences(of: "{x}", with: "\(path.x)")
            .replacingOccurrences(of: "{y}", with: "\(path.y)"))!
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, (any Error)?) -> Void) {
        let localURL = tileFileURL(path: path)
        if let data = try? Data(contentsOf: localURL) {
            touchFile(at: localURL)
            result(data, nil)
            return
        }

        enqueue(path: path) { [weak self] data, error in
            if let data {
                result(data, nil)
            } else {
                result(nil, error)
            }
            self?.enforceCacheSizeLimitIfNeeded()
        }
    }

    func prefetch(paths: [MKTileOverlayPath]) {
        let now = Date()
        if now.timeIntervalSince(lastPrefetchEnqueueAt) < prefetchThrottleSeconds {
            return
        }
        lastPrefetchEnqueueAt = now

        for path in paths {
            let localURL = tileFileURL(path: path)
            if FileManager.default.fileExists(atPath: localURL.path) {
                touchFile(at: localURL)
                continue
            }
            enqueue(path: path, completion: nil)
        }
        enforceCacheSizeLimitIfNeeded()
    }

    func prefetchAround(coordinate: CLLocationCoordinate2D, zoomLevels: ClosedRange<Int> = 13...16, radius: Int = 1, contentScale: CGFloat = UIScreen.main.scale) {
        var paths: [MKTileOverlayPath] = []
        for zoom in zoomLevels {
            let centerX = lonToTileX(coordinate.longitude, zoom: zoom)
            let centerY = latToTileY(coordinate.latitude, zoom: zoom)
            for x in (centerX - radius)...(centerX + radius) {
                for y in (centerY - radius)...(centerY + radius) {
                    if x < 0 || y < 0 { continue }
                    paths.append(MKTileOverlayPath(x: x, y: y, z: zoom, contentScaleFactor: contentScale))
                }
            }
        }
        prefetch(paths: paths)
    }

    private func tileFileURL(path: MKTileOverlayPath) -> URL {
        cacheDirectory
            .appendingPathComponent("\(path.z)", isDirectory: true)
            .appendingPathComponent("\(path.x)", isDirectory: true)
            .appendingPathComponent("\(path.y).png")
    }

    private func createParentDirectory(for fileURL: URL) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func enqueue(path: MKTileOverlayPath, completion: TileCompletion?) {
        let key = pathKey(path)
        stateQueue.async {
            if let completion {
                self.completionHandlers[key, default: []].append(completion)
            }
            guard !self.pendingPathKeys.contains(key), !self.inFlightPathKeys.contains(key) else { return }
            self.pendingPaths.append(path)
            self.pendingPathKeys.insert(key)
            self.processQueue()
        }
    }

    private func processQueue() {
        stateQueue.async {
            guard !self.pendingPaths.isEmpty else { return }
            let now = Date()
            let delay = max(0, self.requestThrottleSeconds - now.timeIntervalSince(self.lastDispatchAt))
            self.stateQueue.asyncAfter(deadline: .now() + delay) {
                guard !self.pendingPaths.isEmpty else { return }
                let path = self.pendingPaths.removeFirst()
                let key = self.pathKey(path)
                self.pendingPathKeys.remove(key)
                self.inFlightPathKeys.insert(key)
                self.lastDispatchAt = Date()
                self.download(path: path) { data, error in
                    self.stateQueue.async {
                        self.inFlightPathKeys.remove(key)
                        let handlers = self.completionHandlers[key] ?? []
                        self.completionHandlers[key] = nil
                        handlers.forEach { $0(data, error) }
                        self.processQueue()
                    }
                }
            }
        }
    }

    private func download(path: MKTileOverlayPath, completion: @escaping (Data?, Error?) -> Void) {
        let localURL = tileFileURL(path: path)
        let request = URLRequest(url: url(forTilePath: path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        session.dataTask(with: request) { [weak self] data, _, error in
            guard let self else {
                completion(nil, error)
                return
            }
            if let data {
                try? self.createParentDirectory(for: localURL)
                try? data.write(to: localURL, options: .atomic)
                self.touchFile(at: localURL)
                completion(data, nil)
                return
            }
            completion(nil, error)
        }.resume()
    }

    private func enforceCacheSizeLimitIfNeeded() {
        stateQueue.async {
            let fileManager = FileManager.default
            guard let enumerator = fileManager.enumerator(
                at: self.cacheDirectory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { return }

            var files: [(url: URL, size: Int64, modified: Date)] = []
            var totalSize: Int64 = 0

            for case let fileURL as URL in enumerator {
                guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                      values.isRegularFile == true else { continue }
                let size = Int64(values.fileSize ?? 0)
                let modified = values.contentModificationDate ?? .distantPast
                totalSize += size
                files.append((fileURL, size, modified))
            }

            guard totalSize > self.cacheSizeLimitBytes else { return }
            let sortedByOldest = files.sorted { $0.modified < $1.modified }
            var bytesToFree = totalSize - self.cacheSizeLimitBytes

            for file in sortedByOldest where bytesToFree > 0 {
                try? fileManager.removeItem(at: file.url)
                bytesToFree -= file.size
            }
        }
    }

    private func touchFile(at url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private func pathKey(_ path: MKTileOverlayPath) -> String {
        "\(path.z)/\(path.x)/\(path.y)"
    }

    private func lonToTileX(_ lon: Double, zoom: Int) -> Int {
        Int(floor((lon + 180.0) / 360.0 * Double(1 << zoom)))
    }

    private func latToTileY(_ lat: Double, zoom: Int) -> Int {
        let rad = lat * .pi / 180
        let value = (1 - log(tan(rad) + 1 / cos(rad)) / .pi) / 2
        return Int(floor(value * Double(1 << zoom)))
    }
}
