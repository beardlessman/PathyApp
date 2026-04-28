//
//  GPXService.swift
//  PathyApp
//

import Foundation
import SwiftData

enum GPXService {
    static func export(track: Track) throws -> URL {
        let safeName = track.name.replacingOccurrences(of: " ", with: "_")
        let filename = "\(safeName)_\(Int(track.startedAt.timeIntervalSince1970)).gpx"
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try buildDocument(track: track).write(to: destination, atomically: true, encoding: .utf8)
        return destination
    }

    static func `import`(from url: URL, modelContext: ModelContext) throws -> Track {
        let data = try Data(contentsOf: url)
        let points = try parseGPX(data: data)
        let track = Track(name: url.deletingPathExtension().lastPathComponent, startedAt: points.first?.timestamp ?? .now)
        modelContext.insert(track)
        points.forEach { gpxPoint in
            let point = TrackPoint(
                timestamp: gpxPoint.timestamp,
                latitude: gpxPoint.latitude,
                longitude: gpxPoint.longitude,
                altitude: gpxPoint.altitude,
                horizontalAccuracy: 10,
                speed: -1,
                course: -1,
                track: track
            )
            modelContext.insert(point)
            track.points.append(point)
        }
        track.finishedAt = points.last?.timestamp
        try modelContext.save()
        return track
    }

    static func parseGPX(data: Data) throws -> [GPXPoint] {
        let parser = GPXParser(data: data)
        return try parser.parse()
    }

    static func importParsedPoints(_ points: [GPXPoint], trackName: String, modelContext: ModelContext) throws -> Track {
        let track = Track(name: trackName, startedAt: points.first?.timestamp ?? .now)
        modelContext.insert(track)
        points.forEach { gpxPoint in
            let point = TrackPoint(
                timestamp: gpxPoint.timestamp,
                latitude: gpxPoint.latitude,
                longitude: gpxPoint.longitude,
                altitude: gpxPoint.altitude,
                horizontalAccuracy: 10,
                speed: -1,
                course: -1,
                track: track
            )
            modelContext.insert(point)
            track.points.append(point)
        }
        track.finishedAt = points.last?.timestamp
        try modelContext.save()
        return track
    }

    private static func buildDocument(track: Track) -> String {
        let formatter = ISO8601DateFormatter()
        let pointsXML = track.points
            .sorted(by: { $0.timestamp < $1.timestamp })
            .map { point in
                """
                <trkpt lat="\(point.latitude)" lon="\(point.longitude)">
                  <ele>\(point.altitude)</ele>
                  <time>\(formatter.string(from: point.timestamp))</time>
                </trkpt>
                """
            }
            .joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="PathyApp" xmlns="http://www.topografix.com/GPX/1/1">
          <trk>
            <name>\(track.name)</name>
            <trkseg>
        \(pointsXML)
            </trkseg>
          </trk>
        </gpx>
        """
    }
}

struct GPXPoint: Sendable {
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    let altitude: Double
}

private final class GPXParser: NSObject, XMLParserDelegate {
    private let parser: XMLParser
    private var points: [GPXPoint] = []
    private var currentLat: Double?
    private var currentLon: Double?
    private var currentEle: Double = 0
    private var currentTime: Date = .now
    private var currentValue = ""
    private let dateFormatter = ISO8601DateFormatter()

    init(data: Data) {
        parser = XMLParser(data: data)
        super.init()
        parser.delegate = self
    }

    func parse() throws -> [GPXPoint] {
        guard parser.parse() else {
            throw parser.parserError ?? NSError(domain: "GPXParser", code: 1)
        }
        return points
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentValue = ""
        if elementName == "trkpt" {
            currentLat = Double(attributeDict["lat"] ?? "")
            currentLon = Double(attributeDict["lon"] ?? "")
            currentEle = 0
            currentTime = .now
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentValue += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "ele":
            currentEle = Double(value) ?? 0
        case "time":
            currentTime = dateFormatter.date(from: value) ?? .now
        case "trkpt":
            guard let lat = currentLat, let lon = currentLon else { return }
            let point = GPXPoint(
                timestamp: currentTime,
                latitude: lat,
                longitude: lon,
                altitude: currentEle
            )
            points.append(point)
        default:
            break
        }
    }
}
