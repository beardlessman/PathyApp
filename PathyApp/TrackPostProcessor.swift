//
//  TrackPostProcessor.swift
//  PathyApp
//

import CoreLocation
import Foundation

struct TrackProcessingSettings: Sendable, Equatable {
    var isEnabled: Bool
    var noiseFilterEnabled: Bool
    var noiseWindowSize: Int
    var rdpEnabled: Bool
    var rdpToleranceMeters: Double
    var chaikinEnabled: Bool
    var chaikinIterations: Int

    static let defaults = TrackProcessingSettings(
        isEnabled: true,
        noiseFilterEnabled: true,
        noiseWindowSize: 33,
        rdpEnabled: true,
        rdpToleranceMeters: 5.0,
        chaikinEnabled: true,
        chaikinIterations: 1
    )
}

enum TrackProcessingSettingsStore {
    private static let enabledKey = "trackPostProcessingEnabled"
    private static let noiseEnabledKey = "trackNoiseFilterEnabled"
    private static let noiseWindowKey = "trackNoiseWindowSize"
    private static let rdpEnabledKey = "trackRDPEnabled"
    private static let rdpToleranceKey = "trackRDPToleranceMeters"
    private static let chaikinEnabledKey = "trackChaikinEnabled"
    private static let chaikinIterationsKey = "trackChaikinIterations"

    static func load() -> TrackProcessingSettings {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: enabledKey) == nil {
            return .defaults
        }
        return TrackProcessingSettings(
            isEnabled: defaults.bool(forKey: enabledKey),
            noiseFilterEnabled: defaults.object(forKey: noiseEnabledKey) == nil ? true : defaults.bool(forKey: noiseEnabledKey),
            noiseWindowSize: normalizedNoiseWindow(defaults.integer(forKey: noiseWindowKey)),
            rdpEnabled: defaults.object(forKey: rdpEnabledKey) == nil ? true : defaults.bool(forKey: rdpEnabledKey),
            rdpToleranceMeters: normalizedRDPTolerance(defaults.double(forKey: rdpToleranceKey)),
            chaikinEnabled: defaults.object(forKey: chaikinEnabledKey) == nil ? true : defaults.bool(forKey: chaikinEnabledKey),
            chaikinIterations: normalizedChaikinIterations(defaults.integer(forKey: chaikinIterationsKey))
        )
    }

    static func save(_ settings: TrackProcessingSettings) {
        let defaults = UserDefaults.standard
        defaults.set(settings.isEnabled, forKey: enabledKey)
        defaults.set(settings.noiseFilterEnabled, forKey: noiseEnabledKey)
        defaults.set(normalizedNoiseWindow(settings.noiseWindowSize), forKey: noiseWindowKey)
        defaults.set(settings.rdpEnabled, forKey: rdpEnabledKey)
        defaults.set(normalizedRDPTolerance(settings.rdpToleranceMeters), forKey: rdpToleranceKey)
        defaults.set(settings.chaikinEnabled, forKey: chaikinEnabledKey)
        defaults.set(normalizedChaikinIterations(settings.chaikinIterations), forKey: chaikinIterationsKey)
    }

    static func normalizedNoiseWindow(_ value: Int) -> Int {
        let clamped = min(max(value, 3), 51)
        return clamped % 2 == 0 ? clamped + 1 : clamped
    }

    static func normalizedRDPTolerance(_ value: Double) -> Double {
        let clamped = min(max(value, 0.5), 20.0)
        return (clamped * 2).rounded() / 2
    }

    static func normalizedChaikinIterations(_ value: Int) -> Int {
        min(max(value, 0), 3)
    }
}

/// Post-processing pipeline for recorded GPS tracks. Safe to call off the main thread.
enum TrackPostProcessor {
    static func process(_ coordinates: [TrackCoordinate], settings: TrackProcessingSettings) -> [TrackCoordinate] {
        guard settings.isEnabled, coordinates.count >= 2 else { return coordinates }

        var result = coordinates
        if settings.noiseFilterEnabled, settings.noiseWindowSize >= 3 {
            result = movingAverage(result, windowSize: settings.noiseWindowSize)
        }
        if settings.rdpEnabled, settings.rdpToleranceMeters > 0 {
            result = ramerDouglasPeucker(result, toleranceMeters: settings.rdpToleranceMeters)
        }
        if settings.chaikinEnabled, settings.chaikinIterations > 0 {
            for _ in 0..<settings.chaikinIterations {
                result = chaikinOnce(result)
            }
        }
        return result
    }

    // MARK: - Moving average

    private static func movingAverage(_ points: [TrackCoordinate], windowSize: Int) -> [TrackCoordinate] {
        guard points.count > 1 else { return points }

        let halfWindow = windowSize / 2
        var result = points
        result.reserveCapacity(points.count)

        for index in points.indices {
            let lower = max(points.startIndex, index - halfWindow)
            let upper = min(points.endIndex - 1, index + halfWindow)
            var sumLatitude = 0.0
            var sumLongitude = 0.0
            let count = upper - lower + 1
            for neighbor in lower...upper {
                sumLatitude += points[neighbor].latitude
                sumLongitude += points[neighbor].longitude
            }
            let source = points[index]
            result[index] = TrackCoordinate(
                latitude: sumLatitude / Double(count),
                longitude: sumLongitude / Double(count),
                course: source.course,
                speed: source.speed,
                horizontalAccuracy: source.horizontalAccuracy,
                timestamp: source.timestamp
            )
        }
        return result
    }

