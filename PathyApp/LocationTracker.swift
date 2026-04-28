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
        isTracking = true
        locationManager.startUpdatingLocation()
    }

    func stopTracking() {
        locationManager.stopUpdatingLocation()
        locationManager.disallowDeferredLocationUpdates()
        flushCoordinates()
        currentTrack?.finishedAt = .now
        isTracking = false
        try? modelContext?.save()
    }

    private func appendLocation(_ location: CLLocation) {
        guard let modelContext, let currentTrack else { return }
        guard location.horizontalAccuracy > 0, location.horizontalAccuracy <= 100 else { return }

        bufferedCoordinates.append(
            TrackCoordinate(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude
            )
        )

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
        guard let modelContext, let currentTrack else { return }
        currentTrack.replaceCoordinates(bufferedCoordinates)
        try? modelContext.save()
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
