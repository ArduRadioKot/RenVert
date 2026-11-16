import Foundation
import AppKit
import CoreImage
import CoreText
import Vision

/// Conversions Consul does not do: GPS tracks, contacts, calendars, Base64, QR codes and font previews.
public struct BeyondConverter: Converter {
    public init() {}

    public static func handles(from: FormatID, to: FormatID) -> Bool {
        if from == to { return false }
        if from == .b64 || to == .b64 { return from != .folder && to != .folder }
        if geoFormats.contains(from) && (geoFormats.contains(to) || to == .csv || to == .json) { return true }
        if geoFormats.contains(to) && (from == .csv || from == .json) { return true }
        if from == .vcf && (to == .csv || to == .json) { return true }
        if to == .vcf && (from == .csv || from == .json) { return true }
        if from == .ics && (to == .csv || to == .json) { return true }
        if to == .ics && (from == .csv || from == .json) { return true }
        if (from == .ttf || from == .otf) && imageEncodable.contains(to) { return true }
        if bookmarkFormats.contains(from) && (bookmarkFormats.contains(to) || to == .txt || to == .json) { return true }
        if bookmarkFormats.contains(to) && (from == .txt || from == .json) { return true }
        if feedFormats.contains(from) && (feedFormats.contains(to) || to == .json) { return true }
        if feedFormats.contains(to) && from == .json { return true }
        if from != to, [.m3u, .cue, .txt, .json].contains(from), [.m3u, .cue, .txt, .json].contains(to),
           from == .m3u || to == .m3u || from == .cue || to == .cue {
            return true
        }
        if (from == .bib || to == .bib), from != to, from == .json || to == .json || from == .csv || to == .csv { return true }
        if (from == .ldif || to == .ldif), from != to, from == .json || to == .json || from == .csv || to == .csv { return true }
        if paletteFormats.contains(from) && (paletteFormats.contains(to) || to == .json) { return true }
        if paletteFormats.contains(to) && from == .json { return true }
        return false
    }

    public func convert(from source: URL, detected: FormatID, spec: OutputSpec, to destination: URL, context: ConversionContext) throws {
        try context.cancellation.throwIfCancelled()
        if spec.hasQR {
            try QRCode.convert(from: source, detected: detected, spec: spec, to: destination, settings: context.settings)
            return
        }
        if detected == .b64 || spec.format == .b64 {
            try Base64Text.convert(from: source, detected: detected, to: spec.format, destination: destination)
            return
        }
        if detected == .ttf || detected == .otf {
            try FontPreview.render(source, spec: spec, to: destination, settings: context.settings)
            return
        }
        if detected == .vcf || spec.format == .vcf {
            try Contacts.convert(from: source, detected: detected, to: spec.format, destination: destination)
            return
        }
        if detected == .ics || spec.format == .ics {
            try Calendars.convert(from: source, detected: detected, to: spec.format, destination: destination)
            return
        }
        if detected == .webloc || detected == .url || spec.format == .webloc || spec.format == .url {
            try Bookmarks.convert(from: source, detected: detected, to: spec.format, destination: destination)
            return
        }
        if detected == .rss || detected == .atom || spec.format == .rss || spec.format == .atom {
            try Feeds.convert(from: source, detected: detected, to: spec.format, destination: destination)
            return
        }
        if detected == .m3u || spec.format == .m3u || detected == .cue || spec.format == .cue {
            try Playlists.convert(from: source, detected: detected, to: spec.format, destination: destination)
            return
        }
        if detected == .bib || spec.format == .bib {
            try Bibliographies.convert(from: source, detected: detected, to: spec.format, destination: destination)
            return
        }
        if detected == .ldif || spec.format == .ldif {
            try Directories.convert(from: source, detected: detected, to: spec.format, destination: destination)
            return
        }
        if paletteFormats.contains(detected) || paletteFormats.contains(spec.format) {
            try Palettes.convert(from: source, detected: detected, to: spec.format, destination: destination)
            return
        }
        try GeoTracks.convert(from: source, detected: detected, to: spec.format, destination: destination)
        context.onProgress?(1)
    }
}

// MARK: - Base64

