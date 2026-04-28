//
//  TrackBackupService.swift
//  PathyApp
//

import Foundation
import SwiftData

enum TrackBackupService {
    private static let backupFolderName = "TrackBackups"

    static func backup(track: Track) throws {
        guard !track.coordinates.isEmpty else { return }
        let backupURL = try backupDirectory()
            .appendingPathComponent("\(track.id.uuidString).json")
        let payload = TrackBackupPayload(
            id: track.id,
            name: track.name,
            startedAt: track.startedAt,
            finishedAt: track.finishedAt,
            coordinates: track.coordinates
        )
        let data = try JSONEncoder().encode(payload)
        try data.write(to: backupURL, options: .atomic)
    }

    static func removeBackup(trackID: UUID) {
        guard let directory = try? backupDirectory() else { return }
        let url = directory.appendingPathComponent("\(trackID.uuidString).json")
        try? FileManager.default.removeItem(at: url)
    }

    static func restoreIfNeeded(modelContext: ModelContext) throws -> Int {
        let descriptor = FetchDescriptor<Track>()
        let existingCount = try modelContext.fetchCount(descriptor)
        guard existingCount == 0 else { return 0 }

        let directory = try backupDirectory()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "json" }
        guard !files.isEmpty else { return 0 }

        let decoder = JSONDecoder()
        var restored = 0
        for fileURL in files {
            let data = try Data(contentsOf: fileURL)
            let payload = try decoder.decode(TrackBackupPayload.self, from: data)
            let track = Track(name: payload.name, startedAt: payload.startedAt)
            track.id = payload.id
            track.finishedAt = payload.finishedAt
            track.replaceCoordinates(payload.coordinates)
            modelContext.insert(track)
            restored += 1
        }
        try modelContext.save()
        return restored
    }

    private static func backupDirectory() throws -> URL {
        let baseURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let backupURL = baseURL.appendingPathComponent(backupFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: backupURL, withIntermediateDirectories: true)
        return backupURL
    }
}

private struct TrackBackupPayload: Codable {
    let id: UUID
    let name: String
    let startedAt: Date
    let finishedAt: Date?
    let coordinates: [TrackCoordinate]
}
