//
//  TrackMapView.swift
//  PathyApp
//

import CoreLocation
import MapKit
import SwiftUI
import UIKit

struct TrackMapView: UIViewRepresentable {
    struct Route {
        let id: String
        let coordinates: [TrackCoordinate]
        let strokeColor: UIColor
    }

    var routes: [Route]
    var highlightedRouteIDs: Set<String> = []
    var focusedRouteID: String?
    var followUserLocation = false
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
        if followUserLocation {
            if mapView.userTrackingMode != .follow {
                mapView.setUserTrackingMode(.follow, animated: true)
            }
        } else if mapView.userTrackingMode != .none {
            mapView.setUserTrackingMode(.none, animated: false)
        }

        let drawableRoutes = routes
            .map { route in
                (
                    id: route.id,
                    color: route.strokeColor,
                    coordinates: route.coordinates
                        .map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                )
            }
            .filter { $0.coordinates.count > 1 }
            .sorted { lhs, rhs in
                let lhsHighlighted = highlightedRouteIDs.contains(lhs.id)
                let rhsHighlighted = highlightedRouteIDs.contains(rhs.id)
                if lhsHighlighted != rhsHighlighted {
                    return !lhsHighlighted
                }
                return false
            }

        let highlightSignature = highlightedRouteIDs.sorted().joined(separator: ",")
        let tracksSignature = drawableRoutes
            .map { route in
                let first = route.coordinates.first
                let last = route.coordinates.last
                let color = route.color.rgbaSignature
                let highlighted = highlightedRouteIDs.contains(route.id) ? "1" : "0"
                return "\(route.id):\(route.coordinates.count):\(first?.latitude ?? 0),\(first?.longitude ?? 0):\(last?.latitude ?? 0),\(last?.longitude ?? 0):\(color):\(highlighted)"
            }
            .joined(separator: "|") + "#\(highlightSignature)"

        if context.coordinator.lastTracksSignature != tracksSignature {
            mapView.removeOverlays(context.coordinator.trackPolylines)
            context.coordinator.polylineColors = [:]
            context.coordinator.polylineRouteIDs = [:]
            let polylines = drawableRoutes.map { route in
                let polyline = MKPolyline(coordinates: route.coordinates, count: route.coordinates.count)
                let polylineID = ObjectIdentifier(polyline)
                context.coordinator.polylineColors[polylineID] = route.color
                context.coordinator.polylineRouteIDs[polylineID] = route.id
                return polyline
            }
            context.coordinator.trackPolylines = polylines
            mapView.addOverlays(polylines, level: .aboveLabels)
            context.coordinator.lastTracksSignature = tracksSignature
        }

        if context.coordinator.lastFocusedRouteID != focusedRouteID, let focusedRouteID {
            let focusedRects = context.coordinator.trackPolylines.compactMap { polyline -> MKMapRect? in
                let id = context.coordinator.polylineRouteIDs[ObjectIdentifier(polyline)]
                return id == focusedRouteID ? polyline.boundingMapRect : nil
            }
            let unionRect = focusedRects.reduce(MKMapRect.null) { current, next in
                current.isNull ? next : current.union(next)
            }
            if !unionRect.isNull {
                let insets = UIEdgeInsets(top: 48, left: 48, bottom: 48, right: 48)
                mapView.setVisibleMapRect(unionRect, edgePadding: insets, animated: true)
            }
            context.coordinator.lastFocusedRouteID = focusedRouteID
        } else if focusedRouteID == nil {
            context.coordinator.lastFocusedRouteID = nil
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var overlay: OfflineTileOverlay?
        var trackPolylines: [MKPolyline] = []
        var polylineColors: [ObjectIdentifier: UIColor] = [:]
        var polylineRouteIDs: [ObjectIdentifier: String] = [:]
        var lastTracksSignature = ""
        var lastFocusedRouteID: String?

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tile)
            }
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = polylineColors[ObjectIdentifier(polyline)] ?? .systemBlue
                renderer.lineWidth = 4
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

private extension UIColor {
    var rgbaSignature: String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(format: "%.4f-%.4f-%.4f-%.4f", red, green, blue, alpha)
    }
}
