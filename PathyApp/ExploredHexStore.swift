//
//  ExploredHexStore.swift
//  PathyApp
//

import Combine
import CoreLocation
import Foundation
import SwiftData

final class ExploredHexStore: ObservableObject {
    @Published private(set) var revision = 0

    private let lock = NSLock()
    private var modelContext: ModelContext?
    private var cache: [ExploredHexCacheEntry] = []
    private var knownHexIDs: Set<String> = []
    private var lastIndexedAt: Date?
    private let indexThrottle: TimeInterval = 5

    private struct ExploredHexCacheEntry: Sendable {
        let hexId: String
        let centerLatitude: Double
        let centerLongitude: Double
        let boundary: [CLLocationCoordinate2D]
    }

    @MainActor
    func reloadFromDatabase() {
        reloadCache()
    }

    @MainActor
    func attach(modelContext: ModelContext) {
        self.modelContext = modelContext
        reloadCache()
    }

    @MainActor
    func backfillFromTracksIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "didBackfillExploredHexes") else { return }
        guard let modelContext else { return }

        let tracks = (try? modelContext.fetch(FetchDescriptor<Track>())) ?? []
        guard !tracks.isEmpty else {
            defaults.set(true, forKey: "didBackfillExploredHexes")
            return
        }

        Task { @MainActor in
            await indexCoordinates(tracks.flatMap(\.coordinates), persistBatchSize: 500)
            defaults.set(true, forKey: "didBackfillExploredHexes")
        }
    }

    @MainActor
    func indexCoordinate(_ coordinate: CLLocationCoordinate2D, throttle: Bool = false) {
        if throttle {
            let now = Date()
            if let lastIndexedAt, now.timeIntervalSince(lastIndexedAt) < indexThrottle {
                return
            }
            self.lastIndexedAt = now
        }
        guard let hexId = H3Indexing.hexId(latitude: coordinate.latitude, longitude: coordinate.longitude) else {
            return
        }
        insertHexIfNeeded(hexId: hexId)
    }

    @MainActor
    func indexCoordinates(_ coordinates: [TrackCoordinate]) {
        Task { @MainActor in
            await indexCoordinates(coordinates, persistBatchSize: 200)
        }
    }

    func exploredHexes(in bounds: MapTileBounds) -> [ExploredHexRenderData] {
        lock.lock()
        let snapshot = cache
        lock.unlock()

        return snapshot.compactMap { entry in
            guard bounds.intersects(
                center: CLLocationCoordinate2D(latitude: entry.centerLatitude, longitude: entry.centerLongitude),
                boundary: entry.boundary
            ) else {
                return nil
            }
            guard entry.boundary.count >= 3 else { return nil }
            return ExploredHexRenderData(hexId: entry.hexId, boundary: entry.boundary)
        }
    }

    func isExplored(hexId: String) -> Bool {
        lock.lock()
        let explored = knownHexIDs.contains(hexId)
        lock.unlock()
        return explored
    }

    @MainActor
    private func reloadCache() {
        guard let modelContext else {
            lock.lock()
            cache = []
            knownHexIDs = []
            lock.unlock()
            return
        }

        let descriptor = FetchDescriptor<ExploredHex>()
        let stored = (try? modelContext.fetch(descriptor)) ?? []
        let entries = stored.compactMap { explored -> ExploredHexCacheEntry? in
            guard let boundary = H3Indexing.boundaryCoordinates(for: explored.hexId), boundary.count >= 3 else {
                return nil
            }
            return ExploredHexCacheEntry(
                hexId: explored.hexId,
                centerLatitude: explored.centerLatitude,
                centerLongitude: explored.centerLongitude,
                boundary: boundary
            )
        }
        lock.lock()
        cache = entries
        knownHexIDs = Set(entries.map(\.hexId))
        lock.unlock()
    }

    @MainActor
    private func insertHexIfNeeded(hexId: String) {
        lock.lock()
        let alreadyKnown = knownHexIDs.contains(hexId)
        lock.unlock()
        guard !alreadyKnown else { return }
        guard let modelContext else { return }
        guard let center = H3Indexing.centerCoordinate(for: hexId) else { return }
        guard let boundary = H3Indexing.boundaryCoordinates(for: hexId), boundary.count >= 3 else { return }

        let explored = ExploredHex(
            hexId: hexId,
            centerLatitude: center.latitude,
            centerLongitude: center.longitude
        )
        modelContext.insert(explored)

        let entry = ExploredHexCacheEntry(
            hexId: hexId,
            centerLatitude: center.latitude,
            centerLongitude: center.longitude,
            boundary: boundary
        )
        lock.lock()
        knownHexIDs.insert(hexId)
        cache.append(entry)
        let shouldSave = knownHexIDs.count.isMultiple(of: 25)
        lock.unlock()

        revision &+= 1

        if shouldSave {
            try? modelContext.save()
        }
    }

    @MainActor
    private func indexCoordinates(_ coordinates: [TrackCoordinate], persistBatchSize: Int) async {
        guard let modelContext else { return }

        var insertedSinceSave = 0
        for coordinate in coordinates {
            guard let hexId = H3Indexing.hexId(latitude: coordinate.latitude, longitude: coordinate.longitude) else {
                continue
            }

            lock.lock()
            let alreadyKnown = knownHexIDs.contains(hexId)
            lock.unlock()
            guard !alreadyKnown else { continue }
            guard let center = H3Indexing.centerCoordinate(for: hexId) else { continue }
            guard let boundary = H3Indexing.boundaryCoordinates(for: hexId), boundary.count >= 3 else { continue }

            let explored = ExploredHex(
                hexId: hexId,
                centerLatitude: center.latitude,
                centerLongitude: center.longitude
            )
            modelContext.insert(explored)

            let entry = ExploredHexCacheEntry(
                hexId: hexId,
                centerLatitude: center.latitude,
                centerLongitude: center.longitude,
                boundary: boundary
            )
            lock.lock()
            knownHexIDs.insert(hexId)
            cache.append(entry)
            lock.unlock()

            insertedSinceSave += 1
            if insertedSinceSave.isMultiple(of: persistBatchSize) {
                try? modelContext.save()
                revision &+= 1
            }
        }

        try? modelContext.save()
        revision &+= 1
    }
}
