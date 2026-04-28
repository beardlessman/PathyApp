//
//  LocationTracker.swift
//  PathyApp
//

import Combine
import CoreLocation
import Foundation
import SwiftData

@MainActor
final class LocationTracker: NSObject, ObservableObject {
    @Published private(set) var isTracking = false
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var currentTrack: Track?

    private let locationManager = CLLocationManager()
    private var modelContext: ModelContext?
    private var deferredDistance: CLLocationDistance = 120
    private var deferredTimeout: TimeInterval = 120
    private var bufferedCoordinates: [TrackCoordinate] = []
    private var lastSignificantLocation: CLLocation?
    private var lastSignificantMovementAt: Date?

    private let significantMovementThreshold: CLLocationDistance = 20
    private let stationaryTimeout: TimeInterval = 30 * 60
    private let activeTrackIDKey = "activeTrackingTrackID"

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.activityType = .fitness
        locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        locationManager.distanceFilter = 7
        locationManager.pausesLocationUpdatesAutomatically = true
        locationManager.allowsBackgroundLocationUpdates = supportsBackgroundLocationMode
    }

    func attach(modelContext: ModelContext) {
        self.modelContext = modelContext
        restoreActiveTrackingIfNeeded()
    }

    func requestPermissions() {
        locationManager.requestWhenInUseAuthorization()
        if authorizationStatus == .authorizedWhenInUse {
            locationManager.requestAlwaysAuthorization()
        }
    }

    func startTracking() {
        guard let modelContext else { return }
        guard authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse else {
            requestPermissions()
            return
        }

        let track = Track(name: "Track \(Date.now.formatted(date: .abbreviated, time: .shortened))")
        modelContext.insert(track)
        currentTrack = track
        bufferedCoordinates = track.coordinates
        lastSignificantLocation = nil
        lastSignificantMovementAt = .now
        persistActiveTrackID(track.id)
        isTracking = true
        locationManager.startUpdatingLocation()
    }

    func stopTracking() {
        locationManager.stopUpdatingLocation()
        locationManager.disallowDeferredLocationUpdates()
        flushCoordinates(forceSave: true)
        currentTrack?.finishedAt = .now
        isTracking = false
        clearActiveTrackID()
        try? modelContext?.save()
    }

    private func appendLocation(_ location: CLLocation) {
        guard let modelContext, let currentTrack else { return }
        guard location.horizontalAccuracy > 0, location.horizontalAccuracy <= 100 else { return }

        bufferedCoordinates.append(
            TrackCoordinate(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                course: location.course >= 0 ? location.course : nil
            )
        )

        evaluateMovementState(with: location)

        if bufferedCoordinates.count.isMultiple(of: 25) {
            flushCoordinates()
        }
    }

    private func armDeferredUpdates() {
        guard CLLocationManager.deferredLocationUpdatesAvailable() else { return }
        locationManager.allowDeferredLocationUpdates(untilTraveled: deferredDistance, timeout: deferredTimeout)
    }

    private var supportsBackgroundLocationMode: Bool {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        return modes?.contains("location") == true
    }

    private func flushCoordinates() {
        flushCoordinates(forceSave: false)
    }

    func persistCurrentState() {
        flushCoordinates(forceSave: true)
    }

    private func flushCoordinates(forceSave: Bool) {
        guard let modelContext, let currentTrack else { return }
        currentTrack.replaceCoordinates(bufferedCoordinates)
        if forceSave || bufferedCoordinates.count.isMultiple(of: 25) {
            try? modelContext.save()
        }
    }

    private func evaluateMovementState(with location: CLLocation) {
        if lastSignificantLocation == nil {
            lastSignificantLocation = location
            lastSignificantMovementAt = location.timestamp
            return
        }

        guard let lastSignificantLocation, let lastSignificantMovementAt else { return }
        let distance = location.distance(from: lastSignificantLocation)

        if distance >= significantMovementThreshold {
            self.lastSignificantLocation = location
            self.lastSignificantMovementAt = location.timestamp
            return
        }

        if location.timestamp.timeIntervalSince(lastSignificantMovementAt) >= stationaryTimeout {
            stopTracking()
        }
    }

    private func restoreActiveTrackingIfNeeded() {
        guard let modelContext, !isTracking else { return }
        guard let idString = UserDefaults.standard.string(forKey: activeTrackIDKey),
              let trackID = UUID(uuidString: idString) else {
            return
        }

        let descriptor = FetchDescriptor<Track>(
            predicate: #Predicate<Track> { track in
                track.id == trackID
            }
        )
        guard let track = try? modelContext.fetch(descriptor).first else {
            clearActiveTrackID()
            return
        }

        if track.finishedAt != nil {
            clearActiveTrackID()
            return
        }

        currentTrack = track
        bufferedCoordinates = track.coordinates
        lastSignificantLocation = bufferedCoordinates.last.map {
            CLLocation(latitude: $0.latitude, longitude: $0.longitude)
        }
        lastSignificantMovementAt = .now
        isTracking = true
        locationManager.startUpdatingLocation()
    }

    private func persistActiveTrackID(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: activeTrackIDKey)
    }

    private func clearActiveTrackID() {
        UserDefaults.standard.removeObject(forKey: activeTrackIDKey)
    }
}

extension LocationTracker: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            authorizationStatus = manager.authorizationStatus
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            guard isTracking else { return }
            locations.forEach(appendLocation)
            armDeferredUpdates()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFinishDeferredUpdatesWithError error: Error?) {
        Task { @MainActor in
            if isTracking {
                armDeferredUpdates()
            }
        }
    }
}
