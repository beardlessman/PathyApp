//
//  TrackMapView.swift
//  PathyApp
//

import CoreLocation
import MapKit
import SwiftUI
import UIKit

struct TrackMapView: UIViewRepresentable {
    var trackPointGroups: [[TrackCoordinate]]
    var shouldAutoFocus = false
    var focusSignature = ""
    var onMapReady: ((MKMapView, OfflineTileOverlay) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.userTrackingMode = .follow
        mapView.showsCompass = true

        let overlay = OfflineTileOverlay(urlTemplate: nil)
        mapView.addOverlay(overlay, level: .aboveRoads)
        context.coordinator.overlay = overlay
        onMapReady?(mapView, overlay)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        let coordinateGroups = trackPointGroups
            .map { group in
                group.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            }
            .filter { $0.count > 1 }

        let tracksSignature = coordinateGroups
            .map { coordinates in
                let first = coordinates.first
                let last = coordinates.last
                return "\(coordinates.count):\(first?.latitude ?? 0),\(first?.longitude ?? 0):\(last?.latitude ?? 0),\(last?.longitude ?? 0)"
            }
            .joined(separator: "|")

        if context.coordinator.lastTracksSignature != tracksSignature {
            mapView.removeOverlays(context.coordinator.trackPolylines)
            let polylines = coordinateGroups.map { MKPolyline(coordinates: $0, count: $0.count) }
            context.coordinator.trackPolylines = polylines
            mapView.addOverlays(polylines, level: .aboveLabels)
            context.coordinator.lastTracksSignature = tracksSignature
        }

        if shouldAutoFocus, context.coordinator.lastFocusSignature != focusSignature {
            let unionRect = context.coordinator.trackPolylines
                .map(\.boundingMapRect)
                .reduce(MKMapRect.null) { current, next in
                    current.isNull ? next : current.union(next)
                }

            if !unionRect.isNull {
                let insets = UIEdgeInsets(top: 48, left: 48, bottom: 48, right: 48)
                mapView.setVisibleMapRect(unionRect, edgePadding: insets, animated: true)
            }
            context.coordinator.lastFocusSignature = focusSignature
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var overlay: OfflineTileOverlay?
        var trackPolylines: [MKPolyline] = []
        var lastTracksSignature = ""
        var lastFocusSignature = ""

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tile)
            }
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = .systemBlue
                renderer.lineWidth = 4
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}
