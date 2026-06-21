//
//  DiscoveryMapViewController.swift
//  PathyApp
//

import Combine
import CoreLocation
import MapKit
import SwiftUI
import UIKit

/// Full-screen fog-of-war map. Owns a dedicated `MKMapView` instance that is released on dismiss.
final class DiscoveryMapViewController: UIViewController {
    private let exploredHexStore: ExploredHexStore
    private let initialRegion: MKCoordinateRegion?

    private var mapView: MKMapView?
    private var fogOverlay: FogOfWarTileOverlay?
    private var compassButton: MKCompassButton?
    private var trackingButton: DiscoveryUserTrackingButton?
    private var revisionCancellable: AnyCancellable?
    private var lastFogRevision = -1
    private var pendingFogRevision: Int?
    private var shouldCenterOnUser = true
    private let discoveryZoomMeters: CLLocationDistance = 500

    init(exploredHexStore: ExploredHexStore, initialRegion: MKCoordinateRegion?) {
        self.exploredHexStore = exploredHexStore
        self.initialRegion = initialRegion
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        revisionCancellable?.cancel()
        fogOverlay?.purgeCache()
        mapView?.delegate = nil
        if let mapView, let fogOverlay {
            mapView.removeOverlay(fogOverlay)
        }
        fogOverlay = nil
        compassButton?.removeFromSuperview()
        trackingButton?.removeFromSuperview()
        compassButton = nil
        trackingButton = nil
        mapView?.removeFromSuperview()
        mapView = nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        exploredHexStore.reloadFromDatabase()
        configureMap()
        applyInitialViewport()
        observeFogRevision()
        applyFogRevision(exploredHexStore.revision)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        _ = centerOnUserIfAvailable()
    }

    func updateFogRevision(_ revision: Int) {
        guard revision != lastFogRevision else { return }
        applyFogRevision(revision)
    }

    private func configureMap() {
        let mapView = MKMapView(frame: view.bounds)
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.delegate = self
        mapView.showsUserLocation = true
        mapView.showsCompass = false
        mapView.showsUserTrackingButton = false
        mapView.pointOfInterestFilter = MKPointOfInterestFilter(including: [])

        let configuration = MKStandardMapConfiguration()
        configuration.emphasisStyle = .muted
        configuration.pointOfInterestFilter = MKPointOfInterestFilter(including: [])
        mapView.preferredConfiguration = configuration

        view.addSubview(mapView)
        self.mapView = mapView

        let fogOverlay = FogOfWarTileOverlay(urlTemplate: nil)
        fogOverlay.setExploredHexProvider { [weak exploredHexStore] bounds in
            exploredHexStore?.exploredHexes(in: bounds) ?? []
        }
        fogOverlay.setExploredHexLookup { [weak exploredHexStore] hexId in
            exploredHexStore?.isExplored(hexId: hexId) ?? false
        }
        mapView.addOverlay(fogOverlay, level: .aboveLabels)
        self.fogOverlay = fogOverlay

        configureMapControls(mapView: mapView)

        if let pendingFogRevision {
            self.pendingFogRevision = nil
            applyFogRevision(pendingFogRevision)
        } else {
            applyFogRevision(lastFogRevision)
        }
    }

    private func configureMapControls(mapView: MKMapView) {
        let trackingButton = DiscoveryUserTrackingButton(mapView: mapView)
        trackingButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(trackingButton)
        self.trackingButton = trackingButton

        let compassButton = MKCompassButton(mapView: mapView)
        compassButton.compassVisibility = .adaptive
        compassButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(compassButton)
        self.compassButton = compassButton

        let controlsTopInset: CGFloat = 56

        NSLayoutConstraint.activate([
            trackingButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: controlsTopInset),
            trackingButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            compassButton.topAnchor.constraint(equalTo: trackingButton.bottomAnchor, constant: 8),
            compassButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
        ])
    }

    private func applyInitialViewport() {
        if centerOnUserIfAvailable() { return }

        guard let mapView else { return }

        if let initialRegion, isValidRegion(initialRegion) {
            mapView.setRegion(initialRegion, animated: false)
            return
        }

        mapView.setUserTrackingMode(.follow, animated: false)
    }

    @discardableResult
    private func centerOnUserIfAvailable() -> Bool {
        guard shouldCenterOnUser else { return false }
        guard let mapView else { return false }
        guard let location = mapView.userLocation.location,
              location.horizontalAccuracy >= 0,
              isValidCoordinate(location.coordinate) else {
            return false
        }

        let region = MKCoordinateRegion(
            center: location.coordinate,
            latitudinalMeters: discoveryZoomMeters,
            longitudinalMeters: discoveryZoomMeters
        )
        guard isValidRegion(region) else { return false }

        mapView.setRegion(region, animated: false)
        shouldCenterOnUser = false
        return true
    }

    private func applyFogRevision(_ revision: Int) {
        lastFogRevision = revision
        guard isViewLoaded, mapView != nil, fogOverlay != nil else {
            pendingFogRevision = revision
            return
        }
        fogOverlay?.setContentRevision(revision)
    }

    private func observeFogRevision() {
        revisionCancellable = exploredHexStore.$revision
            .receive(on: DispatchQueue.main)
            .sink { [weak self] revision in
                self?.applyFogRevision(revision)
            }
    }

    private func isValidCoordinate(_ coordinate: CLLocationCoordinate2D) -> Bool {
        CLLocationCoordinate2DIsValid(coordinate)
            && abs(coordinate.latitude) <= 90
            && abs(coordinate.longitude) <= 180
            && !(coordinate.latitude == 0 && coordinate.longitude == 0)
    }

    private func isValidRegion(_ region: MKCoordinateRegion) -> Bool {
        isValidCoordinate(region.center)
            && region.span.latitudeDelta > 0
            && region.span.longitudeDelta > 0
            && region.span.latitudeDelta < 180
            && region.span.longitudeDelta < 360
    }
}

