//
//  LocationTracker.swift
//  PathyApp
//

import Combine
import CoreLocation
import CoreMotion
import Foundation
import SwiftData
import UIKit
import UserNotifications

@MainActor
final class LocationTracker: NSObject, ObservableObject {
    static let shared = LocationTracker()

    @Published private(set) var isTracking = false
    @Published private(set) var isPaused = false
    @Published private(set) var isAutoStartEnabled = true
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var currentTrack: Track?
    @Published private(set) var liveTrackCoordinates: [TrackCoordinate] = []
    @Published private(set) var lastLocationSnapshot: LocationDebugSnapshot?
    @Published private(set) var lastMotionSummary = "n/a"
    @Published private(set) var debugEvents: [String] = []
    @Published private(set) var debugGeofenceActive = false
    @Published private(set) var debugRestCoordinate: CLLocationCoordinate2D?
    @Published private(set) var debugDistanceToRest: CLLocationDistance?
    @Published private(set) var debugLastSignificantMovementAt: Date?
    @Published private(set) var debugSecondsUntilAutoStop: TimeInterval?
    @Published private(set) var debugMedianHorizontalAccuracy: Double?
    @Published private(set) var debugPoorAccuracyShare: Double?
    @Published private(set) var debugDesiredAccuracy: CLLocationAccuracy = 0
    @Published private(set) var debugDistanceFilter: CLLocationDistance = 0
    @Published private(set) var debugDeferredDistance: CLLocationDistance = 0
    @Published private(set) var debugDeferredTimeout: TimeInterval = 0
    var onCoordinateRecorded: ((CLLocationCoordinate2D) -> Void)?

    private let locationManager = CLLocationManager()
    private let motionActivityManager = CMMotionActivityManager()
    private var modelContext: ModelContext?
    /// Deferred batching is disabled during active tracking to keep near-1Hz cadence.
    private var deferredDistance: CLLocationDistance = 8
    private var deferredTimeout: TimeInterval = 6
    private var bufferedCoordinates: [TrackCoordinate] = []
    private var lastSignificantLocation: CLLocation?
    private var lastSignificantMovementAt: Date?
    private var pendingAutoStartLocation: CLLocation?
    private var lastPassiveTriggerLocation: CLLocation?
    private var lastPassiveTriggerAt: Date?
    private var latestMotionActivity: CMMotionActivity?
    private var pendingDebugLocationScan = false
    private var recentHorizontalAccuracies: [Double] = []

    private let significantMovementThreshold: CLLocationDistance = 20
    private let maxWalkingAutoStartSpeed: CLLocationSpeed = 2.8
    /// Coarse wake: iOS geofence; Apple recommends ~100m minimum for reliable region events.
    private let passiveWakeGeofenceRadius: CLLocationDistance = 100
    /// Fine trigger after wake: user must move this far from rest (on quality-filtered fixes).
    private let autoStartVerificationDistanceThreshold: CLLocationDistance = 20
    /// Single-fix fast path: large separation with excellent accuracy (reduces wait for 2nd sample).
    private let autoStartStrongDistanceThreshold: CLLocationDistance = 35
    private let autoStartStrongAccuracyCap: CLLocationAccuracy = 22
    private let verificationDistanceFilter: CLLocationDistance = 10
    private let verificationMaxHorizontalAccuracy: CLLocationAccuracy = 50
    private let verificationMinGoodSamples = 2
    private let verificationPhaseTimeout: TimeInterval = 48
    private let gpsJumpDistanceThreshold: CLLocationDistance = 500
    private let gpsJumpTimeThreshold: TimeInterval = 10
    private let stationaryTimeout: TimeInterval = 15 * 60
    /// Progressive filter QA: set each to `true` to match production gates step by step.
    private let appendFilter_wallClockSkew = true
    private let appendFilter_horizontalAccuracy = true
    private let appendFilter_shouldPersist = true
    private let economyAccuracy = kCLLocationAccuracyBest
    private let activeTrackingAccuracy = kCLLocationAccuracyBestForNavigation
    private let economyDistanceFilter: CLLocationDistance = 1.6
    private let activeTrackingDistanceFilter = kCLDistanceFilterNone
    /// Minimum segment length for Bearing-based turn detection (reduces jitter from coarse fixes).
    private let bearingTurnMinDistance: CLLocationDistance = 28
    /// Degrees difference between successive movement vectors → likely fork / sharp bend.
    private let bearingTurnThresholdDegrees = 28.0
    /// If horizontal accuracy worsens abruptly, briefly request best fixes again.
    private let poorAccuracyBurstThreshold = 42.0
    private let poorAccuracyBurstDelta = 22.0
    private let highAccuracyDuration: TimeInterval = 90
    /// Ignore low-speed GPS drift when deciding whether user actually resumed moving.
    private let significantMovementMinSpeed: CLLocationSpeed = 0.6
    /// Skip near-identical fixes while user is effectively stationary.
    private let duplicateDistanceThreshold: CLLocationDistance = 3.0
    private let duplicateTimeThreshold: TimeInterval = 10
    /// Reject physically implausible jumps that usually come from bad fixes.
    private let suspiciousJumpDistanceThreshold: CLLocationDistance = 120
    private let suspiciousJumpSpeedThreshold: CLLocationSpeed = 12
    private let suspiciousJumpPoorAccuracyThreshold: CLLocationAccuracy = 20
    /// Reject cached / replayed fixes (common right after unlock) vs wall clock.
    private let maxLocationWallClockSkewSeconds: TimeInterval = 25
    /// Pocket / weak GPS: drop very poor fixes while still allowing a usable trail (ТЗ ≤ 60 m).
    private let maxHorizontalAccuracyToRecord: CLLocationAccuracy = 60
    private var lastBearingPoint: CLLocation?
    private var lastHorizontalAccuracy: CLLocationAccuracy?
    private var highAccuracyWorkItem: DispatchWorkItem?
    private var stationaryCheckTimer: Timer?
    /// Bridges inactive → background so Core Location keeps priority before the blue-indicator session fully owns execution time.
    private var resignActiveBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var endLocationHandoffBridgeWorkItem: DispatchWorkItem?
    private let activeTrackIDKey = "activeTrackingTrackID"
    private let restLatitudeKey = "restLatitude"
    private let restLongitudeKey = "restLongitude"
    private let restTimestampKey = "restTimestamp"
    private let passiveGeofenceIdentifier = "resting-geofence"
    private let didAskTrackingNotificationPermissionKey = "didAskTrackingNotificationPermission"
    private let lastAlwaysLocationEducationNotificationKey = "lastAlwaysLocationEducationNotificationAt"
    private let autoStartEnabledKey = "autoStartEnabled"
    /// Persisted alongside active track ID so restore knows whether to suppress automotive fixes.
    private let activeTrackingSessionAutoStartedKey = "activeTrackingSessionAutoStarted"

