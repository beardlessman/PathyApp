//
//  TrackModels.swift
//  PathyApp
//

import Foundation
import SwiftData
import CoreLocation

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
    }

    var coordinates: [TrackCoordinate] {
        TrackGeometryCodec.decode(geometryData)
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

extension Track {
    /// Approximate on-disk payload per track (geometry blob + name UTF-8). SQLite/SwiftData overhead is extra.
    var approximateStorageByteCount: Int64 {
        Int64(geometryData.count + name.utf8.count) + 96
    }
}

struct TrackCoordinate: Sendable, Hashable, Codable {
    let latitude: Double
    let longitude: Double
    let course: Double?
    let speed: Double?
    let horizontalAccuracy: Double?
    let timestamp: Date?

    init(
        latitude: Double,
        longitude: Double,
        course: Double?,
        speed: Double? = nil,
        horizontalAccuracy: Double? = nil,
        timestamp: Date? = nil
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.course = course
        self.speed = speed
        self.horizontalAccuracy = horizontalAccuracy
        self.timestamp = timestamp
    }
}

enum TrackGeometryCodec {
    private static let version1: UInt8 = 1
    private static let version2: UInt8 = 2
    private static let version3: UInt8 = 3

    static func encode(_ coordinates: [TrackCoordinate]) -> Data {
        var data = Data()
        data.reserveCapacity(1 + 4 + coordinates.count * 28)

        data.append(version3)
        var count = UInt32(coordinates.count).littleEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }

        for coordinate in coordinates {
            var lat = Int32((coordinate.latitude * 10_000_000).rounded()).littleEndian
            var lon = Int32((coordinate.longitude * 10_000_000).rounded()).littleEndian
            var course = Float((coordinate.course ?? .nan)).bitPattern.littleEndian
            var speed = Float((coordinate.speed ?? .nan)).bitPattern.littleEndian
            var hAcc = Float((coordinate.horizontalAccuracy ?? .nan)).bitPattern.littleEndian
            var timestamp = coordinate.timestamp?.timeIntervalSince1970.bitPattern.littleEndian ?? Double.nan.bitPattern.littleEndian
            withUnsafeBytes(of: &lat) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &lon) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &course) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &speed) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &hAcc) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &timestamp) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func decode(_ data: Data) -> [TrackCoordinate] {
        guard data.count >= 5 else { return [] }

        let version = data[0]
        guard version == version1 || version == version2 || version == version3 else { return [] }

        let expectedCount = Int(readUInt32(from: data, offset: 1))
        let stride: Int
        switch version {
        case version3: stride = 28
        case version2: stride = 12
        default: stride = 8
        }
        let payloadLength = expectedCount * stride
        guard data.count >= 5 + payloadLength else { return [] }

        var coordinates: [TrackCoordinate] = []
        coordinates.reserveCapacity(expectedCount)

        var cursor = 5
        for _ in 0..<expectedCount {
            let lat = Double(readInt32(from: data, offset: cursor)) / 10_000_000
            let lon = Double(readInt32(from: data, offset: cursor + 4)) / 10_000_000
            if version == version3 {
                let rawCourse = readUInt32(from: data, offset: cursor + 8)
                let rawSpeed = readUInt32(from: data, offset: cursor + 12)
                let rawHAcc = readUInt32(from: data, offset: cursor + 16)
                let rawTimestamp = readUInt64(from: data, offset: cursor + 20)

                let course = Double(Float(bitPattern: rawCourse.littleEndian))
                let speed = Double(Float(bitPattern: rawSpeed.littleEndian))
                let hAcc = Double(Float(bitPattern: rawHAcc.littleEndian))
                let timestampSeconds = Double(bitPattern: rawTimestamp.littleEndian)

                coordinates.append(
                    TrackCoordinate(
                        latitude: lat,
                        longitude: lon,
                        course: course.isFinite ? course : nil,
                        speed: speed.isFinite ? speed : nil,
                        horizontalAccuracy: hAcc.isFinite ? hAcc : nil,
                        timestamp: timestampSeconds.isFinite ? Date(timeIntervalSince1970: timestampSeconds) : nil
                    )
                )
                cursor += 28
            } else if version == version2 {
                let rawCourse = readUInt32(from: data, offset: cursor + 8)
                let course = Double(Float(bitPattern: rawCourse.littleEndian))
                let normalizedCourse = course.isFinite ? course : nil
                coordinates.append(TrackCoordinate(latitude: lat, longitude: lon, course: normalizedCourse))
                cursor += 12
            } else {
                coordinates.append(TrackCoordinate(latitude: lat, longitude: lon, course: nil))
                cursor += 8
            }
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

    private static func readUInt64(from data: Data, offset: Int) -> UInt64 {
        var value: UInt64 = 0
        _ = withUnsafeMutableBytes(of: &value) { buffer in
            data.copyBytes(to: buffer, from: offset..<(offset + 8))
        }
        return UInt64(littleEndian: value)
    }
}

extension Track {
    var distanceMeters: CLLocationDistance {
        let points = coordinates
        guard points.count > 1 else { return 0 }

        var distance: CLLocationDistance = 0
        var prev = CLLocation(latitude: points[0].latitude, longitude: points[0].longitude)
        for point in points.dropFirst() {
            let current = CLLocation(latitude: point.latitude, longitude: point.longitude)
            distance += current.distance(from: prev)
            prev = current
        }
        return distance
    }

    var duration: TimeInterval? {
        let timePoints = coordinates.compactMap(\.timestamp)
        if let minTime = timePoints.min(), let maxTime = timePoints.max(), maxTime >= minTime {
            return maxTime.timeIntervalSince(minTime)
        }
        if let finishedAt, finishedAt >= startedAt {
            return finishedAt.timeIntervalSince(startedAt)
        }
        return nil
    }

    /// Earliest GPS timestamp in the track, or `startedAt` when points have no time.
    var firstPointDate: Date {
        coordinates.compactMap(\.timestamp).min() ?? startedAt
    }
}

enum TrackNameFormatter {
    /// Leading `001_` / `008_` style prefix from export filenames.
    static func numericPrefix(in name: String) -> String? {
        guard let end = name.firstIndex(of: "_") else { return nil }
        let prefix = name[..<end]
        guard !prefix.isEmpty, prefix.allSatisfy(\.isNumber) else { return nil }
        return String(name[..<name.index(after: end)])
    }

    static func displayName(for storedName: String) -> String {
        guard let prefix = numericPrefix(in: storedName) else { return storedName }
        return String(storedName.dropFirst(prefix.count))
    }

    static func storedName(fromDisplayName displayName: String, preservingPrefixIn originalName: String) -> String {
        guard let prefix = numericPrefix(in: originalName) else { return displayName }
        return prefix + displayName
    }

    static func sortedByFirstPointDate(_ tracks: [Track]) -> [Track] {
        tracks.sorted { lhs, rhs in
            lhs.firstPointDate > rhs.firstPointDate
        }
    }

    /// Example: `12 Jun 2026 at 23-10`
    static func importedTrackName(from date: Date) -> String {
        importedTrackNameFormatter.string(from: date)
    }

    private static let importedTrackNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "dd MMM yyyy 'at' HH-mm"
        return formatter
    }()
}