extension DiscoveryMapViewController: MKMapViewDelegate {
    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        guard let fogOverlay = overlay as? FogOfWarTileOverlay else {
            return MKOverlayRenderer(overlay: overlay)
        }
        let renderer = MKTileOverlayRenderer(tileOverlay: fogOverlay)
        fogOverlay.attach(renderer: renderer)
        return renderer
    }

    func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
        guard userLocation.location != nil else { return }
        _ = centerOnUserIfAvailable()
    }

    func mapView(_ mapView: MKMapView, didChange mode: MKUserTrackingMode, animated: Bool) {
        trackingButton?.syncAppearance(with: mode)
    }
}

// MARK: - Custom user tracking button

/// Outline SF Symbol styling with the same tracking-mode cycle as `MKUserTrackingButton`.
private final class DiscoveryUserTrackingButton: UIControl {
    private weak var mapView: MKMapView?
    private let iconView = UIImageView()

    private let buttonSize: CGFloat = 44
    private let iconTint = UIColor(white: 0.12, alpha: 1)

    init(mapView: MKMapView) {
        self.mapView = mapView
        super.init(frame: .zero)
        configure()
        syncAppearance(with: mapView.userTrackingMode)
        addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func syncAppearance(with mode: MKUserTrackingMode) {
        let symbolName: String
        switch mode {
        case .none, .follow:
            symbolName = "location"
        case .followWithHeading:
            symbolName = "location.north.line"
        @unknown default:
            symbolName = "location"
        }
        let configuration = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        iconView.image = UIImage(systemName: symbolName, withConfiguration: configuration)?
            .withRenderingMode(.alwaysTemplate)
    }

    @objc private func handleTap() {
        guard let mapView else { return }
        let nextMode: MKUserTrackingMode
        switch mapView.userTrackingMode {
        case .none:
            nextMode = .follow
        case .follow:
            nextMode = .followWithHeading
        case .followWithHeading:
            nextMode = .none
        @unknown default:
            nextMode = .follow
        }
        mapView.setUserTrackingMode(nextMode, animated: true)
        syncAppearance(with: nextMode)
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .white
        layer.cornerRadius = buttonSize / 2
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 2
        layer.shadowOffset = CGSize(width: 0, height: 1)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.tintColor = iconTint
        iconView.contentMode = .scaleAspectFit
        addSubview(iconView)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: buttonSize),
            heightAnchor.constraint(equalToConstant: buttonSize),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),
        ])
    }
}

struct DiscoveryMapViewControllerRepresentable: UIViewControllerRepresentable {
    @ObservedObject var exploredHexStore: ExploredHexStore
    let initialRegion: MKCoordinateRegion?

    func makeUIViewController(context: Context) -> DiscoveryMapViewController {
        DiscoveryMapViewController(
            exploredHexStore: exploredHexStore,
            initialRegion: initialRegion
        )
    }

    func updateUIViewController(_ uiViewController: DiscoveryMapViewController, context: Context) {
        uiViewController.updateFogRevision(exploredHexStore.revision)
    }
}

struct DiscoveryMapScreen: View {
    @ObservedObject var exploredHexStore: ExploredHexStore
    let initialRegion: MKCoordinateRegion?

    var body: some View {
        DiscoveryMapViewControllerRepresentable(
            exploredHexStore: exploredHexStore,
            initialRegion: initialRegion
        )
        .ignoresSafeArea()
    }
}