    // MARK: - RDP

    private static func ramerDouglasPeucker(_ points: [TrackCoordinate], toleranceMeters: Double) -> [TrackCoordinate] {
        guard points.count > 2 else { return points }

        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true

        var stack: [(start: Int, end: Int)] = [(0, points.count - 1)]
        while let segment = stack.popLast() {
            guard segment.end > segment.start + 1 else { continue }

            let startPoint = points[segment.start]
            let endPoint = points[segment.end]
            var maxDistance = 0.0
            var indexOfFarthest = segment.start

            for index in (segment.start + 1)..<segment.end {
                let distance = crossTrackDistanceMeters(
                    point: points[index],
                    segmentStart: startPoint,
                    segmentEnd: endPoint
                )
                if distance > maxDistance {
                    maxDistance = distance
                    indexOfFarthest = index
                }
            }

            if maxDistance > toleranceMeters {
                keep[indexOfFarthest] = true
                stack.append((segment.start, indexOfFarthest))
                stack.append((indexOfFarthest, segment.end))
            }
        }

        return points.enumerated().compactMap { index, point in
            keep[index] ? point : nil
        }
    }

    private static func crossTrackDistanceMeters(
        point: TrackCoordinate,
        segmentStart: TrackCoordinate,
        segmentEnd: TrackCoordinate
    ) -> Double {
        let start = CLLocation(latitude: segmentStart.latitude, longitude: segmentStart.longitude)
        let end = CLLocation(latitude: segmentEnd.latitude, longitude: segmentEnd.longitude)
        let sample = CLLocation(latitude: point.latitude, longitude: point.longitude)

        let segmentLength = start.distance(from: end)
        if segmentLength < 0.001 {
            return start.distance(from: sample)
        }

        let distanceStartToPoint = start.distance(from: sample)
        if distanceStartToPoint < 0.001 {
            return 0
        }

        let bearingStartToEnd = bearingRadians(from: start, to: end)
        let bearingStartToPoint = bearingRadians(from: start, to: sample)

        let angularDistanceStartToPoint = distanceStartToPoint / GeoConstants.earthRadiusMeters
        let crossTrackAngular = asin(sin(angularDistanceStartToPoint) * sin(bearingStartToPoint - bearingStartToEnd))
        let crossTrackMeters = abs(crossTrackAngular) * GeoConstants.earthRadiusMeters

        let alongTrackMeters: Double
        if abs(cos(crossTrackAngular)) < 1e-12 {
            alongTrackMeters = 0
        } else {
            alongTrackMeters = acos(cos(angularDistanceStartToPoint) / cos(crossTrackAngular)) * GeoConstants.earthRadiusMeters
        }

        if alongTrackMeters < 0 || alongTrackMeters > segmentLength {
            return min(distanceStartToPoint, end.distance(from: sample))
        }
        return crossTrackMeters
    }

    private static func bearingRadians(from start: CLLocation, to end: CLLocation) -> Double {
        let lat1 = start.coordinate.latitude * .pi / 180
        let lat2 = end.coordinate.latitude * .pi / 180
        let deltaLon = (end.coordinate.longitude - start.coordinate.longitude) * .pi / 180
        let y = sin(deltaLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon)
        return atan2(y, x)
    }

    // MARK: - Chaikin

    private static func chaikinOnce(_ points: [TrackCoordinate]) -> [TrackCoordinate] {
        guard points.count >= 3 else { return points }

        var smoothed: [TrackCoordinate] = []
        smoothed.reserveCapacity(points.count * 2)
        smoothed.append(points[0])

        for index in 0..<(points.count - 1) {
            let current = points[index]
            let next = points[index + 1]
            smoothed.append(interpolateTrackCoordinate(from: current, to: next, fraction: 0.25))
            smoothed.append(interpolateTrackCoordinate(from: current, to: next, fraction: 0.75))
        }

        smoothed.append(points[points.count - 1])
        return smoothed
    }

    private static func interpolateTrackCoordinate(
        from start: TrackCoordinate,
        to end: TrackCoordinate,
        fraction: Double
    ) -> TrackCoordinate {
        let timestamp: Date?
        if let startTime = start.timestamp, let endTime = end.timestamp {
            timestamp = startTime.addingTimeInterval(endTime.timeIntervalSince(startTime) * fraction)
        } else {
            timestamp = start.timestamp ?? end.timestamp
        }

        return TrackCoordinate(
            latitude: start.latitude + (end.latitude - start.latitude) * fraction,
            longitude: start.longitude + (end.longitude - start.longitude) * fraction,
            course: nil,
            speed: nil,
            horizontalAccuracy: nil,
            timestamp: timestamp
        )
    }
}

private enum GeoConstants {
    static let earthRadiusMeters = 6_371_000.0
}
