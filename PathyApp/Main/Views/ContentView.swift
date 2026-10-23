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
        isImportingTrack || isDeletingTracks || exploredHexStore.isReindexing
            || postProcessingTrackID != nil || tracker.isPostProcessingTrack
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
                exploredHexStore.reindexFromAllTracks()
            }
            .onChange(of: tracker.isPostProcessingTrack) { _, isProcessing in
                guard !isProcessing else { return }
                if let currentTrack = tracker.currentTrack {
                    upsertLocalTrack(currentTrack)
                }
                refreshTracks()
                exploredHexStore.reindexFromAllTracks()
            }
            .animation(nil, value: isMapExpanded)
            .overlay {
                if isBusy {
                    ZStack {
                        Color.black.opacity(0.2).ignoresSafeArea()
                        ProgressView(
                            isProcessingTrack
                                ? "Processing track..."
                                : (exploredHexStore.isReindexing
                                    ? "Updating discovery map..."
                                    : (isDeletingTracks ? "Deleting track..." : "Importing GPX..."))
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
                }
                refreshTracks()
                syncSelectionWithTracks()
                exploredHexStore.reindexFromAllTracks()
            } catch let batchError as GPXBatchImportError {
                for track in batchError.partiallyImported {
                    upsertLocalTrack(track)
                }
                refreshTracks()
                syncSelectionWithTracks()
                exploredHexStore.reindexFromAllTracks()
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
        exploredHexStore.reindexFromAllTracks()
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
                exploredHexStore.reindexFromAllTracks()
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
                exploredHexStore.reindexFromAllTracks()
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

private extension UTType {
    static var gpx: UTType {
        UTType(filenameExtension: "gpx") ?? .xml
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Track.self, inMemory: true)
        .environmentObject(LocationTracker.shared)
}
