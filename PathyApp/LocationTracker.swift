//
//  LocationTracker.swift
//  PathyApp
//

import Combine
import CoreLocation
import Foundation
import SwiftData
import UserNotifications

@MainActor
final class LocationTracker: NSObject, ObservableObject {
    static let shared = LocationTracker()

    @Published private(set) var isTracking = false
    @Published private(set) var isPaused = false
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var currentTrack: Track?
    var onCoordinateRecorded: ((CLLocationCoordinate2D) -> Void)?

    private let locationManager = CLLocationManager()
    private var modelContext: ModelContext?
    private var deferredDistance: CLLocationDistance = 120
    private var deferredTimeout: TimeInterval = 120
    private var bufferedCoordinates: [TrackCoordinate] = []
    private var lastSignificantLocation: CLLocation?
    private var lastSignificantMovementAt: Date?
    private var pendingAutoStartLocation: CLLocation?
    private var lastPassiveTriggerLocation: CLLocation?
    private var lastPassiveTriggerAt: Date?

    private let significantMovementThreshold: CLLocationDistance = 20
    private let autoStartDistanceThreshold: CLLocationDistance = 200
    private let geofenceRadius: CLLocationDistance = 200
    private let gpsJumpDistanceThreshold: CLLocationDistance = 500
    private let gpsJumpTimeThreshold: TimeInterval = 10
    private let stationaryTimeout: TimeInterval = 15 * 60
    private let economyAccuracy = kCLLocationAccuracyNearestTenMeters
    /// Minimum segment length for Bearing-based turn detection (reduces jitter from coarse fixes).
    private let bearingTurnMinDistance: CLLocationDistance = 28
    /// Degrees difference between successive movement vectors → likely fork / sharp bend.
    private let bearingTurnThresholdDegrees = 28.0
    /// If horizontal accuracy worsens abruptly, briefly request best fixes again.
    private let poorAccuracyBurstThreshold = 42.0
    private let poorAccuracyBurstDelta = 22.0
    private let highAccuracyDuration: TimeInterval = 90
    private var lastBearingPoint: CLLocation?
    private var lastHorizontalAccuracy: CLLocationAccuracy?
    private var highAccuracyWorkItem: DispatchWorkItem?
    private let activeTrackIDKey = "activeTrackingTrackID"
    private let restLatitudeKey = "restLatitude"
    private let restLongitudeKey = "restLongitude"
    private let restTimestampKey = "restTimestamp"
    private let passiveGeofenceIdentifier = "resting-geofence"
    private let didAskTrackingNotificationPermissionKey = "didAskTrackingNotificationPermission"

    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.activityType = .fitness
        locationManager.desiredAccuracy = economyAccuracy
        locationManager.distanceFilter = 20
        locationManager.pausesLocationUpdatesAutomatically = true
        locationManager.allowsBackgroundLocationUpdates = supportsBackgroundLocationMode
    }

    func attach(modelContext: ModelContext) {
        self.modelContext = modelContext
        restoreActiveTrackingIfNeeded()
        restorePassiveMonitoringIfNeeded()
    }

    func requestPermissions() {
        locationManager.requestWhenInUseAuthorization()
        if authorizationStatus == .authorizedWhenInUse {
            locationManager.requestAlwaysAuthorization()
        }
    }

    func handleDidFinishLaunching() {
        restorePassiveMonitoringIfNeeded()
    }

    func startTracking() {
        guard let modelContext else { return }
        guard authorizationStatus == .authorizedAlways else {
            locationManager.requestAlwaysAuthorization()
            return
        }

        let track = Track(name: "Track \(Date.now.formatted(date: .abbreviated, time: .shortened))")
        modelContext.insert(track)
        currentTrack = track
        bufferedCoordinates = track.coordinates
        lastSignificantLocation = nil
        lastSignificantMovementAt = .now
        lastBearingPoint = nil
        lastHorizontalAccuracy = nil
        cancelHighAccuracyReset()
        applyDesiredAccuracyIfNeeded(economyAccuracy)
        persistActiveTrackID(track.id)
        locationManager.stopMonitoringSignificantLocationChanges()
        stopRestGeofenceIfNeeded()
        isTracking = true
        isPaused = false
        locationManager.startUpdatingLocation()
        ensureTrackingNotificationsPermissionIfNeeded()
        postTrackingStateNotification(isStarted: true)
    }

    func stopTracking() {
        guard isTracking else { return }

        cancelHighAccuracyReset()
        lastHorizontalAccuracy = nil
        locationManager.desiredAccuracy = economyAccuracy
        locationManager.stopUpdatingLocation()
        locationManager.disallowDeferredLocationUpdates()
        flushCoordinates(forceSave: true)
        currentTrack?.finishedAt = .now
        isTracking = false
        isPaused = false
        clearActiveTrackID()
        persistRestLocationFromCurrentState()
        startPassiveMonitoringIfAuthorized()
        try? modelContext?.save()
        postTrackingStateNotification(isStarted: false)
    }

    func pauseTracking() {
        guard isTracking, !isPaused else { return }

        isPaused = true
        cancelHighAccuracyReset()
        applyDesiredAccuracyIfNeeded(economyAccuracy)
        locationManager.stopUpdatingLocation()
        locationManager.disallowDeferredLocationUpdates()
        flushCoordinates(forceSave: true)
    }

    func resumeTracking() {
        guard isTracking, isPaused else { return }

        isPaused = false
        lastSignificantMovementAt = .now
        locationManager.startUpdatingLocation()
    }

    func persistCurrentState() {
        flushCoordinates(forceSave: true)
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
        onCoordinateRecorded?(location.coordinate)

        evaluateAdaptiveAccuracy(with: location)
        evaluateMovementState(with: location)

        if bufferedCoordinates.count.isMultiple(of: 25) {
            flushCoordinates(forceSave: false)
        }

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
        guard track.finishedAt == nil else {
            clearActiveTrackID()
            return
        }

        currentTrack = track
        bufferedCoordinates = track.coordinates
        lastSignificantLocation = bufferedCoordinates.last.map {
            CLLocation(latitude: $0.latitude, longitude: $0.longitude)
        }
        lastSignificantMovementAt = .now
        lastBearingPoint = nil
        lastHorizontalAccuracy = nil
        cancelHighAccuracyReset()
        applyDesiredAccuracyIfNeeded(economyAccuracy)
        isTracking = true
        isPaused = false
        locationManager.stopMonitoringSignificantLocationChanges()
        stopRestGeofenceIfNeeded()
        locationManager.startUpdatingLocation()
    }

    private func restorePassiveMonitoringIfNeeded() {
        guard !isTracking else { return }
        startPassiveMonitoringIfAuthorized()
    }

    private func startPassiveMonitoringIfAuthorized() {
        guard authorizationStatus == .authorizedAlways else { return }
        locationManager.startMonitoringSignificantLocationChanges()
        restoreRestGeofenceIfPossible()
    }

    private func restoreRestGeofenceIfPossible() {
        guard let restLocation = loadRestLocation() else { return }
        createRestGeofence(center: restLocation.coordinate)
    }

    private func createRestGeofence(center: CLLocationCoordinate2D) {
        stopRestGeofenceIfNeeded()
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        let region = CLCircularRegion(center: center, radius: geofenceRadius, identifier: passiveGeofenceIdentifier)
        region.notifyOnEntry = false
        region.notifyOnExit = true
        locationManager.startMonitoring(for: region)
    }

    private func stopRestGeofenceIfNeeded() {
        for region in locationManager.monitoredRegions where region.identifier == passiveGeofenceIdentifier {
            locationManager.stopMonitoring(for: region)
        }
    }

    private func persistRestLocationFromCurrentState() {
        let location: CLLocation?
        if let last = bufferedCoordinates.last {
            location = CLLocation(latitude: last.latitude, longitude: last.longitude)
        } else {
            location = locationManager.location
        }
        guard let location else { return }

        let defaults = UserDefaults.standard
        defaults.set(location.coordinate.latitude, forKey: restLatitudeKey)
        defaults.set(location.coordinate.longitude, forKey: restLongitudeKey)
        defaults.set(location.timestamp.timeIntervalSince1970, forKey: restTimestampKey)
        createRestGeofence(center: location.coordinate)
    }

    private func loadRestLocation() -> CLLocation? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: restLatitudeKey) != nil,
              defaults.object(forKey: restLongitudeKey) != nil else {
            return nil
        }
        let latitude = defaults.double(forKey: restLatitudeKey)
        let longitude = defaults.double(forKey: restLongitudeKey)
        let timestamp = defaults.double(forKey: restTimestampKey)
        let date = timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : .distantPast
        return CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: 0,
            horizontalAccuracy: 50,
            verticalAccuracy: -1,
            timestamp: date
        )
    }

    private func evaluatePassiveTrigger(with location: CLLocation) {
        guard !isTracking else { return }
        guard authorizationStatus == .authorizedAlways else { return }

        if let lastPassiveTriggerLocation, let lastPassiveTriggerAt {
            let distance = location.distance(from: lastPassiveTriggerLocation)
            let dt = location.timestamp.timeIntervalSince(lastPassiveTriggerAt)
            if dt > 0, dt <= gpsJumpTimeThreshold, distance >= gpsJumpDistanceThreshold {
                return
            }
        }
        lastPassiveTriggerLocation = location
        lastPassiveTriggerAt = location.timestamp

        guard let restLocation = loadRestLocation() else {
            pendingAutoStartLocation = location
            attemptPendingAutoStart()
            return
        }

        if location.distance(from: restLocation) >= autoStartDistanceThreshold {
            pendingAutoStartLocation = location
            attemptPendingAutoStart()
        }
    }

    private func attemptPendingAutoStart() {
        guard pendingAutoStartLocation != nil else { return }
        guard modelContext != nil else { return }
        startTracking()
        pendingAutoStartLocation = nil
    }

    private var supportsBackgroundLocationMode: Bool {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        return modes?.contains("location") == true
    }

    private func armDeferredUpdates() {
        guard CLLocationManager.deferredLocationUpdatesAvailable() else { return }
        locationManager.allowDeferredLocationUpdates(untilTraveled: deferredDistance, timeout: deferredTimeout)
    }

    private func persistActiveTrackID(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: activeTrackIDKey)
    }

    private func clearActiveTrackID() {
        UserDefaults.standard.removeObject(forKey: activeTrackIDKey)
    }


    private func ensureTrackingNotificationsPermissionIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: didAskTrackingNotificationPermissionKey) else { return }

        defaults.set(true, forKey: didAskTrackingNotificationPermissionKey)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func postTrackingStateNotification(isStarted: Bool) {
        guard !isPaused else { return }

        let content = UNMutableNotificationContent()
        content.title = isStarted ? "Трекинг начат" : "Трекинг завершён"
        content.body = isStarted
            ? "PathyApp начал записывать ваш маршрут."
            : "PathyApp остановил запись маршрута."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "tracking-state-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
    private func applyDesiredAccuracyIfNeeded(_ accuracy: CLLocationAccuracy) {
        guard abs(locationManager.desiredAccuracy - accuracy) > 0.5 else { return }
        locationManager.desiredAccuracy = accuracy
    }

    private func cancelScheduledReturnToEconomy() {
        highAccuracyWorkItem?.cancel()
        highAccuracyWorkItem = nil
    }

    private func cancelHighAccuracyReset() {
        cancelScheduledReturnToEconomy()
    }

    private func scheduleReturnToEconomyAccuracy() {
        cancelScheduledReturnToEconomy()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.applyDesiredAccuracyIfNeeded(self.economyAccuracy)
            self.highAccuracyWorkItem = nil
        }
        highAccuracyWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + highAccuracyDuration, execute: item)
    }

    private func requestHighAccuracyBurst() {
        applyDesiredAccuracyIfNeeded(kCLLocationAccuracyBest)
        scheduleReturnToEconomyAccuracy()
    }

    /// Prefer course from GPS when valid; otherwise movement vector from spaced samples.
    private func evaluateAdaptiveAccuracy(with location: CLLocation) {
        let h = location.horizontalAccuracy
        if let prev = lastHorizontalAccuracy,
           h > poorAccuracyBurstThreshold,
           h - prev >= poorAccuracyBurstDelta {
            requestHighAccuracyBurst()
        }
        lastHorizontalAccuracy = h

        guard location.horizontalAccuracy <= 65 else { return }

        if location.course >= 0, location.speed >= 0.5 {
            if let last = lastBearingPoint, last.course >= 0, last.speed >= 0.5 {
                let delta = abs(normalizedDegreesDelta(location.course, last.course))
                if delta >= bearingTurnThresholdDegrees {
                    requestHighAccuracyBurst()
                }
            }
            lastBearingPoint = location
            return
        }

        guard let anchor = lastBearingPoint ?? lastSignificantLocation else {
            lastBearingPoint = location
            return
        }
        let distance = location.distance(from: anchor)
        guard distance >= bearingTurnMinDistance else { return }

        let b1 = anchor.bearing(to: location)
        if let previous = bufferedCoordinates.dropLast().last {
            let previousLocation = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
            let segmentDistance = anchor.distance(from: previousLocation)
            if segmentDistance >= bearingTurnMinDistance {
                let b0 = previousLocation.bearing(to: anchor)
                let delta = abs(normalizedDegreesDelta(b1, b0))
                if delta >= bearingTurnThresholdDegrees {
                    requestHighAccuracyBurst()
                }
            }
        }
        lastBearingPoint = location
    }
}

