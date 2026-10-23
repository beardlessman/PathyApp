//
//  DebugDashboardView.swift
//  PathyApp
//

import Combine
import MapKit
import SwiftUI
import UIKit

struct DebugDashboardView: View {
    @ObservedObject var tracker: LocationTracker
    @State private var didCopyLog = false
    @State private var restRelocateTick = Date()

    private let restRelocateRefresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        List {
            Section("Tracking") {
                debugRow("isTracking", tracker.isTracking ? "true" : "false")
                debugRow("live points", "\(tracker.liveTrackCoordinates.count)")
            }

            Section("Rest / Geofence") {
                debugRow("geofence", tracker.debugGeofenceActive ? "active" : "inactive")
                if let rest = tracker.debugRestCoordinate {
                    DebugRestPointMap(
                        restCoordinate: rest,
                        userCoordinate: tracker.freshUserCoordinateForDebug(),
                        showGeofence: tracker.debugGeofenceActive
                    )
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))

                    if let createdAt = tracker.debugRestCreatedAt {
                        debugRow("rest created", DateFormatter.debugTimestamp.string(from: createdAt))
                    } else {
                        debugRow("rest created", "n/a")
                    }
                    debugRow("rest reason", tracker.debugRestCreatedReason ?? "n/a")
                } else {
                    debugRow("rest point", "n/a")
                }
                if let distance = freshDistanceToRest {
                    debugRow("distance to rest", String(format: "%.1f m", distance))
                } else {
                    debugRow("distance to rest", "n/a (no current GPS)")
                }
                debugRow("motion", tracker.lastMotionSummary)
                debugRow("until relocate", restRelocateCountdownLabel)
            }

            Section("Last Location") {
                if let snapshot = tracker.lastLocationSnapshot {
                    debugRow("source", snapshot.source)
                    debugRow("timestamp", DateFormatter.debugTimestamp.string(from: snapshot.timestamp))
                    NavigationLink("View Full Snapshot") {
                        DebugLocationSnapshotView(snapshot: snapshot)
                    }
                } else {
                    Text("No location yet")
                        .foregroundStyle(.secondary)
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
        .onReceive(restRelocateRefresh) { date in
            restRelocateTick = date
        }
        .onDisappear {
            didCopyLog = false
        }
    }

    private var restRelocateCountdownLabel: String {
        _ = restRelocateTick

        guard tracker.debugRestCoordinate != nil else { return "n/a (no rest)" }
        guard !tracker.isTracking else { return "n/a (tracking)" }
        guard tracker.isAutoStartEnabled else { return "n/a (auto-start off)" }

        let distanceThreshold = tracker.debugRestRelocateDistanceThreshold
        guard let distance = freshDistanceToRest else {
            return "n/a (need current GPS)"
        }
        guard distance >= distanceThreshold else {
            return String(format: "n/a (need ≥%.0fm)", distanceThreshold)
        }

        let resting = tracker.lastMotionSummary.contains("stationary")
        guard resting else { return "n/a (need rest)" }

        guard let createdAt = tracker.debugRestCreatedAt else {
            return "n/a (no rest time)"
        }

        let required = tracker.debugRestRelocateMinAge
        let remaining = max(0, required - Date().timeIntervalSince(createdAt))
        return remaining > 0 ? formatDuration(remaining) : "ready"
    }

    private var freshDistanceToRest: CLLocationDistance? {
        _ = restRelocateTick
        return tracker.freshDistanceToRest()
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

    private func buildDebugReport() -> String {
        var lines: [String] = []
        lines.append("Pathy Debug Report")
        lines.append("generatedAt: \(DateFormatter.debugTimestamp.string(from: .now))")
        lines.append("isTracking: \(tracker.isTracking)")
        lines.append("livePoints: \(tracker.liveTrackCoordinates.count)")
        lines.append("geofenceActive: \(tracker.debugGeofenceActive)")
        if let rest = tracker.debugRestCoordinate {
            lines.append(String(format: "restCoordinate: %.6f, %.6f", rest.latitude, rest.longitude))
        }
        if let createdAt = tracker.debugRestCreatedAt {
            lines.append("restCreatedAt: \(DateFormatter.debugTimestamp.string(from: createdAt))")
        }
        if let reason = tracker.debugRestCreatedReason {
            lines.append("restCreatedReason: \(reason)")
        }
        if let d = tracker.debugDistanceToRest {
            lines.append(String(format: "distanceToRest: %.1f", d))
        }
        lines.append("motion: \(tracker.lastMotionSummary)")
        lines.append("untilRelocate: \(restRelocateCountdownLabel)")
        if let left = tracker.debugSecondsUntilAutoStop {
            lines.append("secondsUntilAutoStop: \(Int(left.rounded()))")
        }

        if let snapshot = tracker.lastLocationSnapshot {
            lines.append("lastLocation.source: \(snapshot.source)")
            lines.append("lastLocation.timestamp: \(DateFormatter.debugTimestamp.string(from: snapshot.timestamp))")
            lines.append(String(format: "lastLocation.lat: %.6f", snapshot.latitude))
            lines.append(String(format: "lastLocation.lon: %.6f", snapshot.longitude))
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


extension DateFormatter {
    static let debugTimestamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.dateStyle = .short
        f.timeStyle = .medium
        return f
    }()
}