enum Base64Text {
    static func convert(from source: URL, detected: FormatID, to format: FormatID, destination: URL) throws {
        if format == .b64 {
            let text = try Data(contentsOf: source).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
            try (text + "\n").write(to: destination, atomically: true, encoding: .utf8)
            return
        }
        let raw = try String(contentsOf: source, encoding: .utf8).filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: raw) else {
            throw RenvertError.invalidInput(L("The file is not valid Base64."))
        }
        try data.write(to: destination)
        _ = detected
    }
}

// MARK: - QR

enum QRCode {
    static func canConvert(from: FormatID, to: FormatID) -> Bool {
        let source = FormatRegistry.descriptor(for: from).category
        let textual: Set<FormatCategory> = [.document, .config, .spreadsheet, .email, .subtitle, .geo]
        if textual.contains(source) && imageEncodable.contains(to) { return true }
        if (source == .image || from == .pdf) && to == .txt { return true }
        return false
    }

    static func convert(from source: URL, detected: FormatID, spec: OutputSpec, to destination: URL, settings: AppSettings) throws {
        if spec.format == .txt {
            let text = try decode(source)
            guard !text.isEmpty else { throw RenvertError.converterFailed(L("No QR code or barcode was found.")) }
            try text.write(to: destination, atomically: true, encoding: .utf8)
            return
        }
        let payload = DelimitedText.decode(try Data(contentsOf: source)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { throw RenvertError.invalidInput(L("There is no text to put in a QR code.")) }
        guard payload.utf8.count <= 2000 else {
            throw RenvertError.converterFailed(L("The text is too long for a QR code."))
        }
        let image = try encode(payload)
        if spec.format == .pdf {
            try ImageConverter().writePDF(image, to: destination, spec: spec, preserveMeta: false)
            return
        }
        guard let uti = ImageIOSupport.utType(for: spec.format) else {
            throw RenvertError.unsupportedConversion(from: detected.rawValue, to: spec.format.rawValue)
        }
        try ImageConverter().writeImage(image, to: destination, utType: uti, spec: spec, settings: settings)
    }

    private static func encode(_ text: String) throws -> NSImage {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
            throw RenvertError.converterFailed(L("QR codes are not available on this Mac."))
        }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let code = filter.outputImage else {
            throw RenvertError.converterFailed(L("Could not build a QR code."))
        }
        let scaled = code.transformed(by: CGAffineTransform(scaleX: 16, y: 16))
        let extent = scaled.extent.integral
        let margin = 32
        let size = NSSize(width: extent.width + CGFloat(margin * 2), height: extent.height + CGFloat(margin * 2))
        guard let cg = CIContext().createCGImage(scaled, from: extent) else {
            throw RenvertError.converterFailed(L("Could not build a QR code."))
        }
        return ImageRaster.bitmap(pixelSize: size) { _ in
            NSColor.white.setFill()
            NSRect(origin: .zero, size: size).fill()
            NSGraphicsContext.current?.cgContext.draw(
                cg,
                in: CGRect(x: CGFloat(margin), y: CGFloat(margin), width: extent.width, height: extent.height)
            )
        }
    }

    private static func decode(_ url: URL) throws -> String {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr, .aztec, .pdf417, .dataMatrix, .ean13, .ean8, .code128, .code39]
        let image: CIImage
        if url.pathExtension.lowercased() == "pdf", let page = CGPDFDocument(url as CFURL)?.page(at: 1) {
            let box = page.getBoxRect(.mediaBox)
            guard let ctx = CGContext(data: nil, width: Int(box.width * 2), height: Int(box.height * 2), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw RenvertError.invalidInput(L("Could not read the image."))
            }
            ctx.setFillColor(CGColor.white)
            ctx.fill(CGRect(x: 0, y: 0, width: box.width * 2, height: box.height * 2))
            ctx.scaleBy(x: 2, y: 2)
            ctx.drawPDFPage(page)
            image = CIImage(cgImage: ctx.makeImage()!)
        } else if let cg = ImageRaster.cgImage(at: url) {
            image = CIImage(cgImage: cg)
        } else {
            throw RenvertError.invalidInput(L("Could not read the image."))
        }
        try VNImageRequestHandler(ciImage: image).perform([request])
        let values = (request.results ?? []).compactMap { $0.payloadStringValue }.filter { !$0.isEmpty }
        return values.joined(separator: "\n")
    }
}

