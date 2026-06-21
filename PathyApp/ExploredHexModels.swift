//
//  ExploredHexModels.swift
//  PathyApp
//

import CoreLocation
import Foundation
import SwiftData
import SwiftyH3

@Model
final class ExploredHex {
    @Attribute(.unique) var hexId: String
    var centerLatitude: Double
    var centerLongitude: Double
    var exploredAt: Date

    init(hexId: String, centerLatitude: Double, centerLongitude: Double, exploredAt: Date = .now) {
        self.hexId = hexId
        self.centerLatitude = centerLatitude
        self.centerLongitude = centerLongitude
        self.exploredAt = exploredAt
    }
}

enum H3Indexing {
    static let resolution: H3Cell.Resolution = .res10
    static let resolutionValue = 10
    /// Approximate hex edge length at resolution 10 (~66 m per Uber H3).
    static let boundsPaddingDegrees = 0.0005

    static func isHexIdAtCurrentResolution(_ hexId: String) -> Bool {
        guard let cell = H3Cell(hexId), cell.isValid else { return false }
        return (try? cell.resolution) == resolution
    }

    static func hexId(latitude: Double, longitude: Double) -> String? {
        let latLng = H3LatLng(latitudeDegs: latitude, longitudeDegs: longitude)
        guard let cell = try? latLng.cell(at: resolution) else { return nil }
        return cell.description
    }

    static func centerCoordinate(for hexId: String) -> CLLocationCoordinate2D? {
        guard let cell = H3Cell(hexId) else { return nil }
        guard let center = try? cell.center else { return nil }
        return CLLocationCoordinate2D(latitude: center.latitudeDegs, longitude: center.longitudeDegs)
    }

    static func boundaryCoordinates(for hexId: String) -> [CLLocationCoordinate2D]? {
        guard let cell = H3Cell(hexId) else { return nil }
        guard let boundary = try? cell.boundary else { return nil }
        return boundary.map {
            CLLocationCoordinate2D(latitude: $0.latitudeDegs, longitude: $0.longitudeDegs)
        }
    }

    /// Edge segments (2 points) that border unexplored cells — for outer contour strokes only.
    static func unexploredEdgeSegments(
        for hexId: String,
        isExplored: (String) -> Bool
    ) -> [[CLLocationCoordinate2D]] {
        guard let cell = H3Cell(hexId) else { return [] }
        guard let edges = try? cell.directedEdges else { return [] }

        return edges.compactMap { edge -> [CLLocationCoordinate2D]? in
            guard let destination = try? edge.destination else { return nil }
            if isExplored(destination.description) { return nil }
            guard let boundary = try? edge.boundary, boundary.count >= 2 else { return nil }
            return boundary.map {
                CLLocationCoordinate2D(latitude: $0.latitudeDegs, longitude: $0.longitudeDegs)
            }
        }
    }
}

struct ExploredHexRenderData: Sendable {
    let hexId: String
    let boundary: [CLLocationCoordinate2D]
}

struct MapTileBounds: Sendable {
    let west: Double
    let south: Double
    let east: Double
    let north: Double

    func contains(latitude: Double, longitude: Double) -> Bool {
        latitude >= south && latitude <= north && longitude >= west && longitude <= east
    }

    func intersects(center: CLLocationCoordinate2D, boundary: [CLLocationCoordinate2D]) -> Bool {
        if contains(latitude: center.latitude, longitude: center.longitude) {
            return true
        }
        return boundary.contains { contains(latitude: $0.latitude, longitude: $0.longitude) }
    }

    static func forTile(z: Int, x: Int, y: Int) -> MapTileBounds {
        let tileCount = Double(1 << z)
        let west = Double(x) / tileCount * 360.0 - 180.0
        let east = Double(x + 1) / tileCount * 360.0 - 180.0
        let north = mercatorLatitude(forTileY: Double(y), zoom: z)
        let south = mercatorLatitude(forTileY: Double(y + 1), zoom: z)
        let padding = H3Indexing.boundsPaddingDegrees
        return MapTileBounds(
            west: west - padding,
            south: south - padding,
            east: east + padding,
            north: north + padding
        )
    }

    private static func mercatorLatitude(forTileY y: Double, zoom: Int) -> Double {
        let tileCount = Double(1 << zoom)
        let n = .pi - 2.0 * .pi * y / tileCount
        return 180.0 / .pi * atan(0.5 * (exp(n) - exp(-n)))
    }
}
