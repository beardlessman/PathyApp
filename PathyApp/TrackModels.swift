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
    @Relationship(deleteRule: .cascade, inverse: \TrackPoint.track) var points: [TrackPoint]

    init(name: String = "New Track", startedAt: Date = .now) {
        self.id = UUID()
        self.startedAt = startedAt
        self.finishedAt = nil
        self.name = name
        self.points = []
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
