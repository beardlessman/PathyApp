//
//  ContentView.swift
//  PathyApp
//
//  Created by Dmitrii Mungalov on 28.04.2026.
//

import MapKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var tracker = LocationTracker.shared
    @State private var tracks: [Track] = []

    @State private var selectedTrackIDs: Set<UUID> = []
    @State private var knownTrackIDs: Set<UUID> = []
    @State private var mapView: MKMapView?
    @State private var tileOverlay: OfflineTileOverlay?
    @State private var isImporting = false
    @State private var isImportingTrack = false
    @State private var isDeletingTracks = false
    @State private var exportedURL: URL?
    @State private var exportError: String?

    private var isBusy: Bool {
        isImportingTrack || isDeletingTracks
    }

    private var displayedTrackPointGroups: [[TrackCoordinate]] {
        let selectedTracks = tracks.filter { selectedTrackIDs.contains($0.id) }
        if !selectedTracks.isEmpty {
            return selectedTracks.map(\.coordinates)
        }
        if tracker.isTracking {
            return [tracker.liveTrackCoordinates]
        }
        if let currentTrack = tracker.currentTrack {
            return [currentTrack.coordinates]
        }
        return []
    }

    private var focusSignature: String {
        let ids = selectedTrackIDs
            .map(\.uuidString)
            .sorted()
            .joined(separator: "|")
        let totalPoints = displayedTrackPointGroups.reduce(0) { $0 + $1.count }
        return "\(ids)#\(totalPoints)"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                TrackMapView(
                    trackPointGroups: displayedTrackPointGroups,
                    shouldAutoFocus: !selectedTrackIDs.isEmpty,
                    focusSignature: focusSignature
                ) { map, overlay in
                    mapView = map
                    tileOverlay = overlay
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                HStack(spacing: 12) {
                    Button(tracker.isTracking ? "Stop Tracking" : "Start Tracking") {
                        if tracker.isTracking {
                            tracker.stopTracking()
                            if let currentTrack = tracker.currentTrack {
                                upsertLocalTrack(currentTrack)
                            }
                            refreshTracks()
                        } else {
                            tracker.startTracking()
                            if let currentTrack = tracker.currentTrack {
                                upsertLocalTrack(currentTrack)
                            }
                        }
                        syncSelectionWithTracks()
                    }
                    .buttonStyle(.borderedProminent)

                    if tracker.isTracking {
                        Button(tracker.isPaused ? "Resume" : "Pause") {
                            if tracker.isPaused {
                                tracker.resumeTracking()
                            } else {
                                tracker.pauseTracking()
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }


                List {
                    ForEach(tracks) { track in
                        Button {
                            if selectedTrackIDs.contains(track.id) {
                                selectedTrackIDs.remove(track.id)
                            } else {
                                selectedTrackIDs.insert(track.id)
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(track.name).font(.headline)
                                    Text("Points: \(track.pointCount)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedTrackIDs.contains(track.id) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                }
                            }
                        }
                    }
                    .onDelete(perform: deleteTracks)
                }
                .frame(height: 180)
                .disabled(isBusy)
            }
            .padding()
            .navigationTitle("Pathy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                    SettingsView(
                        isAutoStartEnabled: tracker.isAutoStartEnabled,
                        setAutoStartEnabled: { tracker.setAutoStartEnabled($0) },
                        onImportGPX: { isImporting = true },
                        onExportGPX: exportAllTracks,
                        canExportGPX: !tracks.isEmpty,
                        isBusy: isBusy
                    )
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.xml, .gpx],
                allowsMultipleSelection: false
            ) { result in
                if case let .success(urls) = result, let url = urls.first {
                    importTrack(url: url)
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
                tracker.requestPermissions()
                tracker.onCoordinateRecorded = { coordinate in
                    autoCacheAroundTrackingCoordinate(coordinate)
                }
                refreshTracks()
                syncSelectionWithTracks()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase != .active {
                    tracker.persistCurrentState()
                    refreshTracks()
                }
            }
            .overlay {
                if isBusy {
                    ZStack {
                        Color.black.opacity(0.2).ignoresSafeArea()
                        ProgressView(isDeletingTracks ? "Deleting track..." : "Importing GPX...")
                            .padding(.horizontal, 20)
                            .padding(.vertical, 14)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
    }

    private func importTrack(url: URL) {
        isImportingTrack = true
        Task { @MainActor in
            let hasScopedAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasScopedAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let track = try GPXService.import(from: url, modelContext: modelContext)
                upsertLocalTrack(track)
                refreshTracks()
                selectedTrackIDs.insert(track.id)
                syncSelectionWithTracks()
            } catch {
                exportError = "Unable to import GPX: \(error.localizedDescription)"
            }
            isImportingTrack = false
        }
    }

    private func autoCacheAroundTrackingCoordinate(_ coordinate: CLLocationCoordinate2D) {
        guard tracker.isTracking else { return }
        tileOverlay?.prefetchAround(coordinate: coordinate, zoomLevels: 13...16, radius: 1)
    }

    private func exportAllTracks() {
        do {
            exportedURL = try GPXService.exportAllAsZip(tracks: tracks)
        } catch {
            exportError = "Unable to export GPX: \(error.localizedDescription)"
        }
    }

    private func deleteTracks(at offsets: IndexSet) {
        let tracksToDelete = offsets.map { tracks[$0] }
        isDeletingTracks = true

        Task {
            do {
                for track in tracksToDelete {
                    selectedTrackIDs.remove(track.id)
                    knownTrackIDs.remove(track.id)
                    modelContext.delete(track)
                }
                try modelContext.save()
                let deletedIDs = Set(tracksToDelete.map(\.id))
                tracks.removeAll { deletedIDs.contains($0.id) }
                refreshTracks()
                syncSelectionWithTracks()
            } catch {
                exportError = "Unable to delete track: \(error.localizedDescription)"
            }
            isDeletingTracks = false
        }
    }

    private func syncSelectionWithTracks() {
        let currentIDs = Set(tracks.map(\.id))
        let newIDs = currentIDs.subtracting(knownTrackIDs)
        let removedIDs = knownTrackIDs.subtracting(currentIDs)

        selectedTrackIDs.subtract(removedIDs)
        selectedTrackIDs.formUnion(newIDs)
        knownTrackIDs = currentIDs
    }

    private func refreshTracks() {
        let descriptor = FetchDescriptor<Track>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        do {
            let fetched = try modelContext.fetch(descriptor)
            tracks = fetched
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
        selectedTrackIDs.insert(track.id)
    }

}

private struct SettingsView: View {
    let isAutoStartEnabled: Bool
    let setAutoStartEnabled: (Bool) -> Void
    let onImportGPX: () -> Void
    let onExportGPX: () -> Void
    let canExportGPX: Bool
    let isBusy: Bool

    var body: some View {
        Form {
            Section("Tracking") {
                Toggle("Auto-start tracking", isOn: Binding(
                    get: { isAutoStartEnabled },
                    set: setAutoStartEnabled
                ))
            }

            Section("GPX") {
                Button("Import GPX", action: onImportGPX)
                    .disabled(isBusy)

                Button("Export GPX", action: onExportGPX)
                    .disabled(isBusy || !canExportGPX)
            }
        }
        .navigationTitle("Settings")
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
}
