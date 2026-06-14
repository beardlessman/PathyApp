//
//  GPXService.swift
//  PathyApp
//

import Foundation
import SwiftData

struct GPXBatchImportError: LocalizedError {
    let partiallyImported: [Track]
    let failures: [String]

    var errorDescription: String? {
        "Imported \(partiallyImported.count) track(s). Some files failed:\n" + failures.joined(separator: "\n")
    }
}

enum GPXService {
    static func export(track: Track) throws -> URL {
        let safeName = track.name.replacingOccurrences(of: " ", with: "_")
        let filename = "\(safeName)_\(Int(track.startedAt.timeIntervalSince1970)).gpx"
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try buildDocument(track: track).write(to: destination, atomically: true, encoding: .utf8)
        return destination
    }

    static func exportAllAsZip(tracks: [Track]) throws -> URL {
        let sortedTracks = tracks.sorted { lhs, rhs in
            let lhsTime = exportSortDate(for: lhs)
            let rhsTime = exportSortDate(for: rhs)
            if lhsTime != rhsTime {
                return lhsTime > rhsTime
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        var entries: [ZipArchive.Entry] = []
        entries.reserveCapacity(sortedTracks.count)
        for (index, track) in sortedTracks.enumerated() {
            let safeName = track.name
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: " ", with: "_")
            let filename = String(format: "%03d_%@.gpx", index + 1, safeName)
            let data = buildDocument(track: track).data(using: .utf8) ?? Data()
            entries.append(.init(filename: filename, data: data))
        }

        let exportTimestamp = zipFilenameDateFormatter.string(from: .now)
        let zipFilename = "pathy-tracks-\(exportTimestamp).zip"
        let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent(zipFilename)
        try ZipArchive.create(zipURL: zipURL, entries: entries)
        return zipURL
    }

    private static func exportSortDate(for track: Track) -> Date {
        track.coordinates.compactMap(\.timestamp).min() ?? track.startedAt
    }

    static func `import`(
        from url: URL,
        modelContext: ModelContext,
        saveImmediately: Bool = true
    ) throws -> Track {
        let data = try Data(contentsOf: url)
        let parsed = try parseGPXDocument(data: data)
        let points = parsed.points
        guard !points.isEmpty else {
            throw NSError(domain: "GPXImport", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "No track points found in selected GPX file."
            ])
        }
        let timestamps = points.compactMap(\.timestamp)
        let startedAt = timestamps.min() ?? .now
        let finishedAt = timestamps.max() ?? startedAt
        let trackName = TrackNameFormatter.importedTrackName(from: startedAt)
        let track = Track(name: trackName, startedAt: startedAt)
        modelContext.insert(track)
        track.replaceCoordinates(points)
        track.finishedAt = finishedAt
        if saveImmediately {
            try modelContext.save()
        }
        return track
    }

