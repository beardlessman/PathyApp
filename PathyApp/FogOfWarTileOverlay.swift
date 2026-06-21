//
//  FogOfWarTileOverlay.swift
//  PathyApp
//

import CoreLocation
import MapKit
import UIKit

final class FogOfWarTileOverlay: MKTileOverlay {
    private typealias TileCompletion = (Data?, (any Error)?) -> Void

    private let lock = NSLock()
    private var exploredHexProvider: (@Sendable (MapTileBounds) -> [ExploredHexRenderData])?
    private var contentRevision = 0
    private weak var tileRenderer: MKTileOverlayRenderer?

    private let tileCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 256
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    private var inFlightKeys: Set<String> = []
    private var pendingCompletions: [String: [TileCompletion]] = [:]
    private let renderQueue = DispatchQueue(
        label: "pathy.fog-tile-render",
        qos: .userInteractive,
        attributes: .concurrent
    )

    override init(urlTemplate: String?) {
        super.init(urlTemplate: nil)
        canReplaceMapContent = false
        minimumZ = 1
        maximumZ = 19
    }

    func attach(renderer: MKTileOverlayRenderer) {
        lock.lock()
        tileRenderer = renderer
        lock.unlock()
    }

    func setExploredHexProvider(_ provider: @escaping @Sendable (MapTileBounds) -> [ExploredHexRenderData]) {
        lock.lock()
        exploredHexProvider = provider
        lock.unlock()
    }

    func setExploredHexLookup(_ lookup: @escaping @Sendable (String) -> Bool) {
        // Kept for API compatibility; border/cutout paths no longer need neighbor lookup.
        _ = lookup
    }

    func purgeCache() {
        lock.lock()
        tileCache.removeAllObjects()
        inFlightKeys.removeAll()
        pendingCompletions.removeAll()
        lock.unlock()
    }

    func setContentRevision(_ revision: Int) {
        lock.lock()
        guard contentRevision != revision else {
            lock.unlock()
            return
        }
        contentRevision = revision
        tileCache.removeAllObjects()
        let renderer = tileRenderer
        lock.unlock()

        DispatchQueue.main.async {
            renderer?.setNeedsDisplay()
        }
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, (any Error)?) -> Void) {
        lock.lock()
        let cacheKey = tileCacheKey(revision: contentRevision, path: path)
        if let cached = tileCache.object(forKey: cacheKey) {
            lock.unlock()
            result(cached as Data, nil)
            return
        }
        lock.unlock()

        enqueueRender(for: path, cacheKey: cacheKey, result: result)
    }

    private func enqueueRender(
        for path: MKTileOverlayPath,
        cacheKey: NSString,
        result: @escaping TileCompletion
    ) {
        var shouldStartRender = false

        lock.lock()
        if inFlightKeys.contains(cacheKey as String) {
            pendingCompletions[cacheKey as String, default: []].append(result)
            lock.unlock()
            return
        }

        inFlightKeys.insert(cacheKey as String)
        pendingCompletions[cacheKey as String] = [result]
        let provider = exploredHexProvider
        let revision = contentRevision
        shouldStartRender = true
        lock.unlock()

        guard shouldStartRender else { return }

        renderQueue.async {
            let bounds = MapTileBounds.forTile(z: path.z, x: path.x, y: path.y)
            let exploredHexes = provider?(bounds) ?? []
            let pngData = FogTileRenderer.renderTile(
                z: path.z,
                x: path.x,
                y: path.y,
                contentScaleFactor: path.contentScaleFactor,
                exploredHexes: exploredHexes
            )

            let completions: [TileCompletion]
            self.lock.lock()
            self.inFlightKeys.remove(cacheKey as String)
            completions = self.pendingCompletions.removeValue(forKey: cacheKey as String) ?? []

            if let pngData, self.contentRevision == revision {
                self.tileCache.setObject(
                    pngData as NSData,
                    forKey: cacheKey,
                    cost: pngData.count
                )
            }
            self.lock.unlock()

            for completion in completions {
                completion(pngData, nil)
            }
        }
    }

    private func tileCacheKey(revision: Int, path: MKTileOverlayPath) -> NSString {
        "\(revision)/\(path.z)/\(path.x)/\(path.y)" as NSString
    }
}

