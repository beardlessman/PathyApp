//
//  ContentView.swift
//  PathyApp
//
//  Created by Dmitrii Mungalov on 28.04.2026.
//

import Combine
import MapKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var tracker: LocationTracker
    @StateObject private var exploredHexStore = ExploredHexStore()
    @State private var tracks: [Track] = []

    @State private var trackDisplayStates: [UUID: TrackDisplayState] = [:]
    @State private var knownTrackIDs: Set<UUID> = []
    @State private var mapView: MKMapView?
    @State private var tileOverlay: OfflineTileOverlay?
    @State private var isImporting = false
    @State private var isImportingTrack = false
    @State private var isDeletingTracks = false
    @State private var postProcessingTrackID: UUID?
    @State private var exportedURL: URL?
    @State private var exportError: String?
    @State private var editingTrackID: UUID?
    @State private var editingTrackName = ""
    @State private var isMapExpanded = false
    @State private var shouldFollowUserOnMap = true
    @State private var showTracksScreen = false

    private var isBusy: Bool {
        isImportingTrack || isDeletingTracks || postProcessingTrackID != nil || tracker.isPostProcessingTrack
    }

    private var isProcessingTrack: Bool {
        postProcessingTrackID != nil || tracker.isPostProcessingTrack
    }

    private var displayedTrackRoutes: [TrackMapView.Route] {
        if tracker.isTracking {
            return [
                .init(
                    id: "live",
                    coordinates: tracker.liveTrackCoordinates,
                    strokeColor: .systemBlue
                )
            ]
        }
        return tracks.compactMap { track in
            let state = trackDisplayStates[track.id] ?? .normal
            guard state != .hidden else { return nil }
            return TrackMapView.Route(
                id: track.id.uuidString,
                coordinates: track.coordinates,
                strokeColor: state == .highlighted ? .systemOrange : .systemBlue
            )
        }
    }

    private var highlightedRouteIDs: Set<String> {
        Set(
            tracks.compactMap { track in
                (trackDisplayStates[track.id] ?? .normal) == .highlighted ? track.id.uuidString : nil
            }
        )
    }

    private var focusedRouteID: String? {
        guard !tracker.isTracking else { return nil }
        return tracks.first(where: { (trackDisplayStates[$0.id] ?? .normal) == .highlighted })?.id.uuidString
    }

    private var highlightedTrackCount: Int {
        tracks.reduce(0) { partialResult, track in
            partialResult + ((trackDisplayStates[track.id] ?? .normal) == .highlighted ? 1 : 0)
        }
    }

    /// Sum of persisted track payloads (blob + metadata estimate); excludes SwiftData bookkeeping.
    private var approximateSavedTracksTotalBytes: Int64 {
        tracks.reduce(Int64(0)) { $0 + $1.approximateStorageByteCount }
    }

    /// Map and floating buttons. Expanded mode hides the nav bar and ignores safe-area insets behind the MKMapView.
    @ViewBuilder
    private var mapAndControlsSection: some View {
        ZStack {
            TrackMapView(
                routes: displayedTrackRoutes,
                highlightedRouteIDs: highlightedRouteIDs,
                focusedRouteID: focusedRouteID,
                followUserLocation: tracker.isTracking && shouldFollowUserOnMap
            ) { map, overlay in
                mapView = map
                tileOverlay = overlay
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: isMapExpanded ? 0 : 12))
            .modifier(ExpandedMapIgnoresSafeArea(isExpanded: isMapExpanded))

            VStack(spacing: 10) {
                if isMapExpanded {
                    Button {
                        shouldFollowUserOnMap = true
                        centerMapOnUserLocation()
                    } label: {
                        Image(systemName: "location.fill")
                            .frame(width: 42, height: 42)
                    }
                }

                if isMapExpanded {
                    Button {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            isMapExpanded = false
                        }
                    } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .frame(width: 42, height: 42)
                    }
                } else {
                    Button {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            isMapExpanded = true
                        }
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .frame(width: 42, height: 42)
                    }
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .background(Color.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Tracking controls and track list — only visible when map is not expanded.
    @ViewBuilder
    private var collapsedMapChrome: some View {
        HStack(spacing: 16) {
            Button(tracker.isTracking ? "Stop" : "Start") {
                if tracker.isTracking {
                    tracker.stopTracking()
                    shouldFollowUserOnMap = true
                    if let currentTrack = tracker.currentTrack {
                        upsertLocalTrack(currentTrack)
                    }
                    refreshTracks()
                } else {
                    tracker.startTracking()
                    shouldFollowUserOnMap = true
                    if let currentTrack = tracker.currentTrack {
                        upsertLocalTrack(currentTrack)
                    }
                }
                syncSelectionWithTracks()
            }
            .buttonStyle(.borderedProminent)
            .tint(tracker.isTracking ? Color.red : Color.green)
            .controlSize(.large)
            .font(.title3.weight(.semibold))
            .frame(minHeight: 48)

            if tracker.isTracking {
                Button(tracker.isPaused ? "Resume" : "Pause") {
                    if tracker.isPaused {
                        tracker.resumeTracking()
                    } else {
                        tracker.pauseTracking()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .font(.title3.weight(.semibold))
                .frame(minHeight: 48)
            }
        }

        List {
            ForEach(tracks) { track in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        if editingTrackID == track.id {
                            TextField("Track name", text: $editingTrackName)
                                .textFieldStyle(.roundedBorder)
                                .font(.headline)
                                .onSubmit {
                                    commitTrackNameEdit(for: track)
                                }
                                .onDisappear {
                                    if editingTrackID == track.id {
                                        commitTrackNameEdit(for: track)
                                    }
                                }
                        } else {
                            Text(TrackNameFormatter.displayName(for: track.name))
                                .font(.headline)
                                .foregroundStyle(nameColor(for: track))
                                .onTapGesture {
                                    cycleDisplayState(for: track)
                                }
                                .onLongPressGesture(minimumDuration: 0.4) {
                                    beginTrackNameEdit(for: track)
                                }
                        }

                        Text(trackSummary(track))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if editingTrackID == track.id {
                        commitTrackNameEdit(for: track)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        deleteTrack(track)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }

                    Button {
                        postProcessTrack(track)
                    } label: {
                        Label("Process", systemImage: "bolt.fill")
                    }
                    .tint(.orange)
                    .disabled(postProcessingTrackID != nil || track.coordinates.count < 2)
                }
            }
        }
        .frame(height: 180)
        .disabled(isBusy)
        .overlay(alignment: .topLeading) {
            if highlightedTrackCount > 1 {
                Button("Deselect all") {
                    deselectAllHighlightedTracks()
                }
                .font(.footnote)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.top, 5)
                .padding(.leading, 12)
            }
        }
    }

    @ViewBuilder
    private var mainTracksView: some View {
        VStack(spacing: isMapExpanded ? 0 : 12) {
            mapAndControlsSection
                .frame(maxHeight: .infinity)

            if !isMapExpanded {
                collapsedMapChrome
            }
        }
        .padding(isMapExpanded ? 0 : 16)
        .navigationTitle("Pathy")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SettingsView(
                        tracker: tracker,
                        isAutoStartEnabled: tracker.isAutoStartEnabled,
                        setAutoStartEnabled: { tracker.setAutoStartEnabled($0) },
                        onImportGPX: { isImporting = true },
                        onExportGPX: exportAllTracks,
                        canExportGPX: !tracks.isEmpty,
                        isBusy: isBusy,
                        savedTracksApproximateByteCount: approximateSavedTracksTotalBytes,
                        onDeleteAllTracks: deleteAllTracks,
                        canBulkDeleteAllTracks: !tracks.isEmpty && !tracker.isTracking,
                        trackingBlocksBulkDeleteAll: tracker.isTracking && !tracks.isEmpty
                    )
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
        .toolbar(isMapExpanded ? .hidden : .automatic, for: .navigationBar)
    }

    var body: some View {
        NavigationStack {
            DiscoveryMapScreen(
                exploredHexStore: exploredHexStore,
                initialRegion: nil,
                onOpenTracks: { showTracksScreen = true }
            )
            .navigationDestination(isPresented: $showTracksScreen) {
                mainTracksView
            }
            .toolbar(.hidden, for: .navigationBar)
        }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.xml, .gpx],
                allowsMultipleSelection: true
            ) { result in
                if case let .success(urls) = result, !urls.isEmpty {
                    importTracks(urls: urls)
                }
            }
            .sheet(isPresented: Binding(
                get: { exportedURL != nil },
                set: { if !$0 { exportedURL = nil } }
            )) {
                if let exportedURL {
                    ShareSheet(items: [exportedURL])
                }
            }
            .alert("Operation Error", isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            ), actions: {
                Button("OK") { exportError = nil }
            }, message: {
                Text(exportError ?? "")
            })
            .onAppear {
                tracker.attach(modelContext: modelContext)
                exploredHexStore.attach(modelContext: modelContext)
                tracker.requestPermissions()
                tracker.onCoordinateRecorded = { coordinate in
                    autoCacheAroundTrackingCoordinate(coordinate)
                    exploredHexStore.indexCoordinate(coordinate, throttle: true)
                }
                refreshTracks()
                exploredHexStore.backfillFromTracksIfNeeded()
                syncSelectionWithTracks()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase != .active {
                    tracker.persistCurrentState()
                    refreshTracks()
                }
            }
            .onChange(of: tracker.isTracking) { wasTracking, isTracking in
                guard wasTracking, !isTracking else { return }
                exploredHexStore.indexCoordinates(tracker.liveTrackCoordinates)
            }
            .onChange(of: tracker.isPostProcessingTrack) { _, isProcessing in
                guard !isProcessing else { return }
                if let currentTrack = tracker.currentTrack {
                    upsertLocalTrack(currentTrack)
                    exploredHexStore.indexCoordinates(currentTrack.coordinates)
                }
                refreshTracks()
            }
            .animation(nil, value: isMapExpanded)
            .overlay {
                if isBusy {
                    ZStack {
                        Color.black.opacity(0.2).ignoresSafeArea()
                        ProgressView(
                            isProcessingTrack
                                ? "Processing track..."
                                : (isDeletingTracks ? "Deleting track..." : "Importing GPX...")
                        )
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
    }

    private func importTracks(urls: [URL]) {
        isImportingTrack = true
        Task { @MainActor in
            defer { isImportingTrack = false }

            var scopedURLs: [URL] = []
            for url in urls {
                if url.startAccessingSecurityScopedResource() {
                    scopedURLs.append(url)
                }
            }
            defer {
                for url in scopedURLs {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let imported = try GPXService.importTracks(from: urls, modelContext: modelContext)
                for track in imported {
                    upsertLocalTrack(track)
                    exploredHexStore.indexCoordinates(track.coordinates)
                }
                refreshTracks()
                syncSelectionWithTracks()
            } catch let batchError as GPXBatchImportError {
                for track in batchError.partiallyImported {
                    upsertLocalTrack(track)
                    exploredHexStore.indexCoordinates(track.coordinates)
                }
                refreshTracks()
                syncSelectionWithTracks()
                exportError = batchError.localizedDescription
            } catch {
                exportError = "Unable to import GPX: \(error.localizedDescription)"
            }
        }
    }

    private func autoCacheAroundTrackingCoordinate(_ coordinate: CLLocationCoordinate2D) {
        guard tracker.isTracking else { return }
        tileOverlay?.prefetchAround(coordinate: coordinate, zoomLevels: 13...16, radius: 1)
    }

    private func exportAllTracks() {
        let highlightedTracks = tracks.filter { (trackDisplayStates[$0.id] ?? .normal) == .highlighted }
        let tracksToExport = highlightedTracks.isEmpty ? tracks : highlightedTracks
        do {
            exportedURL = try GPXService.exportAllAsZip(tracks: tracksToExport)
        } catch {
            exportError = "Unable to export GPX: \(error.localizedDescription)"
        }
    }

    private func deleteAllTracks() {
        guard !tracks.isEmpty else { return }
        isDeletingTracks = true
        Task { @MainActor in
            defer { isDeletingTracks = false }
            do {
                try deleteAllTracksFromDatabase()
            } catch {
                exportError = "Unable to delete tracks: \(error.localizedDescription)"
            }
        }
    }

    private func deleteAllTracksFromDatabase() throws {
        let descriptor = FetchDescriptor<Track>()
        let all = try modelContext.fetch(descriptor)
        for track in all {
            modelContext.delete(track)
        }
        try modelContext.save()
        refreshTracks()
        syncSelectionWithTracks()
    }

    private func deleteTrack(_ track: Track) {
        isDeletingTracks = true
        Task { @MainActor in
            defer { isDeletingTracks = false }
            do {
                trackDisplayStates.removeValue(forKey: track.id)
                knownTrackIDs.remove(track.id)
                modelContext.delete(track)
                try modelContext.save()
                tracks.removeAll { $0.id == track.id }
                refreshTracks()
                syncSelectionWithTracks()
            } catch {
                exportError = "Unable to delete track: \(error.localizedDescription)"
            }
        }
    }

    private func postProcessTrack(_ track: Track) {
        guard postProcessingTrackID == nil else { return }
        let rawCoordinates = track.coordinates
        guard rawCoordinates.count >= 2 else {
            exportError = "Track has too few points to process."
            return
        }

        postProcessingTrackID = track.id
        Task { @MainActor in
            defer { postProcessingTrackID = nil }
            let rawCount = rawCoordinates.count
            let processed = await Task.detached(priority: .userInitiated) {
                TrackPostProcessor.processWithStoredSettings(rawCoordinates, forceEnabled: true)
            }.value

            track.replaceCoordinates(processed)
            do {
                try modelContext.save()
                upsertLocalTrack(track)
                exploredHexStore.indexCoordinates(processed)
            } catch {
                exportError = "Unable to save processed track: \(error.localizedDescription)"
            }
        }
    }

    private func syncSelectionWithTracks() {
        let currentIDs = Set(tracks.map(\.id))
        let newIDs = currentIDs.subtracting(knownTrackIDs)
        let removedIDs = knownTrackIDs.subtracting(currentIDs)

        for id in removedIDs {
            trackDisplayStates.removeValue(forKey: id)
        }
        for id in newIDs {
            trackDisplayStates[id] = .normal
        }
        knownTrackIDs = currentIDs
    }

    private func refreshTracks() {
        let descriptor = FetchDescriptor<Track>()
        do {
            let fetched = try modelContext.fetch(descriptor)
            tracks = TrackNameFormatter.sortedByFirstPointDate(fetched)
        } catch {
            tracks = []
            exportError = "Unable to load tracks: \(error.localizedDescription)"
        }
    }

    private func upsertLocalTrack(_ track: Track) {
        if let index = tracks.firstIndex(where: { $0.id == track.id }) {
            tracks[index] = track
        } else {
            tracks.insert(track, at: 0)
        }
        trackDisplayStates[track.id] = trackDisplayStates[track.id] ?? .normal
    }

    private func centerMapOnUserLocation() {
        guard let mapView else { return }
        mapView.setUserTrackingMode(.follow, animated: true)

        if let coordinate = mapView.userLocation.location?.coordinate {
            mapView.setCenter(coordinate, animated: true)
        }
    }

    private func formatDistance(_ meters: CLLocationDistance) -> String {
        if meters < 1_000 {
            return "\(Int(meters.rounded())) m"
        }
        return String(format: "%.2f km", meters / 1_000)
    }

    private func trackSummary(_ track: Track) -> String {
        let distance = formatDistance(track.distanceMeters)
        guard let duration = track.duration else { return distance }
        return "\(distance) • \(formatDuration(duration))"
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let totalMinutes = Int((max(0, seconds) / 60).rounded())
        if totalMinutes < 60 {
            return "\(totalMinutes) min"
        }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return "\(hours) h \(minutes) min"
    }

    private func nameColor(for track: Track) -> Color {
        switch trackDisplayStates[track.id] ?? .normal {
        case .normal:
            return .primary
        case .highlighted:
            return .orange
        case .hidden:
            return Color(uiColor: .tertiaryLabel)
        }
    }

    private func cycleDisplayState(for track: Track) {
        let current = trackDisplayStates[track.id] ?? .normal
        let next = current.next
        trackDisplayStates[track.id] = next
    }

    private func deselectAllHighlightedTracks() {
        for track in tracks where (trackDisplayStates[track.id] ?? .normal) == .highlighted {
            trackDisplayStates[track.id] = .normal
        }
    }


    private func beginTrackNameEdit(for track: Track) {
        editingTrackID = track.id
        editingTrackName = TrackNameFormatter.displayName(for: track.name)
    }

    private func commitTrackNameEdit(for track: Track) {
        guard editingTrackID == track.id else { return }

        let newDisplayName = editingTrackName.trimmingCharacters(in: .whitespacesAndNewlines)
        editingTrackID = nil

        let currentDisplayName = TrackNameFormatter.displayName(for: track.name)
        guard !newDisplayName.isEmpty, newDisplayName != currentDisplayName else { return }

        track.name = TrackNameFormatter.storedName(
            fromDisplayName: newDisplayName,
            preservingPrefixIn: track.name
        )
        do {
            try modelContext.save()
            upsertLocalTrack(track)
        } catch {
            exportError = "Unable to rename track: \(error.localizedDescription)"
        }
    }

}

private enum TrackDisplayState {
    case normal
    case highlighted
    case hidden

    var next: TrackDisplayState {
        switch self {
        case .normal:
            return .highlighted
        case .highlighted:
            return .hidden
        case .hidden:
            return .normal
        }
    }
}

private struct ExpandedMapIgnoresSafeArea: ViewModifier {
    let isExpanded: Bool

    func body(content: Content) -> some View {
        if isExpanded {
            content
                .ignoresSafeArea()
        } else {
            content
        }
    }
}

private struct DebugDashboardView: View {
    @ObservedObject var tracker: LocationTracker
    @State private var batteryLevel: Float = UIDevice.current.batteryLevel
    @State private var batterySamples: [(date: Date, level: Float)] = []
    @State private var didCopyLog = false

    private let refreshTimer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        List {
            Section("Tracking") {
                debugRow("isTracking", tracker.isTracking ? "true" : "false")
                debugRow("isPaused", tracker.isPaused ? "true" : "false")
                debugRow("live points", "\(tracker.liveTrackCoordinates.count)")
                debugRow("desiredAccuracy", String(format: "%.0f", tracker.debugDesiredAccuracy))
                debugRow("distanceFilter", String(format: "%.1f m", tracker.debugDistanceFilter))
                debugRow("deferred", "\(Int(tracker.debugDeferredDistance))m / \(Int(tracker.debugDeferredTimeout))s")
            }

            Section("Rest / Geofence") {
                debugRow("geofence", tracker.debugGeofenceActive ? "active" : "inactive")
                if let rest = tracker.debugRestCoordinate {
                    debugRow("rest lat", String(format: "%.6f", rest.latitude))
                    debugRow("rest lon", String(format: "%.6f", rest.longitude))
                } else {
                    debugRow("rest point", "n/a")
                }
                if let distance = tracker.debugDistanceToRest {
                    debugRow("distance to rest", String(format: "%.1f m", distance))
                }
            }

            Section("Stationary Timer") {
                if let last = tracker.debugLastSignificantMovementAt {
                    debugRow("last movement", DateFormatter.debugTimestamp.string(from: last))
                } else {
                    debugRow("last movement", "n/a")
                }
                if let left = tracker.debugSecondsUntilAutoStop {
                    debugRow("until auto-stop", formatDuration(left))
                } else {
                    debugRow("until auto-stop", "n/a")
                }
            }

            Section("GPS Quality") {
                if let median = tracker.debugMedianHorizontalAccuracy {
                    debugRow("median hAcc", String(format: "%.1f m", median))
                } else {
                    debugRow("median hAcc", "n/a")
                }
                if let share = tracker.debugPoorAccuracyShare {
                    debugRow("poor fixes (>30m)", String(format: "%.0f%%", share * 100))
                } else {
                    debugRow("poor fixes (>30m)", "n/a")
                }
            }

            Section("Battery Impact Hints") {
                debugRow("level", formatBatteryLevel())
                if let drain = estimatedDrainPerHour() {
                    debugRow("drain estimate", String(format: "%.1f%%/h", drain))
                } else {
                    debugRow("drain estimate", "collecting...")
                }
            }

            Section("Motion") {
                debugRow("activity", tracker.lastMotionSummary)
            }

            Section("Last Location") {
                if let snapshot = tracker.lastLocationSnapshot {
                    debugRow("source", snapshot.source)
                    debugRow("timestamp", DateFormatter.debugTimestamp.string(from: snapshot.timestamp))
                    debugRow("lat", String(format: "%.6f", snapshot.latitude))
                    debugRow("lon", String(format: "%.6f", snapshot.longitude))
                    debugRow("speed", snapshot.speed >= 0 ? String(format: "%.2f m/s", snapshot.speed) : "n/a")
                    debugRow("course", snapshot.course >= 0 ? String(format: "%.1f°", snapshot.course) : "n/a")
                    debugRow("hAccuracy", String(format: "%.1f m", snapshot.horizontalAccuracy))
                    debugRow("vAccuracy", snapshot.verticalAccuracy >= 0 ? String(format: "%.1f m", snapshot.verticalAccuracy) : "n/a")
                    debugRow("altitude", String(format: "%.1f m", snapshot.altitude))
                } else {
                    Text("No location yet")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if tracker.debugEvents.isEmpty {
                    Text("No events yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(tracker.debugEvents.prefix(20).enumerated()), id: \.offset) { _, event in
                        Text(event)
                            .font(.system(.footnote, design: .monospaced))
                    }
                }
            } header: {
                HStack {
                    Text("Events Log")
                    Spacer()
                    Button("Copy Log") {
                        UIPasteboard.general.string = buildDebugReport()
                        didCopyLog = true
                    }
                    .font(.caption)
                }
            } footer: {
                if didCopyLog {
                    Text("Debug log copied to clipboard")
                }
            }
        }
        .navigationTitle("Debug")
        .onAppear {
            UIDevice.current.isBatteryMonitoringEnabled = true
            refreshBattery()
            tracker.requestDebugLocationScan()
        }
        .onReceive(refreshTimer) { _ in
            refreshBattery()
        }
        .onDisappear {
            didCopyLog = false
        }
    }

    @ViewBuilder
    private func debugRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .font(.system(.body, design: .monospaced))
        }
    }

    private func refreshBattery() {
        batteryLevel = UIDevice.current.batteryLevel
        guard batteryLevel >= 0 else { return }

        let now = Date()
        batterySamples.append((date: now, level: batteryLevel))
        let cutoff = now.addingTimeInterval(-30 * 60)
        batterySamples.removeAll { $0.date < cutoff }
    }

    private func formatBatteryLevel() -> String {
        guard batteryLevel >= 0 else { return "n/a" }
        return "\(Int((batteryLevel * 100).rounded()))%"
    }

    private func estimatedDrainPerHour() -> Double? {
        guard let first = batterySamples.first, let last = batterySamples.last else { return nil }
        let dt = last.date.timeIntervalSince(first.date)
        guard dt >= 5 * 60 else { return nil }
        let delta = Double(first.level - last.level) * 100
        return max(0, delta / (dt / 3600))
    }


    private func buildDebugReport() -> String {
        var lines: [String] = []
        lines.append("Pathy Debug Report")
        lines.append("generatedAt: \(DateFormatter.debugTimestamp.string(from: .now))")
        lines.append("isTracking: \(tracker.isTracking)")
        lines.append("isPaused: \(tracker.isPaused)")
        lines.append("livePoints: \(tracker.liveTrackCoordinates.count)")
        lines.append(String(format: "desiredAccuracy: %.0f", tracker.debugDesiredAccuracy))
        lines.append(String(format: "distanceFilter: %.1f", tracker.debugDistanceFilter))
        lines.append("deferred: \(Int(tracker.debugDeferredDistance))m / \(Int(tracker.debugDeferredTimeout))s")
        lines.append("geofenceActive: \(tracker.debugGeofenceActive)")
        if let rest = tracker.debugRestCoordinate {
            lines.append(String(format: "restCoordinate: %.6f, %.6f", rest.latitude, rest.longitude))
        }
        if let d = tracker.debugDistanceToRest {
            lines.append(String(format: "distanceToRest: %.1f", d))
        }
        if let left = tracker.debugSecondsUntilAutoStop {
            lines.append("secondsUntilAutoStop: \(Int(left.rounded()))")
        }
        if let median = tracker.debugMedianHorizontalAccuracy {
            lines.append(String(format: "medianHAcc: %.1f", median))
        }
        if let share = tracker.debugPoorAccuracyShare {
            lines.append(String(format: "poorAccuracyShare: %.2f", share))
        }
        lines.append("motion: \(tracker.lastMotionSummary)")
        lines.append("batteryLevel: \(formatBatteryLevel())")
        if let drain = estimatedDrainPerHour() {
            lines.append(String(format: "batteryDrainPerHour: %.1f", drain))
        }

        if let snapshot = tracker.lastLocationSnapshot {
            lines.append("lastLocation.source: \(snapshot.source)")
            lines.append("lastLocation.timestamp: \(DateFormatter.debugTimestamp.string(from: snapshot.timestamp))")
            lines.append(String(format: "lastLocation.lat: %.6f", snapshot.latitude))
            lines.append(String(format: "lastLocation.lon: %.6f", snapshot.longitude))
            lines.append(String(format: "lastLocation.speed: %.2f", snapshot.speed))
            lines.append(String(format: "lastLocation.course: %.1f", snapshot.course))
            lines.append(String(format: "lastLocation.hAcc: %.1f", snapshot.horizontalAccuracy))
            lines.append(String(format: "lastLocation.vAcc: %.1f", snapshot.verticalAccuracy))
            lines.append(String(format: "lastLocation.alt: %.1f", snapshot.altitude))
        }

        lines.append("events:")
        lines.append(contentsOf: tracker.debugEvents.prefix(80))
        return lines.joined(separator: "\n")
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let clamped = Int(max(0, seconds.rounded()))
        let min = clamped / 60
        let sec = clamped % 60
        return String(format: "%02dm %02ds", min, sec)
    }
}

