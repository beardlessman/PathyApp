//
//  SettingsView.swift
//  PathyApp
//

import SwiftUI

struct SettingsView: View {
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

