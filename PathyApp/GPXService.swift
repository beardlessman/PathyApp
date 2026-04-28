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
        guard !points.isEmpty else {
            throw NSError(domain: "GPXImport", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "No track points found in selected GPX file."
            ])
        }
        let track = Track(name: url.deletingPathExtension().lastPathComponent, startedAt: .now)
        modelContext.insert(track)
        track.replaceCoordinates(points)
        track.finishedAt = .now
        try modelContext.save()
        return track
    }

    static func parseGPX(data: Data) throws -> [TrackCoordinate] {
        let parser = GPXParser(data: data)
        return try parser.parse()
    }

    static func importParsedPoints(_ points: [TrackCoordinate], trackName: String, modelContext: ModelContext) throws -> Track {
        let track = Track(name: trackName, startedAt: .now)
        modelContext.insert(track)
        track.replaceCoordinates(points)
        track.finishedAt = .now
        try modelContext.save()
        return track
    }

    private static func buildDocument(track: Track) -> String {
        let pointsXML = track.coordinates
            .map { point in
                """
                <trkpt lat="\(point.latitude)" lon="\(point.longitude)"></trkpt>
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

private final class GPXParser: NSObject, XMLParserDelegate {
    private let parser: XMLParser
    private var points: [TrackCoordinate] = []
    private var currentLat: Double?
    private var currentLon: Double?
    private var currentValue = ""

    init(data: Data) {
        parser = XMLParser(data: data)
        super.init()
        parser.delegate = self
    }

    func parse() throws -> [TrackCoordinate] {
        guard parser.parse() else {
            throw parser.parserError ?? NSError(domain: "GPXParser", code: 1)
        }
        return points
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentValue = ""
        let name = elementName.lowercased()
        if name == "trkpt" || name == "rtept" || name == "wpt" {
            currentLat = Double(attributeDict["lat"] ?? "")
            currentLon = Double(attributeDict["lon"] ?? "")
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentValue += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName.lowercased() {
        case "trkpt", "rtept", "wpt":
            guard let lat = currentLat, let lon = currentLon else { return }
            let point = TrackCoordinate(latitude: lat, longitude: lon)
            points.append(point)
        default:
            break
        }
    }
}
