//
//  DebugRestPointMap.swift
//  PathyApp
//

import MapKit
import SwiftUI

struct DebugRestPointMap: View {
    let restCoordinate: CLLocationCoordinate2D
    let userCoordinate: CLLocationCoordinate2D?
    let showGeofence: Bool

    /// Matches `LocationTracker.passiveWakeGeofenceRadius`.
    private let geofenceRadiusMeters: CLLocationDistance = 100

    @State private var position: MapCameraPosition

    init(
        restCoordinate: CLLocationCoordinate2D,
        userCoordinate: CLLocationCoordinate2D?,
        showGeofence: Bool
    ) {
        self.restCoordinate = restCoordinate
        self.userCoordinate = userCoordinate
        self.showGeofence = showGeofence
        _position = State(
            initialValue: .region(Self.region(rest: restCoordinate, user: userCoordinate))
        )
    }

    var body: some View {
        Map(position: $position) {
            Annotation("Rest", coordinate: restCoordinate) {
                mapDot(color: .orange)
            }

            if let userCoordinate {
                Annotation("User", coordinate: userCoordinate) {
                    mapDot(color: .blue)
                }
            }

            if showGeofence {
                MapCircle(center: restCoordinate, radius: geofenceRadiusMeters)
                    .foregroundStyle(.orange.opacity(0.12))
                    .stroke(.orange.opacity(0.55), lineWidth: 1)
            }
        }
        .frame(height: 180)
        .mapStyle(.standard(elevation: .flat))
        .disabled(true)
        .onChange(of: restCoordinate.latitude) { _, _ in recenter() }
        .onChange(of: restCoordinate.longitude) { _, _ in recenter() }
        .onChange(of: userCoordinate?.latitude) { _, _ in recenter() }
        .onChange(of: userCoordinate?.longitude) { _, _ in recenter() }
    }

    private func recenter() {
        position = .region(Self.region(rest: restCoordinate, user: userCoordinate))
    }

    private func mapDot(color: Color) -> some View {
        ZStack {
            Circle()
                .fill(.white)
                .frame(width: 16, height: 16)
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
        }
    }

    private static func region(
        rest: CLLocationCoordinate2D,
        user: CLLocationCoordinate2D?
    ) -> MKCoordinateRegion {
        guard let user else {
            return MKCoordinateRegion(
                center: rest,
                latitudinalMeters: 450,
                longitudinalMeters: 450
            )
        }

        let minLat = min(rest.latitude, user.latitude)
        let maxLat = max(rest.latitude, user.latitude)
        let minLon = min(rest.longitude, user.longitude)
        let maxLon = max(rest.longitude, user.longitude)

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )

        let latDelta = max((maxLat - minLat) * 1.8, 0.004)
        let lonDelta = max((maxLon - minLon) * 1.8, 0.004)

        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
        )
    }
}

