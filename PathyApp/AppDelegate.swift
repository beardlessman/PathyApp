//
//  AppDelegate.swift
//  PathyApp
//

import UIKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        LocationTracker.shared.handleDidFinishLaunching()
        return true
    }

    func applicationWillResignActive(_ application: UIApplication) {
        LocationTracker.shared.beginBackgroundBridgeForLocationHandoff()
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        LocationTracker.shared.endBackgroundBridgeForLocationHandoff()
        LocationTracker.shared.handleAppBecameActive()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        LocationTracker.shared.scheduleEndBackgroundBridgeAfterLocationHandoff()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