// MARK: - Fonts

enum FontPreview {
    static func render(_ url: URL, spec: OutputSpec, to destination: URL, settings: AppSettings) throws {
        var error: Unmanaged<CFError>?
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        defer { CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil) }
        let data = try Data(contentsOf: url)
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor],
              let descriptor = descriptors.first else {
            throw RenvertError.invalidInput(L("This font could not be read."))
        }
        let sample = CTFontCreateWithFontDescriptor(descriptor, 64, nil)
        let postScript = CTFontCopyPostScriptName(sample) as String
        let full = CTFontCopyFullName(sample) as String
        guard let font = NSFont(name: postScript, size: 72) ?? NSFont(name: full, size: 72) else {
            throw RenvertError.invalidInput(L("This font could not be read."))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        let title = NSAttributedString(string: full + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 28, weight: .medium),
            .foregroundColor: NSColor.black
        ])
        let body = NSAttributedString(string: "Aa Bb Cc Dd Ee Ff Gg Hh Ii Jj Kk Ll Mm\nNn Oo Pp Qq Rr Ss Tt Uu Vv Ww Xx Yy Zz\n0123456789  The quick brown fox jumps.", attributes: [
            .font: font,
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph
        ])
        let text = NSMutableAttributedString()
        text.append(title)
        text.append(body)
        let size = NSSize(width: 1400, height: 640)
        let image = ImageRaster.bitmap(pixelSize: size) { rect in
            NSColor.white.setFill()
            NSRect(origin: .zero, size: size).fill()
            text.draw(with: NSRect(x: 48, y: 48, width: rect.width - 96, height: rect.height - 96), options: [.usesLineFragmentOrigin])
        }
        guard let uti = ImageIOSupport.utType(for: spec.format) else {
            throw RenvertError.unsupportedConversion(from: "font", to: spec.format.rawValue)
        }
        try ImageConverter().writeImage(image, to: destination, utType: uti, spec: spec, settings: settings)
    }
}

// MARK: - Tracks

struct GeoPoint {
    var name: String = ""
    var latitude: Double
    var longitude: Double
    var elevation: String = ""
    var time: String = ""
}

enum GeoTracks {
    static func convert(from source: URL, detected: FormatID, to format: FormatID, destination: URL) throws {
        let points = try load(source, format: detected)
        guard !points.isEmpty else { throw RenvertError.invalidInput(L("No coordinates were found.")) }
        switch format {
        case .gpx: try writeGPX(points).write(to: destination, atomically: true, encoding: .utf8)
        case .kml: try writeKML(points).write(to: destination, atomically: true, encoding: .utf8)
        case .geojson: try writeGeoJSON(points).write(to: destination)
        case .csv: try DelimitedText.serialize(table(points), delimiter: ",").write(to: destination, atomically: true, encoding: .utf8)
        case .tcx: try writeTCX(points).write(to: destination, atomically: true, encoding: .utf8)
        case .nmea: try writeNMEA(points).write(to: destination, atomically: true, encoding: .utf8)
        case .igc: try writeIGC(points).write(to: destination, atomically: true, encoding: .utf8)
        case .json:
            let data = try JSONSerialization.data(withJSONObject: points.map(json), options: [.prettyPrinted, .sortedKeys])
            try data.write(to: destination)
        default:
            throw RenvertError.unsupportedConversion(from: detected.rawValue, to: format.rawValue)
        }
    }

    private static func load(_ url: URL, format: FormatID) throws -> [GeoPoint] {
        switch format {
        case .gpx, .kml, .tcx:
            let parser = GeoXMLParser()
            let xml = XMLParser(data: try Data(contentsOf: url))
            xml.delegate = parser
            guard xml.parse() else { throw RenvertError.invalidInput(L("The track file could not be read.")) }
            return parser.points
        case .geojson, .json:
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            return points(in: object)
        case .csv:
            return points(in: DelimitedText.parse(DelimitedText.decode(try Data(contentsOf: url)), delimiter: ","))
        case .nmea:
            return parseNMEA(DelimitedText.decode(try Data(contentsOf: url)))
        case .igc:
            return parseIGC(DelimitedText.decode(try Data(contentsOf: url)))
        default:
            throw RenvertError.unsupportedConversion(from: format.rawValue, to: "track")
        }
    }

