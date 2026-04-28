//
//  Persistence.swift
//  PathyApp
//

import Foundation
import SwiftData

enum PersistenceController {
    private static let migrationFlagKey = "didRunBlobOnlyMigrationV1"

    static let sharedContainer: ModelContainer = {
        do {
            let schema = Schema([Track.self])
            let baseURL = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let storeURL = baseURL.appendingPathComponent("Pathy.store")
            runOneTimeCleanMigrationIfNeeded(storeURL: storeURL)
            let configuration = ModelConfiguration(schema: schema, url: storeURL)
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Unable to initialize persistent store: \(error.localizedDescription)")
        }
    }()

    private static func runOneTimeCleanMigrationIfNeeded(storeURL: URL) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationFlagKey) else { return }

        let fileManager = FileManager.default
        let candidates = [
            storeURL,
            storeURL.appendingPathExtension("wal"),
            storeURL.appendingPathExtension("shm")
        ]

        for url in candidates where fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }

        defaults.set(true, forKey: migrationFlagKey)
    }
}