private enum FogTileRenderer {
    private static let tileSize = 256
    private static let fogColor = UIColor(white: 0.15, alpha: 0.75)
    private static let borderColor = UIColor.black.withAlphaComponent(0.6)

    static func renderTile(
        z: Int,
        x: Int,
        y: Int,
        contentScaleFactor: CGFloat,
        exploredHexes: [ExploredHexRenderData]
    ) -> Data? {
        let borderLineWidth = 1.0 / max(contentScaleFactor, 1.0)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: tileSize, height: tileSize),
            format: format
        )

        let tileRect = CGRect(x: 0, y: 0, width: tileSize, height: tileSize)
        let hexPaths = exploredHexes.map { exploredHex in
            let vertices = exploredHex.boundary.map {
                pixelPoint(latitude: $0.latitude, longitude: $0.longitude, z: z, x: x, y: y)
            }
            return roundedHexPath(vertices: vertices, cornerRadiusPercent: 0.2)
        }

        let image = renderer.image { context in
            let cgContext = context.cgContext
            cgContext.setAllowsAntialiasing(true)
            cgContext.setShouldAntialias(true)
            cgContext.interpolationQuality = .high

            if hexPaths.isEmpty {
                cgContext.setFillColor(fogColor.cgColor)
                cgContext.fill(tileRect)
                return
            }

            // even-odd mask — fog on tile, rounded-hex holes.
            let fogMaskPath = UIBezierPath(rect: tileRect)
            for hexPath in hexPaths {
                fogMaskPath.append(hexPath)
            }
            fogMaskPath.usesEvenOddFillRule = true
            cgContext.setFillColor(fogColor.cgColor)
            cgContext.addPath(fogMaskPath.cgPath)
            cgContext.fillPath(using: .evenOdd)

            cgContext.saveGState()
            cgContext.setBlendMode(.normal)
            cgContext.setStrokeColor(borderColor.cgColor)
            cgContext.setLineWidth(borderLineWidth)
            cgContext.setLineCap(.round)
            cgContext.setLineJoin(.round)

            for hexPath in hexPaths {
                cgContext.addPath(hexPath.cgPath)
            }
            cgContext.strokePath()
            cgContext.restoreGState()
        }
        return image.pngData()
    }

    /// Straight edges with cubic Bézier corners; `k` caps at 0.5 so the polygon cannot become a circle.
    private static func roundedHexPath(
        vertices: [CGPoint],
        cornerRadiusPercent: CGFloat
    ) -> UIBezierPath {
        let path = UIBezierPath()
        let sides = vertices.count
        guard sides >= 3 else { return path }

        let k = max(0, min(0.5, cornerRadiusPercent))

        for index in 0..<sides {
            let current = vertices[index]
            let next = vertices[(index + 1) % sides]
            let previous = vertices[(index - 1 + sides) % sides]

            let startPoint = CGPoint(
                x: current.x + (previous.x - current.x) * k,
                y: current.y + (previous.y - current.y) * k
            )
            let endPoint = CGPoint(
                x: current.x + (next.x - current.x) * k,
                y: current.y + (next.y - current.y) * k
            )

            if index == 0 {
                path.move(to: startPoint)
            } else {
                path.addLine(to: startPoint)
            }

            path.addCurve(to: endPoint, controlPoint1: current, controlPoint2: current)
        }

        path.close()
        return path
    }

    private static func pixelPoint(
        latitude: Double,
        longitude: Double,
        z: Int,
        x: Int,
        y: Int
    ) -> CGPoint {
        let worldSize = Double(tileSize) * pow(2.0, Double(z))
        let pixelX = (longitude + 180.0) / 360.0 * worldSize
        let sinLatitude = sin(latitude * .pi / 180.0)
        let pixelY = (0.5 - log((1.0 + sinLatitude) / (1.0 - sinLatitude)) / (4.0 * .pi)) * worldSize
        return CGPoint(
            x: pixelX - Double(x * tileSize),
            y: pixelY - Double(y * tileSize)
        )
    }
}