    static func importTracks(from urls: [URL], modelContext: ModelContext) throws -> [Track] {
        var imported: [Track] = []
        imported.reserveCapacity(urls.count)
        var failures: [String] = []

        for url in urls.sorted(by: { lhs, rhs in
            lhs.deletingPathExtension().lastPathComponent.localizedStandardCompare(
                rhs.deletingPathExtension().lastPathComponent
            ) == .orderedAscending
        }) {
            do {
                imported.append(try Self.import(from: url, modelContext: modelContext, saveImmediately: false))
            } catch {
                failures.append("\(url.deletingPathExtension().lastPathComponent): \(error.localizedDescription)")
            }
        }

        if !imported.isEmpty {
            try modelContext.save()
        }

        if imported.isEmpty {
            let message = failures.isEmpty
                ? "No GPX files were imported."
                : failures.joined(separator: "\n")
            throw NSError(domain: "GPXImport", code: 3, userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }

        if !failures.isEmpty {
            throw GPXBatchImportError(partiallyImported: imported, failures: failures)
        }

        return imported
    }

    static func parseGPX(data: Data) throws -> [TrackCoordinate] {
        try parseGPXDocument(data: data).points
    }

    private static func parseGPXDocument(data: Data) throws -> ParsedGPX {
        let parser = GPXParser(data: data)
        return try parser.parse()
    }

    static func importParsedPoints(_ points: [TrackCoordinate], trackName: String, modelContext: ModelContext) throws -> Track {
        let timestamps = points.compactMap(\.timestamp)
        let startedAt = timestamps.min() ?? .now
        let finishedAt = timestamps.max() ?? startedAt
        let track = Track(name: trackName, startedAt: startedAt)
        modelContext.insert(track)
        track.replaceCoordinates(points)
        track.finishedAt = finishedAt
        try modelContext.save()
        return track
    }

    private static func buildDocument(track: Track) -> String {
        let pointsXML = track.coordinates
            .map { segment in
                var pointInnerParts: [String] = []

                if let timestamp = segment.timestamp {
                    pointInnerParts.append("  <time>\(gpxDateFormatter.string(from: timestamp))</time>")
                }

                var extensionFields: [String] = []
                if let course = segment.course {
                    extensionFields.append("<gom:course>\(course)</gom:course>")
                }
                if let speed = segment.speed {
                    extensionFields.append("<pathy:speed>\(speed)</pathy:speed>")
                }
                if let hAccuracy = segment.horizontalAccuracy {
                    extensionFields.append("<pathy:hAccuracy>\(hAccuracy)</pathy:hAccuracy>")
                }

                if !extensionFields.isEmpty {
                    pointInnerParts.append("  <extensions>\(extensionFields.joined())</extensions>")
                }

                if pointInnerParts.isEmpty {
                    return """
                    <trkpt lat="\(segment.latitude)" lon="\(segment.longitude)"></trkpt>
                    """
                }

                return """
                <trkpt lat="\(segment.latitude)" lon="\(segment.longitude)">
                \(pointInnerParts.joined(separator: "\n"))
                </trkpt>
                """
            }
            .joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="PathyApp" xmlns="http://www.topografix.com/GPX/1/1" xmlns:gom="https://gurumaps.app/xmlschemas/GuruMapsExtensions/v1" xmlns:pathy="https://pathy.app/xmlschemas/extensions/v1">
          <trk>
            <name>\(track.name)</name>
            <trkseg>
        \(pointsXML)
            </trkseg>
          </trk>
        </gpx>
        """
    }

    private static let gpxDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let zipFilenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        return formatter
    }()
}

private enum ZipArchive {
    struct Entry {
        let filename: String
        let data: Data
    }

    static func create(zipURL: URL, entries: [Entry]) throws {
        var archive = Data()
        var centralDirectory = Data()
        var localHeaderOffsets: [UInt32] = []
        localHeaderOffsets.reserveCapacity(entries.count)

        for entry in entries {
            let filenameData = Data(entry.filename.utf8)
            let crc = CRC32.checksum(entry.data)
            let size = UInt32(entry.data.count)
            let localOffset = UInt32(archive.count)
            localHeaderOffsets.append(localOffset)

            // Local file header
            archive.appendLE(UInt32(0x0403_4b50))
            archive.appendLE(UInt16(20)) // Version needed
            archive.appendLE(UInt16(0)) // General purpose bit flag
            archive.appendLE(UInt16(0)) // Compression method (store)
            archive.appendLE(UInt16(0)) // Last mod time
            archive.appendLE(UInt16(0)) // Last mod date
            archive.appendLE(crc)
            archive.appendLE(size) // Compressed size
            archive.appendLE(size) // Uncompressed size
            archive.appendLE(UInt16(filenameData.count))
            archive.appendLE(UInt16(0)) // Extra field length
            archive.append(filenameData)
            archive.append(entry.data)
        }

        for (index, entry) in entries.enumerated() {
            let filenameData = Data(entry.filename.utf8)
            let crc = CRC32.checksum(entry.data)
            let size = UInt32(entry.data.count)

            // Central directory file header
            centralDirectory.appendLE(UInt32(0x0201_4b50))
            centralDirectory.appendLE(UInt16(20)) // Version made by
            centralDirectory.appendLE(UInt16(20)) // Version needed
            centralDirectory.appendLE(UInt16(0)) // General purpose bit flag
            centralDirectory.appendLE(UInt16(0)) // Compression method (store)
            centralDirectory.appendLE(UInt16(0)) // Last mod time
            centralDirectory.appendLE(UInt16(0)) // Last mod date
            centralDirectory.appendLE(crc)
            centralDirectory.appendLE(size)
            centralDirectory.appendLE(size)
            centralDirectory.appendLE(UInt16(filenameData.count))
            centralDirectory.appendLE(UInt16(0)) // Extra field length
            centralDirectory.appendLE(UInt16(0)) // File comment length
            centralDirectory.appendLE(UInt16(0)) // Disk number start
            centralDirectory.appendLE(UInt16(0)) // Internal file attributes
            centralDirectory.appendLE(UInt32(0)) // External file attributes
            centralDirectory.appendLE(localHeaderOffsets[index])
            centralDirectory.append(filenameData)
        }

        let centralDirectoryOffset = UInt32(archive.count)
        archive.append(centralDirectory)

        // End of central directory record
        archive.appendLE(UInt32(0x0605_4b50))
        archive.appendLE(UInt16(0)) // Number of this disk
        archive.appendLE(UInt16(0)) // Number of disk with central directory
        archive.appendLE(UInt16(entries.count))
        archive.appendLE(UInt16(entries.count))
        archive.appendLE(UInt32(centralDirectory.count))
        archive.appendLE(centralDirectoryOffset)
        archive.appendLE(UInt16(0)) // ZIP file comment length

        try archive.write(to: zipURL, options: .atomic)
    }
}

private enum CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { i in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) == 1 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let idx = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[idx] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}

private struct ParsedGPX {
    let trackName: String?
    let points: [TrackCoordinate]
}

private final class GPXParser: NSObject, XMLParserDelegate {
    private let parser: XMLParser
    private var points: [TrackCoordinate] = []
    private var currentLat: Double?
    private var currentLon: Double?
    private var currentCourse: Double?
    private var currentSpeed: Double?
    private var currentHorizontalAccuracy: Double?
    private var currentTimestamp: Date?
    private var currentValue = ""
    private var parsedTrackName: String?
    private var insideTrack = false
    private var insideRoute = false

    init(data: Data) {
        parser = XMLParser(data: data)
        super.init()
        parser.delegate = self
    }

    func parse() throws -> ParsedGPX {
        guard parser.parse() else {
            throw parser.parserError ?? NSError(domain: "GPXParser", code: 1)
        }
        return ParsedGPX(trackName: parsedTrackName, points: points)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentValue = ""
        let name = elementName.lowercased()
        if name == "trk" {
            insideTrack = true
        } else if name == "rte" {
            insideRoute = true
        }

        if name == "trkpt" || name == "rtept" || name == "wpt" {
            currentLat = Double(attributeDict["lat"] ?? "")
            currentLon = Double(attributeDict["lon"] ?? "")
            currentCourse = nil
            currentSpeed = nil
            currentHorizontalAccuracy = nil
            currentTimestamp = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentValue += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let element = (qName ?? elementName).lowercased()
        switch element {
        case "name":
            if parsedTrackName == nil, insideTrack || insideRoute {
                let value = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    parsedTrackName = value
                }
            }
        case "course", "gom:course":
            let value = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
            currentCourse = Double(value)
        case "speed", "pathy:speed", "gom:speed":
            let value = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
            currentSpeed = Double(value)
        case "haccuracy", "horizontalaccuracy", "pathy:haccuracy", "gom:haccuracy":
            let value = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
            currentHorizontalAccuracy = Double(value)
        case "time":
            let value = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
            currentTimestamp = GPXDateParser.parse(value)
        case "trkpt", "rtept", "wpt":
            guard let lat = currentLat, let lon = currentLon else { return }
            let point = TrackCoordinate(
                latitude: lat,
                longitude: lon,
                course: currentCourse,
                speed: currentSpeed,
                horizontalAccuracy: currentHorizontalAccuracy,
                timestamp: currentTimestamp
            )
            points.append(point)
        case "trk":
            insideTrack = false
        case "rte":
            insideRoute = false
        default:
            break
        }
    }
}


private enum GPXDateParser {
    private static let formatterWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ value: String) -> Date? {
        formatterWithFractional.date(from: value) ?? formatter.date(from: value)
    }
}