private extension DateFormatter {
    static let debugTimestamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.dateStyle = .short
        f.timeStyle = .medium
        return f
    }()
}

private struct SettingsView: View {
    let tracker: LocationTracker
    let isAutoStartEnabled: Bool
    let setAutoStartEnabled: (Bool) -> Void
    let onImportGPX: () -> Void
    let onExportGPX: () -> Void
    let canExportGPX: Bool
    let isBusy: Bool
    let savedTracksApproximateByteCount: Int64
    let onDeleteAllTracks: () -> Void
    let canBulkDeleteAllTracks: Bool
    let trackingBlocksBulkDeleteAll: Bool

    @AppStorage("trackPostProcessingEnabled") private var postProcessingEnabled = true
    @AppStorage("trackNoiseWindowSize") private var noiseWindowSize = 33
    @AppStorage("trackRDPToleranceMeters") private var rdpToleranceMeters = 5.0
    @AppStorage("trackChaikinIterations") private var chaikinIterations = 1

    @State private var tileCacheByteCount: Int64 = 0
    @State private var clearTilesConfirmation = false
    @State private var deleteAllTracksConfirmation = false

    private var normalizedNoiseWindowSize: Int {
        TrackProcessingSettingsStore.normalizedNoiseWindow(noiseWindowSize)
    }