    private static func table(_ points: [GeoPoint]) -> [[String]] {
        [["name", "latitude", "longitude", "elevation", "time"]] + points.map {
            [$0.name, format($0.latitude), format($0.longitude), $0.elevation, $0.time]
        }
    }

    private static func points(in rows: [[String]]) -> [GeoPoint] {
        guard let headers = rows.first else { return [] }
        func column(_ names: [String]) -> Int? {
            headers.firstIndex { names.contains($0.trimmingCharacters(in: .whitespaces).lowercased()) }
        }
        guard let lat = column(["latitude", "lat"]), let lon = column(["longitude", "lon", "lng"]) else { return [] }
        let name = column(["name", "title"])
        let ele = column(["elevation", "ele", "alt", "altitude"])
        let time = column(["time", "timestamp"])
        return rows.dropFirst().compactMap { row in
            guard lat < row.count, lon < row.count, let latitude = Double(row[lat]), let longitude = Double(row[lon]) else { return nil }
            return GeoPoint(
                name: name.flatMap { $0 < row.count ? row[$0] : nil } ?? "",
                latitude: latitude, longitude: longitude,
                elevation: ele.flatMap { $0 < row.count ? row[$0] : nil } ?? "",
                time: time.flatMap { $0 < row.count ? row[$0] : nil } ?? ""
            )
        }
    }

    private static func points(in object: Any) -> [GeoPoint] {
        if let list = object as? [Any] { return list.flatMap { points(in: $0) } }
        guard let record = object as? [String: Any] else { return [] }
        if let features = record["features"] as? [Any] { return features.flatMap { points(in: $0) } }
        if let geometry = record["geometry"] { return points(in: geometry).map { point in
            var copy = point
            if let properties = record["properties"] as? [String: Any] {
                copy.name = properties["name"] as? String ?? copy.name
                if let ele = properties["elevation"] { copy.elevation = string(ele) }
                if let time = properties["time"] as? String { copy.time = time }
            }
            return copy
        } }
        if let coordinates = record["coordinates"] as? [Any] {
            let type = (record["type"] as? String)?.lowercased() ?? ""
            if type == "point" || coordinates.first is NSNumber {
                if let point = point(from: coordinates, name: record["name"] as? String ?? "") { return [point] }
            }
            return coordinates.flatMap { item -> [GeoPoint] in
                if let pair = item as? [Any], let point = point(from: pair, name: "") { return [point] }
                return points(in: item)
            }
        }
        return []
    }

    private static func point(from coordinates: [Any], name: String) -> GeoPoint? {
        guard coordinates.count >= 2, let lon = double(coordinates[0]), let lat = double(coordinates[1]) else { return nil }
        return GeoPoint(name: name, latitude: lat, longitude: lon, elevation: coordinates.count > 2 ? string(coordinates[2]) : "")
    }

    private static func json(_ point: GeoPoint) -> [String: Any] {
        var item: [String: Any] = ["latitude": point.latitude, "longitude": point.longitude]
        if !point.name.isEmpty { item["name"] = point.name }
        if let elevation = Double(point.elevation) { item["elevation"] = elevation }
        if !point.time.isEmpty { item["time"] = point.time }
        return item
    }

