//
//  TrackModels.swift
//  PathyApp
//

import CoreLocation
import Foundation
import SwiftData

@Model
final class Track {
    var id: UUID
    var startedAt: Date
    var finishedAt: Date?
    var name: String
    var pointCount: Int
    var geometryData: Data
    var minLatitude: Double
    var maxLatitude: Double
    var minLongitude: Double
    var maxLongitude: Double

    // Legacy relation kept for compatibility with older local data.
    @Relationship(deleteRule: .cascade, inverse: \TrackPoint.track) var points: [TrackPoint]

    init(name: String = "New Track", startedAt: Date = .now) {
        self.id = UUID()
        self.startedAt = startedAt
        self.finishedAt = nil
        self.name = name
        self.pointCount = 0
        self.geometryData = Data()
        self.minLatitude = 0
        self.maxLatitude = 0
        self.minLongitude = 0
        self.maxLongitude = 0
        self.points = []
    }

    var coordinates: [TrackCoordinate] {
        if !geometryData.isEmpty {
            return TrackGeometryCodec.decode(geometryData)
        }
        return points
            .sorted(by: { $0.timestamp < $1.timestamp })
            .map { TrackCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
    }

    func replaceCoordinates(_ coordinates: [TrackCoordinate]) {
        geometryData = TrackGeometryCodec.encode(coordinates)
        pointCount = coordinates.count

        guard let first = coordinates.first else {
            minLatitude = 0
            maxLatitude = 0
            minLongitude = 0
            maxLongitude = 0
            return
        }

        var minLat = first.latitude
        var maxLat = first.latitude
        var minLon = first.longitude
        var maxLon = first.longitude

        for coordinate in coordinates.dropFirst() {
            minLat = min(minLat, coordinate.latitude)
            maxLat = max(maxLat, coordinate.latitude)
            minLon = min(minLon, coordinate.longitude)
            maxLon = max(maxLon, coordinate.longitude)
        }

        minLatitude = minLat
        maxLatitude = maxLat
        minLongitude = minLon
        maxLongitude = maxLon
    }
}

struct TrackCoordinate: Sendable, Hashable, Codable {
    let latitude: Double
    let longitude: Double
}

enum TrackGeometryCodec {
    private static let version: UInt8 = 1

    static func encode(_ coordinates: [TrackCoordinate]) -> Data {
        var data = Data()
        data.reserveCapacity(1 + 4 + coordinates.count * 8)

        data.append(version)
        var count = UInt32(coordinates.count).littleEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }

        for coordinate in coordinates {
            var lat = Int32((coordinate.latitude * 10_000_000).rounded()).littleEndian
            var lon = Int32((coordinate.longitude * 10_000_000).rounded()).littleEndian
            withUnsafeBytes(of: &lat) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &lon) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func decode(_ data: Data) -> [TrackCoordinate] {
        guard data.count >= 5 else { return [] }
        guard data[0] == version else { return [] }

        let expectedCount = Int(readUInt32(from: data, offset: 1))
        let payloadLength = expectedCount * 8
        guard data.count >= 5 + payloadLength else { return [] }

        var coordinates: [TrackCoordinate] = []
        coordinates.reserveCapacity(expectedCount)

        var cursor = 5
        for _ in 0..<expectedCount {
            let lat = Double(readInt32(from: data, offset: cursor)) / 10_000_000
            let lon = Double(readInt32(from: data, offset: cursor + 4)) / 10_000_000
            coordinates.append(TrackCoordinate(latitude: lat, longitude: lon))
            cursor += 8
        }
        return coordinates
    }

    private static func readUInt32(from data: Data, offset: Int) -> UInt32 {
        var value: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &value) { buffer in
            data.copyBytes(to: buffer, from: offset..<(offset + 4))
        }
        return UInt32(littleEndian: value)
    }

    private static func readInt32(from data: Data, offset: Int) -> Int32 {
        var value: Int32 = 0
        _ = withUnsafeMutableBytes(of: &value) { buffer in
            data.copyBytes(to: buffer, from: offset..<(offset + 4))
        }
        return Int32(littleEndian: value)
    }
}

@Model
final class TrackPoint {
    var timestamp: Date
    var latitude: Double
    var longitude: Double
    var altitude: Double
    var horizontalAccuracy: Double
    var speed: Double
    var course: Double
    var track: Track?

    init(
        timestamp: Date,
        latitude: Double,
        longitude: Double,
        altitude: Double,
        horizontalAccuracy: Double,
        speed: Double,
        course: Double,
        track: Track?
    ) {
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.speed = speed
        self.course = course
        self.track = track
    }

    init(location: CLLocation, track: Track?) {
        self.timestamp = location.timestamp
        self.latitude = location.coordinate.latitude
        self.longitude = location.coordinate.longitude
        self.altitude = location.altitude
        self.horizontalAccuracy = location.horizontalAccuracy
        self.speed = location.speed
        self.course = location.course
        self.track = track
    }
}
