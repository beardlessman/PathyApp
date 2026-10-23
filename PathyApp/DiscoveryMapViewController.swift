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
    private var tracksButton: DiscoveryRoundMapButton?
    private var mapControlsStack: UIStackView?
    private var revisionCancellable: AnyCancellable?
    private var lastFogRevision = -1
    private var pendingFogRevision: Int?
    private var shouldCenterOnUser = true
    private let discoveryZoomMeters: CLLocationDistance = 500

    var onOpenTracks: (() -> Void)?

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
        tracksButton?.removeFromSuperview()
        mapControlsStack?.removeFromSuperview()
        compassButton = nil
        trackingButton = nil
        tracksButton = nil
        mapControlsStack = nil
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
        let tracksButton = DiscoveryRoundMapButton(systemName: "list.bullet")
        tracksButton.addTarget(self, action: #selector(openTracksTapped), for: .touchUpInside)
        tracksButton.accessibilityLabel = "Треки"
        self.tracksButton = tracksButton

        let trackingButton = DiscoveryUserTrackingButton(mapView: mapView)
        self.trackingButton = trackingButton

        let compassButton = MKCompassButton(mapView: mapView)
        compassButton.compassVisibility = .adaptive
        self.compassButton = compassButton

        let controlsStack = UIStackView(arrangedSubviews: [tracksButton, trackingButton, compassButton])
        controlsStack.axis = .vertical
        controlsStack.alignment = .trailing
        controlsStack.spacing = 8
        controlsStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controlsStack)
        self.mapControlsStack = controlsStack

        NSLayoutConstraint.activate([
            controlsStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            controlsStack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
        ])
    }

    @objc private func openTracksTapped() {
        onOpenTracks?()
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

// MARK: - Map control buttons

private class DiscoveryRoundMapButton: UIControl {
    static let diameter: CGFloat = 44

    private let iconView = UIImageView()
    private let iconTint = UIColor(white: 0.12, alpha: 1)

    init(systemName: String) {
        super.init(frame: .zero)
        configure(systemName: systemName)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setSystemName(_ systemName: String) {
        let configuration = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        iconView.image = UIImage(systemName: systemName, withConfiguration: configuration)?
            .withRenderingMode(.alwaysTemplate)
    }

    private func configure(systemName: String) {
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .white
        layer.cornerRadius = Self.diameter / 2
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 2
        layer.shadowOffset = CGSize(width: 0, height: 1)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.tintColor = iconTint
        iconView.contentMode = .scaleAspectFit
        addSubview(iconView)
        setSystemName(systemName)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.diameter),
            heightAnchor.constraint(equalToConstant: Self.diameter),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),
        ])
    }
}

// MARK: - Custom user tracking button

/// Outline SF Symbol styling with the same tracking-mode cycle as `MKUserTrackingButton`.
private final class DiscoveryUserTrackingButton: DiscoveryRoundMapButton {
    private weak var mapView: MKMapView?

    init(mapView: MKMapView) {
        self.mapView = mapView
        super.init(systemName: "location")
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
        setSystemName(symbolName)
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
}

struct DiscoveryMapViewControllerRepresentable: UIViewControllerRepresentable {
    @ObservedObject var exploredHexStore: ExploredHexStore
    let initialRegion: MKCoordinateRegion?
    let onOpenTracks: () -> Void

    func makeUIViewController(context: Context) -> DiscoveryMapViewController {
        let controller = DiscoveryMapViewController(
            exploredHexStore: exploredHexStore,
            initialRegion: initialRegion
        )
        controller.onOpenTracks = onOpenTracks
        return controller
    }

    func updateUIViewController(_ uiViewController: DiscoveryMapViewController, context: Context) {
        uiViewController.onOpenTracks = onOpenTracks
        uiViewController.updateFogRevision(exploredHexStore.revision)
    }
}

struct DiscoveryMapScreen: View {
    @ObservedObject var exploredHexStore: ExploredHexStore
    let initialRegion: MKCoordinateRegion?
    let onOpenTracks: () -> Void

    var body: some View {
        DiscoveryMapViewControllerRepresentable(
            exploredHexStore: exploredHexStore,
            initialRegion: initialRegion,
            onOpenTracks: onOpenTracks
        )
        .ignoresSafeArea()
    }
}
