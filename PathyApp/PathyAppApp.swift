//
//  PathyAppApp.swift
//  PathyApp
//
//  Created by Dmitrii Mungalov on 28.04.2026.
//

import SwiftUI
import SwiftData

@main
struct PathyAppApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [Track.self, TrackPoint.self])
    }
}