    private static func writeGPX(_ points: [GeoPoint]) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<gpx version=\"1.1\" creator=\"Renvert\" xmlns=\"http://www.topografix.com/GPX/1/1\">\n<trk><name>Track</name><trkseg>\n"
        for point in points {
            xml += "<trkpt lat=\"\(format(point.latitude))\" lon=\"\(format(point.longitude))\">"
            if !point.elevation.isEmpty { xml += "<ele>\(escape(point.elevation))</ele>" }
            if !point.time.isEmpty { xml += "<time>\(escape(point.time))</time>" }
            if !point.name.isEmpty { xml += "<name>\(escape(point.name))</name>" }
            xml += "</trkpt>\n"
        }
        xml += "</trkseg></trk>\n</gpx>\n"
        return xml
    }

    private static func writeKML(_ points: [GeoPoint]) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<kml xmlns=\"http://www.opengis.net/kml/2.2\"><Document>\n"
        for point in points {
            let ele = point.elevation.isEmpty ? "0" : point.elevation
            xml += "<Placemark><name>\(escape(point.name))</name><Point><coordinates>\(format(point.longitude)),\(format(point.latitude)),\(escape(ele))</coordinates></Point></Placemark>\n"
        }
        xml += "</Document></kml>\n"
        return xml
    }

    private static func writeTCX(_ points: [GeoPoint]) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<TrainingCenterDatabase xmlns=\"http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2\"><Activities><Activity Sport=\"Other\"><Id>Renvert</Id><Lap><Track>\n"
        for point in points {
            xml += "<Trackpoint>"
            if !point.time.isEmpty { xml += "<Time>\(escape(point.time))</Time>" }
            xml += "<Position><LatitudeDegrees>\(format(point.latitude))</LatitudeDegrees><LongitudeDegrees>\(format(point.longitude))</LongitudeDegrees></Position>"
            if !point.elevation.isEmpty { xml += "<AltitudeMeters>\(escape(point.elevation))</AltitudeMeters>" }
            xml += "</Trackpoint>\n"
        }
        xml += "</Track></Lap></Activity></Activities></TrainingCenterDatabase>\n"
        return xml
    }

    private static func writeGeoJSON(_ points: [GeoPoint]) throws -> Data {
        let features: [[String: Any]] = points.map { point in
            var properties: [String: Any] = [:]
            if !point.name.isEmpty { properties["name"] = point.name }
            if let elevation = Double(point.elevation) { properties["elevation"] = elevation }
            if !point.time.isEmpty { properties["time"] = point.time }
            var coordinates: [Any] = [point.longitude, point.latitude]
            if let elevation = Double(point.elevation) { coordinates.append(elevation) }
            return [
                "type": "Feature",
                "properties": properties,
                "geometry": ["type": "Point", "coordinates": coordinates]
            ]
        }
        return try JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "features": features], options: [.prettyPrinted, .sortedKeys])
    }

    private static func format(_ value: Double) -> String {
        var text = String(format: "%.7f", value)
        while text.contains(".") && (text.hasSuffix("0") || text.hasSuffix(".")) { text.removeLast() }
        return text
    }

    private static func double(_ value: Any) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private static func string(_ value: Any) -> String {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }

    private static func parseNMEA(_ text: String) -> [GeoPoint] {
        var points: [GeoPoint] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = String(raw).trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("$") else { continue }
            if let star = line.firstIndex(of: "*") { line = String(line[..<star]) }
            let fields = line.dropFirst().split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard let kind = fields.first else { continue }
            if kind.hasSuffix("GGA"), fields.count > 9,
               let latitude = nmeaCoordinate(fields[2], fields[3]),
               let longitude = nmeaCoordinate(fields[4], fields[5]) {
                points.append(GeoPoint(latitude: latitude, longitude: longitude, elevation: fields[9], time: fields[1]))
            } else if kind.hasSuffix("RMC"), fields.count > 6, fields[2] == "A",
                      let latitude = nmeaCoordinate(fields[3], fields[4]),
                      let longitude = nmeaCoordinate(fields[5], fields[6]) {
                points.append(GeoPoint(latitude: latitude, longitude: longitude, time: fields[1]))
            }
        }
        return points
    }

    private static func nmeaCoordinate(_ raw: String, _ hemisphere: String) -> Double? {
        guard let value = Double(raw), !raw.isEmpty else { return nil }
        let degrees = floor(value / 100)
        var decimal = degrees + (value - degrees * 100) / 60
        if hemisphere == "S" || hemisphere == "W" { decimal = -decimal }
        return decimal
    }

    private static func parseIGC(_ text: String) -> [GeoPoint] {
        var points: [GeoPoint] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            guard line.count >= 35, line.hasPrefix("B") else { continue }
            let chars = Array(line)
            guard chars.count >= 35,
                  let latitude = igcDegrees(String(chars[7...13]), latitude: true, hemisphere: chars[14]),
                  let longitude = igcDegrees(String(chars[15...22]), latitude: false, hemisphere: chars[23]) else { continue }
            let altitude = Int(String(chars[30...34])) ?? 0
            points.append(GeoPoint(
                latitude: latitude,
                longitude: longitude,
                elevation: altitude == 0 ? "" : String(altitude),
                time: String(chars[1...6])
            ))
        }
        return points
    }

    private static func igcDegrees(_ raw: String, latitude: Bool, hemisphere: Character) -> Double? {
        let degreeCount = latitude ? 2 : 3
        guard raw.count == degreeCount + 5,
              let degrees = Double(raw.prefix(degreeCount)),
              let minutes = Double(raw.dropFirst(degreeCount)) else { return nil }
        var value = degrees + (minutes / 1000) / 60
        if hemisphere == "S" || hemisphere == "W" { value = -value }
        return value
    }

    private static func writeNMEA(_ points: [GeoPoint]) -> String {
        points.map { point in
            let latitude = nmeaField(point.latitude, latitude: true)
            let longitude = nmeaField(point.longitude, latitude: false)
            let elevation = point.elevation.isEmpty ? "0" : point.elevation
            let time = point.time.count == 6 ? point.time : "000000"
            let body = "GPGGA,\(time),\(latitude),\(longitude),1,08,0.9,\(elevation),M,,"
            let checksum = body.utf8.reduce(UInt8(0)) { $0 ^ $1 }
            return "$\(body)*\(String(format: "%02X", checksum))"
        }.joined(separator: "\n") + "\n"
    }

    private static func nmeaField(_ value: Double, latitude: Bool) -> String {
        let hemisphere = latitude ? (value < 0 ? "S" : "N") : (value < 0 ? "W" : "E")
        let absolute = abs(value)
        let degrees = Int(absolute)
        let minutes = (absolute - Double(degrees)) * 60
        let width = latitude ? 2 : 3
        return String(format: "%0\(width)d%07.4f,%@", degrees, minutes, hemisphere)
    }

    private static func writeIGC(_ points: [GeoPoint]) -> String {
        var lines = ["AXRenvert", "HFDTEDATE:010100"]
        for point in points {
            let latitude = igcField(point.latitude, latitude: true)
            let longitude = igcField(point.longitude, latitude: false)
            let time = point.time.count == 6 ? point.time : "000000"
            let altitude = min(99999, max(0, Int(point.elevation) ?? 0))
            lines.append(String(format: "B%@%@%@A%05d%05d", time, latitude, longitude, altitude, altitude))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func igcField(_ value: Double, latitude: Bool) -> String {
        let hemisphere: Character = latitude ? (value < 0 ? "S" : "N") : (value < 0 ? "W" : "E")
        let absolute = abs(value)
        let degrees = Int(absolute)
        let minutes = Int((((absolute - Double(degrees)) * 60) * 1000).rounded())
        if latitude { return String(format: "%02d%05d%@", degrees, minutes, String(hemisphere)) }
        return String(format: "%03d%05d%@", degrees, minutes, String(hemisphere))
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

final class GeoXMLParser: NSObject, XMLParserDelegate {
    var points: [GeoPoint] = []
    private var current: GeoPoint?
    private var text = ""
    private var trackpoint = false
    private var latitude: Double?
    private var longitude: Double?
    private var pendingElevation = ""
    private var pendingTime = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        text = ""
        let name = elementName.split(separator: ":").last.map(String.init)?.lowercased() ?? ""
        if name == "trackpoint" {
            trackpoint = true
            latitude = nil
            longitude = nil
            pendingElevation = ""
            pendingTime = ""
            return
        }
        if name == "wpt" || name == "trkpt" || name == "rtept",
           let lat = Double(attributes["lat"] ?? ""), let lon = Double(attributes["lon"] ?? "") {
            current = GeoPoint(latitude: lat, longitude: lon)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.split(separator: ":").last.map(String.init)?.lowercased() ?? ""
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trackpoint {
            if name == "latitudedegrees" { latitude = Double(value) }
            if name == "longitudedegrees" { longitude = Double(value) }
            if name == "altitudemeters" { pendingElevation = value }
            if name == "time" { pendingTime = value }
            if name == "trackpoint" {
                if let latitude, let longitude {
                    points.append(GeoPoint(latitude: latitude, longitude: longitude, elevation: pendingElevation, time: pendingTime))
                }
                trackpoint = false
            }
        }
        if var point = current {
            if name == "ele" { point.elevation = value }
            if name == "time" { point.time = value }
            if name == "name" { point.name = value }
            current = point
        }
        if name == "wpt" || name == "trkpt" || name == "rtept", let point = current {
            points.append(point)
            current = nil
        }
        if name == "coordinates" {
            for token in value.split(whereSeparator: \.isWhitespace) {
                let parts = token.split(separator: ",").map(String.init)
                guard parts.count >= 2, let lon = Double(parts[0]), let lat = Double(parts[1]) else { continue }
                points.append(GeoPoint(latitude: lat, longitude: lon, elevation: parts.count > 2 ? parts[2] : ""))
            }
        }
    }
}

// MARK: - Contacts

enum Contacts {
    static func convert(from source: URL, detected: FormatID, to format: FormatID, destination: URL) throws {
        let cards: [[String: String]]
        if detected == .vcf {
            cards = parse(DelimitedText.decode(try Data(contentsOf: source)))
        } else {
            cards = records(try SpreadsheetConverter().loadTable(source, format: detected))
        }
        guard !cards.isEmpty else { throw RenvertError.invalidInput(L("No contacts were found.")) }
        switch format {
        case .vcf:
            try cards.map(vcard).joined(separator: "\n").write(to: destination, atomically: true, encoding: .utf8)
        case .json:
            let data = try JSONSerialization.data(withJSONObject: cards, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: destination)
        default:
            let headers = ["name", "email", "phone", "organization", "title", "url", "note"]
            let rows = [headers] + cards.map { card in headers.map { card[$0] ?? "" } }
            try DelimitedText.serialize(rows, delimiter: ",").write(to: destination, atomically: true, encoding: .utf8)
        }
    }

    private static func parse(_ text: String) -> [[String: String]] {
        var cards: [[String: String]] = []
        var card: [String: String] = [:]
        for raw in unfold(text) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "BEGIN:VCARD" { card = [:]; continue }
            if line == "END:VCARD" {
                if !card.isEmpty { cards.append(card) }
                card = [:]
                continue
            }
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].split(separator: ";").first.map(String.init)?.uppercased() ?? ""
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch key {
            case "FN": card["name"] = value
            case "N" where card["name"] == nil:
                let bits = value.split(separator: ";").map(String.init)
                card["name"] = [bits.count > 1 ? bits[1] : "", bits.first ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
            case "EMAIL": card["email"] = value
            case "TEL": card["phone"] = value
            case "ORG": card["organization"] = value
            case "TITLE": card["title"] = value
            case "URL": card["url"] = value
            case "NOTE": card["note"] = value
            default: break
            }
        }
        return cards
    }

    private static func records(_ rows: [[String]]) -> [[String: String]] {
        guard let headers = rows.first else { return [] }
        let keys = headers.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return rows.dropFirst().map { row in
            var card: [String: String] = [:]
            for (index, key) in keys.enumerated() where index < row.count {
                let mapped: String
                switch key {
                case "name", "fn", "full name": mapped = "name"
                case "email", "e-mail": mapped = "email"
                case "phone", "tel", "telephone": mapped = "phone"
                case "organization", "org", "company": mapped = "organization"
                case "title", "role": mapped = "title"
                case "url", "website": mapped = "url"
                case "note", "notes": mapped = "note"
                default: continue
                }
                card[mapped] = row[index]
            }
            return card
        }.filter { !$0.values.allSatisfy(\.isEmpty) }
    }

    private static func vcard(_ card: [String: String]) -> String {
        var lines = ["BEGIN:VCARD", "VERSION:3.0"]
        if let name = card["name"], !name.isEmpty { lines.append("FN:\(name)") }
        for (key, field) in [("EMAIL", "email"), ("TEL", "phone"), ("ORG", "organization"), ("TITLE", "title"), ("URL", "url"), ("NOTE", "note")] {
            if let value = card[field], !value.isEmpty { lines.append("\(key):\(value)") }
        }
        lines.append("END:VCARD")
        return lines.joined(separator: "\n")
    }

    private static func unfold(_ text: String) -> [String] {
        var lines: [String] = []
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix(" ") || line.hasPrefix("\t"), !lines.isEmpty {
                lines[lines.count - 1] += line.dropFirst()
            } else {
                lines.append(line)
            }
        }
        return lines
    }
}

// MARK: - Calendars

enum Calendars {
    static func convert(from source: URL, detected: FormatID, to format: FormatID, destination: URL) throws {
        let events: [[String: String]]
        if detected == .ics {
            events = parse(DelimitedText.decode(try Data(contentsOf: source)))
        } else {
            events = records(try SpreadsheetConverter().loadTable(source, format: detected))
        }
        guard !events.isEmpty else { throw RenvertError.invalidInput(L("No calendar events were found.")) }
        switch format {
        case .ics:
            try write(events).write(to: destination, atomically: true, encoding: .utf8)
        case .json:
            let data = try JSONSerialization.data(withJSONObject: events, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: destination)
        default:
            let headers = ["summary", "start", "end", "location", "description"]
            let rows = [headers] + events.map { event in headers.map { event[$0] ?? "" } }
            try DelimitedText.serialize(rows, delimiter: ",").write(to: destination, atomically: true, encoding: .utf8)
        }
    }

    private static func parse(_ text: String) -> [[String: String]] {
        var events: [[String: String]] = []
        var event: [String: String] = [:]
        var inside = false
        for raw in Contacts.unfoldShared(text) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "BEGIN:VEVENT" { inside = true; event = [:]; continue }
            if line == "END:VEVENT" {
                if !event.isEmpty { events.append(event) }
                inside = false
                continue
            }
            guard inside else { continue }
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].split(separator: ";").first.map(String.init)?.uppercased() ?? ""
            let value = parts[1].replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\,", with: ",")
            switch key {
            case "SUMMARY": event["summary"] = value
            case "DTSTART": event["start"] = value
            case "DTEND": event["end"] = value
            case "LOCATION": event["location"] = value
            case "DESCRIPTION": event["description"] = value
            default: break
            }
        }
        return events
    }

    private static func records(_ rows: [[String]]) -> [[String: String]] {
        guard let headers = rows.first else { return [] }
        let keys = headers.map { $0.lowercased() }
        return rows.dropFirst().map { row in
            var event: [String: String] = [:]
            for (index, key) in keys.enumerated() where index < row.count {
                let mapped: String
                switch key {
                case "summary", "title", "name": mapped = "summary"
                case "start", "dtstart", "begin": mapped = "start"
                case "end", "dtend": mapped = "end"
                case "location", "place": mapped = "location"
                case "description", "notes", "note": mapped = "description"
                default: continue
                }
                event[mapped] = row[index]
            }
            return event
        }.filter { !$0.values.allSatisfy(\.isEmpty) }
    }

    private static func write(_ events: [[String: String]]) -> String {
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Renvert//EN"]
        for event in events {
            lines.append("BEGIN:VEVENT")
            lines.append("UID:\(UUID().uuidString)@renvert")
            if let summary = event["summary"] { lines.append("SUMMARY:\(escaped(summary))") }
            if let start = event["start"], !start.isEmpty { lines.append("DTSTART:\(start)") }
            if let end = event["end"], !end.isEmpty { lines.append("DTEND:\(end)") }
            if let location = event["location"], !location.isEmpty { lines.append("LOCATION:\(escaped(location))") }
            if let description = event["description"], !description.isEmpty { lines.append("DESCRIPTION:\(escaped(description))") }
            lines.append("END:VEVENT")
        }
        lines.append("END:VCALENDAR")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: ",", with: "\\,")
    }
}

extension Contacts {
    static func unfoldShared(_ text: String) -> [String] { unfold(text) }
}