    private var normalizedRDPTolerance: Double {
        TrackProcessingSettingsStore.normalizedRDPTolerance(rdpToleranceMeters)
    }

    private var normalizedChaikinIterations: Int {
        TrackProcessingSettingsStore.normalizedChaikinIterations(chaikinIterations)
    }

    var body: some View {
        Form {
            Section("Tracking") {
                Toggle("Auto-start", isOn: Binding(
                    get: { isAutoStartEnabled },
                    set: setAutoStartEnabled
                ))
            }

            Section {
                Toggle("Post-process tracks", isOn: $postProcessingEnabled)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Noise smoothing")
                        Spacer()
                        Text("\(normalizedNoiseWindowSize) points")
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(normalizedNoiseWindowSize) },
                            set: { noiseWindowSize = TrackProcessingSettingsStore.normalizedNoiseWindow(Int($0.rounded())) }
                        ),
                        in: 3...51,
                        step: 2
                    )
                }
                .disabled(!postProcessingEnabled)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Track simplification (RDP)")
                        Spacer()
                        Text(String(format: "%.1f m", normalizedRDPTolerance))
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { normalizedRDPTolerance },
                            set: { rdpToleranceMeters = TrackProcessingSettingsStore.normalizedRDPTolerance($0) }
                        ),
                        in: 0.5...20.0,
                        step: 0.5
                    )
                }
                .disabled(!postProcessingEnabled)

                Stepper(
                    "Corner smoothing: \(normalizedChaikinIterations) \(normalizedChaikinIterations == 1 ? "iteration" : "iterations")",
                    value: Binding(
                        get: { normalizedChaikinIterations },
                        set: { chaikinIterations = TrackProcessingSettingsStore.normalizedChaikinIterations($0) }
                    ),
                    in: 0...3
                )
                .disabled(!postProcessingEnabled)
            } header: {
                Text("GPS filtering")
            } footer: {
                Text("Applied in the background when a recording finishes: noise filter → RDP → Chaikin.")
                    .foregroundStyle(.secondary)
            }

            Section("Map tiles") {
                LabeledContent("Size") {
                    Text(formatBytes(tileCacheByteCount))
                        .foregroundStyle(.secondary)
                }

                Button("Delete all", role: .destructive) {
                    clearTilesConfirmation = true
                }
            }

            Section {
                LabeledContent("Size") {
                    Text(formatBytes(savedTracksApproximateByteCount))
                        .foregroundStyle(.secondary)
                }

                Button("Delete all tracks", role: .destructive) {
                    deleteAllTracksConfirmation = true
                }
                .disabled(!canBulkDeleteAllTracks)
            } header: {
                Text("Saved tracks")
            } footer: {
                if trackingBlocksBulkDeleteAll {
                    Text("Stop the current recording before deleting all tracks.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("GPX") {
                Button("Import GPX", action: onImportGPX)
                    .disabled(isBusy)

                Button("Export GPX", action: onExportGPX)
                    .disabled(isBusy || !canExportGPX)
            }

            Section {
                NavigationLink {
                    DebugDashboardView(tracker: tracker)
                } label: {
                    Label("Debug", systemImage: "ladybug")
                }
            }
        }
        .navigationTitle("Settings")
        .onAppear {
            refreshTileCacheSize()
        }
        .alert("Delete cached map tiles?", isPresented: $clearTilesConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All", role: .destructive) {
                try? OfflineTileOverlay.removeAllTilesFromDisk()
                refreshTileCacheSize()
            }
        } message: {
            Text("Map tiles download again while you browse the map. This does not delete your saved tracks.")
        }
        .alert("Delete all tracks?", isPresented: $deleteAllTracksConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete All", role: .destructive) {
                onDeleteAllTracks()
            }
        } message: {
            Text(
                "All saved tracks will be removed from this device. This cannot be undone. "
                + "Use Export GPX in the section below first if you want a backup copy."
            )
        }
    }

    private func refreshTileCacheSize() {
        tileCacheByteCount = OfflineTileOverlay.totalTileCacheByteCount()
    }

    private func formatBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        let gb = Double(bytes) / (1024 * 1024 * 1024)
        if gb >= 1 {
            return String(format: "%.2f GB", gb)
        }
        let mb = Double(bytes) / (1024 * 1024)
        if mb >= 1 {
            return String(format: "%.2f MB", mb)
        }
        let kb = Double(bytes) / 1024
        if kb >= 1 {
            return String(format: "%.1f KB", kb)
        }
        return "\(bytes) B"
    }
}

private extension UTType {
    static var gpx: UTType {
        UTType(filenameExtension: "gpx") ?? .xml
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    ContentView()
        .modelContainer(for: Track.self, inMemory: true)
        .environmentObject(LocationTracker.shared)
}