private extension CLLocation {
    func bearing(to other: CLLocation) -> CLLocationDirection {
        let lat1 = coordinate.latitude * .pi / 180
        let lat2 = other.coordinate.latitude * .pi / 180
        let dLon = (other.coordinate.longitude - coordinate.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let θ = atan2(y, x)
        return θ * 180 / .pi
    }
}

private func normalizedDegreesDelta(_ a: CLLocationDirection, _ b: CLLocationDirection) -> CLLocationDirection {
    var d = a - b
    while d > 180 { d -= 360 }
    while d < -180 { d += 360 }
    return d
}

extension LocationTracker: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            authorizationStatus = manager.authorizationStatus
            if manager.authorizationStatus == .authorizedAlways {
                restorePassiveMonitoringIfNeeded()
                attemptPendingAutoStart()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            if isTracking {
                guard !isPaused else { return }
                locations.forEach(appendLocation)
                armDeferredUpdates()
            } else if let latest = locations.last {
                evaluatePassiveTrigger(with: latest)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier == passiveGeofenceIdentifier else { return }
        Task { @MainActor in
            if let location = manager.location {
                evaluatePassiveTrigger(with: location)
            } else if let restLocation = loadRestLocation() {
                evaluatePassiveTrigger(with: restLocation)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFinishDeferredUpdatesWithError error: Error?) {
        Task { @MainActor in
            if isTracking, !isPaused {
                armDeferredUpdates()
            }
        }
    }
}
