//
//  Persistence.swift
//  PathyApp
//

import Foundation
import SwiftData

enum PersistenceController {
    static let sharedContainer: ModelContainer = {
        do {
            let schema = Schema([Track.self, TrackPoint.self])
            let baseURL = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let storeURL = baseURL.appendingPathComponent("Pathy.store")
            let configuration = ModelConfiguration(schema: schema, url: storeURL)
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Unable to initialize persistent store: \(error.localizedDescription)")
        }
    }()
}
