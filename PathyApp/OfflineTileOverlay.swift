//
//  OfflineTileOverlay.swift
//  PathyApp
//

import Foundation
import MapKit

final class OfflineTileOverlay: MKTileOverlay {
    private let cacheDirectory: URL
    private let session: URLSession
    private let template = "https://tile.openstreetmap.org/{z}/{x}/{y}.png"

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
            result(data, nil)
            return
        }

        let remoteURL = url(forTilePath: path)
        let request = URLRequest(url: remoteURL, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 12)
        session.dataTask(with: request) { [weak self] data, _, error in
            if let data {
                try? self?.createParentDirectory(for: localURL)
                try? data.write(to: localURL)
                result(data, nil)
                return
            }
            result(nil, error)
        }.resume()
    }

    func prefetch(paths: [MKTileOverlayPath]) {
        for path in paths {
            let localURL = tileFileURL(path: path)
            if FileManager.default.fileExists(atPath: localURL.path) {
                continue
            }

            let request = URLRequest(url: url(forTilePath: path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            session.dataTask(with: request) { [weak self] data, _, _ in
                guard let data else { return }
                try? self?.createParentDirectory(for: localURL)
                try? data.write(to: localURL)
            }.resume()
        }
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
}