    /// True when recording was initiated by passive auto-start (not Start button); used to skip automotive segments.
    private var currentSessionStartedFromAutoTrigger = false

    /// High-accuracy GPS pass after exiting the 100m rest geofence (before committing auto-start).
    private var isAutoStartVerificationActive = false
    private var autoStartVerificationGoodSamples = 0
    private var autoStartVerificationTimeoutWorkItem: DispatchWorkItem?

    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.activityType = .fitness
        authorizationStatus = locationManager.authorizationStatus
        applyEconomyLocationConfig()
        applyBackgroundLocationPolicy()

        let defaults = UserDefaults.standard
        if defaults.object(forKey: autoStartEnabledKey) == nil {
            defaults.set(true, forKey: autoStartEnabledKey)
        }
        isAutoStartEnabled = defaults.bool(forKey: autoStartEnabledKey)

        refreshDebugConfiguration()
        logDebugEvent("tracker initialized")
        startMotionActivityUpdatesIfAvailable()
    }

    func attach(modelContext: ModelContext) {
        self.modelContext = modelContext
        restoreActiveTrackingIfNeeded()
        restorePassiveMonitoringIfNeeded()
    }

    func requestPermissions() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            locationManager.requestAlwaysAuthorization()
        case .authorizedAlways, .denied, .restricted:
            break
        @unknown default:
            break
        }
    }

    func handleDidFinishLaunching() {
        restorePassiveMonitoringIfNeeded()
    }

    func beginBackgroundBridgeForLocationHandoff() {
        guard isTracking, !isPaused else { return }
        endBackgroundBridgeForLocationHandoff()
        resignActiveBackgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "pathy.location-handoff") { [weak self] in
            Task { @MainActor in
                self?.endBackgroundBridgeForLocationHandoff()
            }
        }
    }

    func endBackgroundBridgeForLocationHandoff() {
        endLocationHandoffBridgeWorkItem?.cancel()
        endLocationHandoffBridgeWorkItem = nil
        if resignActiveBackgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(resignActiveBackgroundTaskID)
            resignActiveBackgroundTaskID = .invalid
        }
    }

    func scheduleEndBackgroundBridgeAfterLocationHandoff() {
        endLocationHandoffBridgeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.endBackgroundBridgeForLocationHandoff()
        }
        endLocationHandoffBridgeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    /// - Parameter startedFromAutoTrigger: `true` when recording began via passive auto-start (`attemptPendingAutoStart`). Manual Start uses `false`.
    func startTracking(startedFromAutoTrigger: Bool = false) {
        guard let modelContext else { return }
        cancelAutoStartVerificationIfActive(reason: "tracking started")
        guard authorizationStatus == .authorizedAlways else {
            locationManager.requestAlwaysAuthorization()
            return
        }

        currentSessionStartedFromAutoTrigger = startedFromAutoTrigger

        let track = Track(name: Date.now.formatted(date: .abbreviated, time: .shortened))
        modelContext.insert(track)
        currentTrack = track
        bufferedCoordinates = track.coordinates
        liveTrackCoordinates = bufferedCoordinates
        lastSignificantLocation = nil
        lastSignificantMovementAt = .now
        debugLastSignificantMovementAt = lastSignificantMovementAt
        updateStationaryDebugFields(now: .now)
        lastBearingPoint = nil
        lastHorizontalAccuracy = nil
        cancelHighAccuracyReset()
        applyActiveTrackingLocationConfig()
        persistActiveTrackingSession(trackID: track.id, startedFromAutoTrigger: startedFromAutoTrigger)
        locationManager.stopMonitoringSignificantLocationChanges()
        stopRestGeofenceIfNeeded()
        isTracking = true
        isPaused = false
        startStationaryTimerIfNeeded()
        locationManager.startUpdatingLocation()
        logDebugEvent("tracking started")
        ensureTrackingNotificationsPermissionIfNeeded()
        postTrackingStateNotification(isStarted: true)
    }

    func stopTracking() {
        guard isTracking else { return }

        currentSessionStartedFromAutoTrigger = false

        cancelHighAccuracyReset()
        lastHorizontalAccuracy = nil
        applyEconomyLocationConfig()
        locationManager.stopUpdatingLocation()
        locationManager.disallowDeferredLocationUpdates()
        flushCoordinates(forceSave: true)
        currentTrack?.finishedAt = .now
        isTracking = false
        isPaused = false
        stopStationaryTimer()
        liveTrackCoordinates = bufferedCoordinates
        clearActiveTrackID()
        persistRestLocationFromCurrentState()
        startPassiveMonitoringIfAuthorized()
        endBackgroundBridgeForLocationHandoff()
        runPersistenceBackgroundTask {
            try? modelContext?.save()
        }
        postTrackingStateNotification(isStarted: false)
        logDebugEvent("tracking stopped")
    }

    func pauseTracking() {
        guard isTracking, !isPaused else { return }

        isPaused = true
        stopStationaryTimer()
        cancelHighAccuracyReset()
        applyEconomyLocationConfig()
        locationManager.stopUpdatingLocation()
        locationManager.disallowDeferredLocationUpdates()
        endBackgroundBridgeForLocationHandoff()
        flushCoordinates(forceSave: true)
        logDebugEvent("tracking paused")
    }

    func resumeTracking() {
        guard isTracking, isPaused else { return }

        isPaused = false
        lastSignificantMovementAt = .now
        debugLastSignificantMovementAt = lastSignificantMovementAt
        updateStationaryDebugFields(now: .now)
        applyActiveTrackingLocationConfig()
        startStationaryTimerIfNeeded()
        locationManager.startUpdatingLocation()
        logDebugEvent("tracking resumed")
    }

    func persistCurrentState() {
        flushCoordinates(forceSave: true)
    }

    func requestDebugLocationScan() {
        guard authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse else { return }
        pendingDebugLocationScan = true
        logDebugEvent("debug location scan requested")
        locationManager.requestLocation()
    }

    func setAutoStartEnabled(_ enabled: Bool) {
        guard isAutoStartEnabled != enabled else { return }

        isAutoStartEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: autoStartEnabledKey)

        if enabled {
            restorePassiveMonitoringIfNeeded()
            attemptPendingAutoStart()
        } else {
            pendingAutoStartLocation = nil
            cancelAutoStartVerificationIfActive(reason: "auto-start disabled")
            locationManager.stopMonitoringSignificantLocationChanges()
            stopRestGeofenceIfNeeded()
        }
    }


    private func appendLocation(_ location: CLLocation) {
        guard isTracking, !isPaused else { return }
        guard let modelContext, let currentTrack else { return }

        if appendFilter_wallClockSkew {
            let wallSkew = Date().timeIntervalSince(location.timestamp)
            if wallSkew > maxLocationWallClockSkewSeconds { return }
            if wallSkew < -2 { return }
        }

        if appendFilter_horizontalAccuracy {
            guard location.horizontalAccuracy > 0, location.horizontalAccuracy <= maxHorizontalAccuracyToRecord else { return }
        }

        if appendFilter_shouldPersist {
            guard shouldPersistLocation(location) else {
                updateDebugLocationSnapshot(location, source: "active")
                updateGPSQuality(with: location.horizontalAccuracy)
                evaluateAdaptiveAccuracy(with: location)
                evaluateMovementState(with: location)
                return
            }
        }

        let storedAccuracy: Double? = location.horizontalAccuracy > 0 ? location.horizontalAccuracy : nil

        bufferedCoordinates.append(
            TrackCoordinate(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                course: location.course >= 0 ? location.course : nil,
                speed: location.speed >= 0 ? location.speed : nil,
                horizontalAccuracy: storedAccuracy,
                timestamp: location.timestamp
            )
        )
        liveTrackCoordinates = bufferedCoordinates
        onCoordinateRecorded?(location.coordinate)
        updateDebugLocationSnapshot(location, source: "active")
        if location.horizontalAccuracy > 0 {
            updateGPSQuality(with: location.horizontalAccuracy)
        }

        evaluateAdaptiveAccuracy(with: location)
        evaluateMovementState(with: location)

        if bufferedCoordinates.count.isMultiple(of: 25) {
            flushCoordinates(forceSave: false)
        }

    }

    private func shouldPersistLocation(_ location: CLLocation) -> Bool {
        if suppressNonWalkingPointForAutoTriggeredSession(at: location) {
            return false
        }

        guard let previousPoint = bufferedCoordinates.last else { return true }

        let previousTimestamp = previousPoint.timestamp ?? location.timestamp
        let dt = location.timestamp.timeIntervalSince(previousTimestamp)
        if dt <= 0 { return false }

        let previousLocation = CLLocation(latitude: previousPoint.latitude, longitude: previousPoint.longitude)
        let distance = location.distance(from: previousLocation)

        let reportedSpeed = location.speed >= 0 ? location.speed : 0
        if distance <= duplicateDistanceThreshold, dt <= duplicateTimeThreshold, reportedSpeed <= significantMovementMinSpeed {
            return false
        }

        if dt <= gpsJumpTimeThreshold, distance >= gpsJumpDistanceThreshold {
            return false
        }

        let inferredSpeed = distance / dt
        if distance >= suspiciousJumpDistanceThreshold,
           inferredSpeed >= suspiciousJumpSpeedThreshold,
           location.horizontalAccuracy >= suspiciousJumpPoorAccuracyThreshold {
            return false
        }

        if isLikelyStationaryNow() {
            let stationaryDriftDistanceThreshold = max(
                duplicateDistanceThreshold * 2,
                min(location.horizontalAccuracy * 0.8, 18)
            )
            if dt <= 20, distance <= stationaryDriftDistanceThreshold {
                return false
            }
        }

        return true
    }

    /// Auto-started sessions record only pedestrian walking (`walking` motion / walking-like GPS speed).
    /// Manual Start is unaffected (`currentSessionStartedFromAutoTrigger == false`).
    private func suppressNonWalkingPointForAutoTriggeredSession(at location: CLLocation) -> Bool {
        guard currentSessionStartedFromAutoTrigger else { return false }

        if !CMMotionActivityManager.isActivityAvailable() {
            return gpsReadsFasterThanWalkingPace(location)
        }

        guard let activity = latestMotionActivity else {
            return gpsReadsFasterThanWalkingPace(location)
        }

        if activity.confidence == .low {
            return gpsReadsFasterThanWalkingPace(location)
        }

        if activity.automotive || activity.cycling || activity.running {
            return true
        }

        if activity.walking {
            return false
        }

        return gpsReadsFasterThanWalkingPace(location)
    }

    private func gpsReadsFasterThanWalkingPace(_ location: CLLocation) -> Bool {
        guard location.speed >= 0 else { return false }
        return location.speed > maxWalkingAutoStartSpeed
    }

    private func isLikelyStationaryNow() -> Bool {
        guard let activity = latestMotionActivity else { return false }
        guard activity.confidence != .low else { return false }
        if activity.walking || activity.running || activity.cycling || activity.automotive {
            return false
        }
        return activity.stationary
    }

    private func flushCoordinates(forceSave: Bool) {
        guard let modelContext, let currentTrack else { return }
        currentTrack.replaceCoordinates(bufferedCoordinates)
        guard forceSave || bufferedCoordinates.count.isMultiple(of: 25) else { return }
        runPersistenceBackgroundTask {
            try? modelContext.save()
        }
    }

    /// Gives CoreLocation / scene teardown a few extra seconds to finish SwiftData writes when the app is not foreground-active.
    private func runPersistenceBackgroundTask(_ work: () -> Void) {
        var taskID = UIBackgroundTaskIdentifier.invalid
        taskID = UIApplication.shared.beginBackgroundTask(withName: "pathy.track-persist") {
            if taskID != .invalid {
                UIApplication.shared.endBackgroundTask(taskID)
                taskID = .invalid
            }
        }
        work()
        if taskID != .invalid {
            UIApplication.shared.endBackgroundTask(taskID)
            taskID = .invalid
        }
    }

    private func evaluateMovementState(with location: CLLocation) {
        if lastSignificantLocation == nil {
            lastSignificantLocation = location
            lastSignificantMovementAt = location.timestamp
            debugLastSignificantMovementAt = lastSignificantMovementAt
            updateStationaryDebugFields(now: location.timestamp)
            return
        }

        guard let priorSignificantLocation = lastSignificantLocation, let priorMovementAt = lastSignificantMovementAt else { return }
        let distance = location.distance(from: priorSignificantLocation)
        let dt = max(1, location.timestamp.timeIntervalSince(priorMovementAt))
        let inferredSpeed = distance / dt
        let adaptiveDistanceThreshold = max(
            significantMovementThreshold,
            max(location.horizontalAccuracy, priorSignificantLocation.horizontalAccuracy) * 2
        )

        if distance >= adaptiveDistanceThreshold && inferredSpeed >= significantMovementMinSpeed {
            // GPS drift while the user is actually still (e.g. phone on a table) can look like movement
            // and keep resetting the auto-stop clock — ignore it when Motion clearly reports stationary.
            if isLikelyStationaryNow() {
                evaluateStationaryTimeout(now: Date())
                return
            }
            lastSignificantLocation = location
            lastSignificantMovementAt = location.timestamp
            debugLastSignificantMovementAt = lastSignificantMovementAt
            updateStationaryDebugFields(now: location.timestamp)
            return
        }

        evaluateStationaryTimeout(now: Date())
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
        currentSessionStartedFromAutoTrigger = UserDefaults.standard.bool(forKey: activeTrackingSessionAutoStartedKey)

        bufferedCoordinates = track.coordinates
        liveTrackCoordinates = bufferedCoordinates
        lastSignificantLocation = bufferedCoordinates.last.map {
            CLLocation(latitude: $0.latitude, longitude: $0.longitude)
        }
        lastSignificantMovementAt = bufferedCoordinates
            .compactMap(\.timestamp)
            .max() ?? .now
        debugLastSignificantMovementAt = lastSignificantMovementAt
        updateStationaryDebugFields(now: lastSignificantMovementAt ?? .now)
        lastBearingPoint = nil
        lastHorizontalAccuracy = nil
        cancelHighAccuracyReset()
        applyActiveTrackingLocationConfig()
        isTracking = true
        isPaused = false
        startStationaryTimerIfNeeded()
        locationManager.stopMonitoringSignificantLocationChanges()
        stopRestGeofenceIfNeeded()
        locationManager.startUpdatingLocation()
        logDebugEvent("tracking restored")
    }

    private func restorePassiveMonitoringIfNeeded() {
        guard !isTracking else { return }
        startPassiveMonitoringIfAuthorized()
    }

    private func startPassiveMonitoringIfAuthorized() {
        guard isAutoStartEnabled else { return }
        guard authorizationStatus == .authorizedAlways else { return }
        locationManager.stopMonitoringSignificantLocationChanges()
        restoreRestGeofenceIfPossible()
    }

    private func restoreRestGeofenceIfPossible() {
        guard let restLocation = loadRestLocation() else { return }
        if CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) {
            createRestGeofence(center: restLocation.coordinate)
        } else {
            locationManager.startMonitoringSignificantLocationChanges()
            logDebugEvent("passive fallback: significant location (geofence unavailable)")
        }
    }

    private func createRestGeofence(center: CLLocationCoordinate2D) {
        stopRestGeofenceIfNeeded()
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }
        let region = CLCircularRegion(center: center, radius: passiveWakeGeofenceRadius, identifier: passiveGeofenceIdentifier)
        debugGeofenceActive = true
        debugRestCoordinate = center
        logDebugEvent("rest geofence armed (\(Int(passiveWakeGeofenceRadius))m wake)")
        region.notifyOnEntry = true
        region.notifyOnExit = true
        locationManager.startMonitoring(for: region)
    }

    private func stopRestGeofenceIfNeeded() {
        var stopped = false
        for region in locationManager.monitoredRegions where region.identifier == passiveGeofenceIdentifier {
            locationManager.stopMonitoring(for: region)
            stopped = true
        }
        if stopped || debugGeofenceActive {
            debugGeofenceActive = false
            logDebugEvent("rest geofence stopped")
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
        logDebugEvent("rest location persisted")
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

    private func startAutoStartVerificationPhase() {
        guard isAutoStartEnabled else { return }
        guard !isTracking else { return }
        guard authorizationStatus == .authorizedAlways else { return }
        guard modelContext != nil else {
            logDebugEvent("auto-start verification skipped: no model context")
            return
        }
        guard loadRestLocation() != nil else { return }
        guard !isAutoStartVerificationActive else { return }

        isAutoStartVerificationActive = true
        autoStartVerificationGoodSamples = 0
        lastPassiveTriggerLocation = nil
        lastPassiveTriggerAt = nil

        autoStartVerificationTimeoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.cancelAutoStartVerificationIfActive(reason: "timeout")
            }
        }
        autoStartVerificationTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + verificationPhaseTimeout, execute: work)

        applyAutoStartVerificationLocationConfig()
        locationManager.startUpdatingLocation()
        logDebugEvent("auto-start verification: high accuracy on")
    }

    private func applyAutoStartVerificationLocationConfig() {
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.distanceFilter = verificationDistanceFilter
        applyDesiredAccuracyIfNeeded(kCLLocationAccuracyBest)
        locationManager.activityType = .otherNavigation
        refreshDebugConfiguration()
    }

    private func cancelAutoStartVerificationIfActive(reason: String) {
        guard isAutoStartVerificationActive else { return }
        autoStartVerificationTimeoutWorkItem?.cancel()
        autoStartVerificationTimeoutWorkItem = nil
        isAutoStartVerificationActive = false
        autoStartVerificationGoodSamples = 0
        locationManager.stopUpdatingLocation()
        locationManager.activityType = .fitness
        applyEconomyLocationConfig()
        refreshDebugConfiguration()
        logDebugEvent("auto-start verification off (\(reason))")
    }

    private func processAutoStartVerificationUpdates(_ locations: [CLLocation]) {
        guard let restLocation = loadRestLocation() else {
            cancelAutoStartVerificationIfActive(reason: "no rest point")
            return
        }

        for location in locations {
            updateDebugLocationSnapshot(location, source: "verification")
            updateDistanceToRest(from: location)

            if let lastPassiveTriggerLocation, let lastPassiveTriggerAt {
                let jumpDistance = location.distance(from: lastPassiveTriggerLocation)
                let dt = location.timestamp.timeIntervalSince(lastPassiveTriggerAt)
                if dt > 0, dt <= gpsJumpTimeThreshold, jumpDistance >= gpsJumpDistanceThreshold {
                    logDebugEvent("auto-start verification: jump filtered")
                    continue
                }
            }
            lastPassiveTriggerLocation = location
            lastPassiveTriggerAt = location.timestamp

            let distanceFromRest = location.distance(from: restLocation)
            let accuracy = location.horizontalAccuracy
            let accuracyOKForCount = accuracy > 0 && accuracy <= verificationMaxHorizontalAccuracy
            if accuracyOKForCount {
                autoStartVerificationGoodSamples += 1
            }

            let standardPath = autoStartVerificationGoodSamples >= verificationMinGoodSamples
                && distanceFromRest > autoStartVerificationDistanceThreshold
            let strongSingletonPath = accuracyOKForCount
                && accuracy <= autoStartStrongAccuracyCap
                && distanceFromRest > autoStartStrongDistanceThreshold
                && autoStartVerificationGoodSamples >= 1

            guard standardPath || strongSingletonPath else { continue }
            guard isLikelyWalkingForAutoStart(at: location) else {
                logDebugEvent("auto-start verification: blocked not walking")
                continue
            }

            logDebugEvent("auto-start verification: confirmed (\(Int(distanceFromRest))m)")
            autoStartVerificationTimeoutWorkItem?.cancel()
            autoStartVerificationTimeoutWorkItem = nil
            isAutoStartVerificationActive = false
            autoStartVerificationGoodSamples = 0
            locationManager.stopUpdatingLocation()
            locationManager.activityType = .fitness
            applyEconomyLocationConfig()
            refreshDebugConfiguration()
            pendingAutoStartLocation = location
            attemptPendingAutoStart()
            return
        }
    }

    private func attemptPendingAutoStart() {
        guard let pendingLocation = pendingAutoStartLocation else { return }
        guard modelContext != nil else { return }
        guard isLikelyWalkingForAutoStart(at: pendingLocation) else {
            logDebugEvent("auto-start blocked: pending not walking")
            return
        }
        logDebugEvent("auto-start accepted")
        startTracking(startedFromAutoTrigger: true)
        pendingAutoStartLocation = nil
    }


    private func startStationaryTimerIfNeeded() {
        stopStationaryTimer()
        stationaryCheckTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateStationaryDebugFields(now: .now)
                self?.evaluateStationaryTimeout(now: .now)
            }
        }
    }

    private func stopStationaryTimer() {
        stationaryCheckTimer?.invalidate()
        stationaryCheckTimer = nil
    }

    private func evaluateStationaryTimeout(now: Date) {
        guard isTracking, !isPaused else { return }
        guard let lastSignificantMovementAt else { return }

        if now.timeIntervalSince(lastSignificantMovementAt) >= stationaryTimeout {
            logDebugEvent("auto-stop: stationary timeout")
            stopTracking()
        }
    }

    private var supportsBackgroundLocationMode: Bool {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        return modes?.contains("location") == true
    }

    private func applyBackgroundLocationPolicy() {
        let enabled = supportsBackgroundLocationMode
        locationManager.allowsBackgroundLocationUpdates = enabled
        if enabled {
            locationManager.showsBackgroundLocationIndicator = true
        }
    }

    private func armDeferredUpdates() {
        guard !isTracking else { return }
        guard CLLocationManager.deferredLocationUpdatesAvailable() else { return }
        locationManager.allowDeferredLocationUpdates(untilTraveled: deferredDistance, timeout: deferredTimeout)
    }

    private func startMotionActivityUpdatesIfAvailable() {
        guard CMMotionActivityManager.isActivityAvailable() else { return }

        let queue = OperationQueue()
        queue.qualityOfService = .utility
        motionActivityManager.startActivityUpdates(to: queue) { [weak self] activity in
            guard let activity else { return }
            Task { @MainActor in
                self?.latestMotionActivity = activity
                self?.lastMotionSummary = Self.describeMotionActivity(activity)
            }
        }
    }

    private func isLikelyWalkingForAutoStart(at location: CLLocation) -> Bool {
        if !CMMotionActivityManager.isActivityAvailable() {
            let speed = location.speed
            return speed >= 0 && speed <= maxWalkingAutoStartSpeed
        }

        guard let activity = latestMotionActivity else {
            let speed = location.speed
            return speed >= 0 && speed <= maxWalkingAutoStartSpeed
        }

        if activity.automotive || activity.cycling {
            return false
        }
        if activity.running {
            return false
        }
        if activity.walking {
            return activity.confidence != .low
        }

        let speed = location.speed
        return speed >= 0.2 && speed <= maxWalkingAutoStartSpeed
    }


    private func updateDebugLocationSnapshot(_ location: CLLocation, source: String) {
        updateDistanceToRest(from: location)
        lastLocationSnapshot = LocationDebugSnapshot(
            timestamp: location.timestamp,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            horizontalAccuracy: location.horizontalAccuracy,
            verticalAccuracy: location.verticalAccuracy,
            speed: location.speed,
            course: location.course,
            altitude: location.altitude,
            source: source
        )
    }

    private static func describeMotionActivity(_ activity: CMMotionActivity) -> String {
        var parts: [String] = []
        if activity.walking { parts.append("walking") }
        if activity.running { parts.append("running") }
        if activity.cycling { parts.append("cycling") }
        if activity.automotive { parts.append("automotive") }
        if activity.stationary { parts.append("stationary") }
        if parts.isEmpty { parts.append("unknown") }

        let confidence: String
        switch activity.confidence {
        case .high: confidence = "high"
        case .medium: confidence = "medium"
        default: confidence = "low"
        }

        return "\(parts.joined(separator: ", ")) [\(confidence)]"
    }

    private func updateDistanceToRest(from location: CLLocation) {
        guard let rest = loadRestLocation() else {
            debugDistanceToRest = nil
            return
        }
        debugDistanceToRest = location.distance(from: rest)
    }

    private func updateGPSQuality(with horizontalAccuracy: CLLocationAccuracy) {
        recentHorizontalAccuracies.append(horizontalAccuracy)
        if recentHorizontalAccuracies.count > 30 {
            recentHorizontalAccuracies.removeFirst(recentHorizontalAccuracies.count - 30)
        }
        let sorted = recentHorizontalAccuracies.sorted()
        if !sorted.isEmpty {
            debugMedianHorizontalAccuracy = sorted[sorted.count / 2]
            let poor = sorted.filter { $0 > 30 }.count
            debugPoorAccuracyShare = Double(poor) / Double(sorted.count)
        }
    }

    private func updateStationaryDebugFields(now: Date) {
        guard let lastSignificantMovementAt else {
            debugSecondsUntilAutoStop = nil
            return
        }
        let elapsed = now.timeIntervalSince(lastSignificantMovementAt)
        debugSecondsUntilAutoStop = max(0, stationaryTimeout - elapsed)
    }

    private func refreshDebugConfiguration() {
        debugDesiredAccuracy = locationManager.desiredAccuracy
        debugDistanceFilter = locationManager.distanceFilter
        debugDeferredDistance = deferredDistance
        debugDeferredTimeout = deferredTimeout
    }

    private func logDebugEvent(_ message: String) {
        let stamp = DateFormatter.debugEventTimestamp.string(from: .now)
        let context = eventContextString()
        let line = context.isEmpty ? "[\(stamp)] \(message)" : "[\(stamp)] \(message) | \(context)"
        debugEvents.insert(line, at: 0)
        if debugEvents.count > 80 {
            debugEvents.removeLast(debugEvents.count - 80)
        }
    }

    private func eventContextString() -> String {
        var parts: [String] = []
        parts.append("tracking=\(isTracking ? 1 : 0)")
        parts.append("paused=\(isPaused ? 1 : 0)")

        if let snapshot = lastLocationSnapshot {
            if snapshot.speed >= 0 {
                parts.append(String(format: "speed=%.2f", snapshot.speed))
            }
            parts.append(String(format: "hAcc=%.1f", snapshot.horizontalAccuracy))
        }

        if let distance = debugDistanceToRest {
            parts.append(String(format: "restDist=%.1f", distance))
        }
        if let left = debugSecondsUntilAutoStop {
            parts.append("toStop=\(Int(left.rounded()))s")
        }

        parts.append("motion=\(lastMotionSummary)")
        return parts.joined(separator: ", ")
    }

    private func persistActiveTrackingSession(trackID: UUID, startedFromAutoTrigger: Bool) {
        UserDefaults.standard.set(trackID.uuidString, forKey: activeTrackIDKey)
        UserDefaults.standard.set(startedFromAutoTrigger, forKey: activeTrackingSessionAutoStartedKey)
    }

    private func clearActiveTrackID() {
        UserDefaults.standard.removeObject(forKey: activeTrackIDKey)
        UserDefaults.standard.removeObject(forKey: activeTrackingSessionAutoStartedKey)
        currentSessionStartedFromAutoTrigger = false
    }


    private func ensureTrackingNotificationsPermissionIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: didAskTrackingNotificationPermissionKey) else { return }

        defaults.set(true, forKey: didAskTrackingNotificationPermissionKey)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Local notice when only «When In Use» is granted: background / screen-off recording needs «Always».
    private func scheduleAlwaysAccessReminderIfNeeded() {
        guard authorizationStatus == .authorizedWhenInUse else { return }

        let defaults = UserDefaults.standard
        let last = defaults.double(forKey: lastAlwaysLocationEducationNotificationKey)
        let now = Date().timeIntervalSince1970
        let minInterval: TimeInterval = 24 * 60 * 60
        guard now - last >= minInterval else { return }
        defaults.set(now, forKey: lastAlwaysLocationEducationNotificationKey)

        let deliver: () -> Void = {
            let content = UNMutableNotificationContent()
            content.title = "Нужен доступ «Всегда»"
            content.body =
                "Чтобы трек записывался в фоне и при выключенном экране, откройте Настройки → Конфиденциальность и безопасность → Службы геолокации → Pathy и выберите «Всегда»."
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1.5, repeats: false)
            let request = UNNotificationRequest(
                identifier: "pathy-always-location-education",
                content: content,
                trigger: trigger
            )
            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
        }

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                deliver()
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted {
                        deliver()
                    }
                }
            default:
                break
            }
        }
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
        debugDesiredAccuracy = accuracy
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
            if self.isTracking, !self.isPaused {
                self.applyDesiredAccuracyIfNeeded(self.activeTrackingAccuracy)
            } else {
                self.applyDesiredAccuracyIfNeeded(self.economyAccuracy)
            }
            self.highAccuracyWorkItem = nil
        }
        highAccuracyWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + highAccuracyDuration, execute: item)
    }

    private func requestHighAccuracyBurst() {
        guard isTracking else { return }
        applyDesiredAccuracyIfNeeded(activeTrackingAccuracy)
        scheduleReturnToEconomyAccuracy()
    }

    private func applyEconomyLocationConfig() {
        locationManager.pausesLocationUpdatesAutomatically = true
        locationManager.distanceFilter = economyDistanceFilter
        applyDesiredAccuracyIfNeeded(economyAccuracy)
    }

    private func applyActiveTrackingLocationConfig() {
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.distanceFilter = activeTrackingDistanceFilter
        locationManager.activityType = .fitness
        if supportsBackgroundLocationMode {
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.showsBackgroundLocationIndicator = true
        }
        applyDesiredAccuracyIfNeeded(activeTrackingAccuracy)
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

        guard location.horizontalAccuracy <= maxHorizontalAccuracyToRecord else { return }

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

private extension DateFormatter {
    static let debugEventTimestamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.dateFormat = "HH:mm:ss"
        return f
    }()
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
            if manager.authorizationStatus == .authorizedWhenInUse {
                // Background recording requires Always authorization.
                manager.requestAlwaysAuthorization()
                scheduleAlwaysAccessReminderIfNeeded()
            }
            if manager.authorizationStatus == .authorizedAlways {
                restorePassiveMonitoringIfNeeded()
                attemptPendingAutoStart()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            handleDidUpdateLocations(locations)
        }
    }

    private func handleDidUpdateLocations(_ locations: [CLLocation]) {
        if isTracking {
            guard !isPaused else { return }
            for location in locations {
                guard isTracking, !isPaused else { break }
                appendLocation(location)
            }
            if isTracking, !isPaused {
                // `Timer` often does not fire on schedule when the app is suspended; location callbacks
                // still wake the process — check wall-clock stationary timeout every batch.
                evaluateStationaryTimeout(now: Date())
                armDeferredUpdates()
            }
        } else if pendingDebugLocationScan, let latest = locations.last {
            updateDebugLocationSnapshot(latest, source: "debug")
            logDebugEvent("debug location scan success")
            pendingDebugLocationScan = false
        } else if isAutoStartVerificationActive {
            processAutoStartVerificationUpdates(locations)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard region.identifier == passiveGeofenceIdentifier else { return }
        Task { @MainActor in
            logDebugEvent("passive geofence exit → verification")
            startAutoStartVerificationPhase()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard region.identifier == passiveGeofenceIdentifier else { return }
        Task { @MainActor in
            guard isAutoStartVerificationActive else { return }
            logDebugEvent("passive geofence re-entry → cancel verification")
            cancelAutoStartVerificationIfActive(reason: "re-entered rest region")
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            if pendingDebugLocationScan {
                logDebugEvent("debug location scan failed: \((error as NSError).code)")
                pendingDebugLocationScan = false
            }
            if isAutoStartVerificationActive {
                cancelAutoStartVerificationIfActive(reason: "location error \((error as NSError).code)")
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


struct LocationDebugSnapshot {
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double
    let verticalAccuracy: Double
    let speed: Double
    let course: Double
    let altitude: Double
    let source: String
}
