//
//  DebugLocationSnapshotView.swift
//  PathyApp
//

import SwiftUI

struct DebugLocationSnapshotView: View {
    let snapshot: LocationDebugSnapshot

    var body: some View {
        List {
            snapshotRow("source", snapshot.source)
            snapshotRow("timestamp", DateFormatter.debugTimestamp.string(from: snapshot.timestamp))
            snapshotRow("lat", String(format: "%.6f", snapshot.latitude))
            snapshotRow("lon", String(format: "%.6f", snapshot.longitude))
            snapshotRow(
                "speed",
                snapshot.speed >= 0 ? String(format: "%.2f m/s", snapshot.speed) : "n/a"
            )
            snapshotRow(
                "course",
                snapshot.course >= 0 ? String(format: "%.1f°", snapshot.course) : "n/a"
            )
            snapshotRow("hAccuracy", String(format: "%.1f m", snapshot.horizontalAccuracy))
            snapshotRow(
                "vAccuracy",
                snapshot.verticalAccuracy >= 0
                    ? String(format: "%.1f m", snapshot.verticalAccuracy)
                    : "n/a"
            )
            snapshotRow("altitude", String(format: "%.1f m", snapshot.altitude))
        }
        .navigationTitle("Location Snapshot")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func snapshotRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .font(.system(.body, design: .monospaced))
        }
    }
}

