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
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var locationTracker = LocationTracker.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(locationTracker)
        }
        .modelContainer(PersistenceController.sharedContainer)
    }
}
