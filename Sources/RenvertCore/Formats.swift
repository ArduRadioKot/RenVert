import Foundation
import UniformTypeIdentifiers

public enum FormatCategory: String, Codable, CaseIterable, Sendable {
    case image, audio, video, document, ebook, email, config, spreadsheet
    case archive, font, model, subtitle, certificate, folder, geo, palette
}

public enum EncodeBackend: String, Codable, Sendable {
    case native
    case ffmpeg
    case ditto
    case vision
    case speech
    case unavailable
}

public struct FormatDescriptor: Hashable, Sendable {
    public let id: FormatID
    public let utType: UTType?
    public let extensions: [String]
    public let category: FormatCategory
    public let decode: EncodeBackend
    public let encode: EncodeBackend
    public let notes: String

    public init(
        id: FormatID,
        utType: UTType?,
        extensions: [String],
        category: FormatCategory,
        decode: EncodeBackend,
        encode: EncodeBackend,
        notes: String = ""
    ) {
        self.id = id
        self.utType = utType
        self.extensions = extensions
        self.category = category
        self.decode = decode
        self.encode = encode
        self.notes = notes
    }
}

public enum FormatID: String, Codable, CaseIterable, Sendable {
    // Images
    case ai, apng, arw, avif, bmp, cr2, cr3, dng, eps, gif, heic, icns, ico, icon
    case jpeg, jp2, jxl, nef, orf, pcx, pef, png, ppm, ps, psd, raf, rw2, sr2, svg, svgz, tga, tiff, webp
    case exr, astc
    // Audio
    case aac, ac3, aiff, alac, au, caf, eac3, flac, m4a, mka, mp3, ogg, opus, tta, wav, wma, wv
    // Video
    case threeGP = "3gp", avi, flv, m2ts, mkv, mov, mp4, mpeg, mxf, ts, vob, webm, wmv
    // Documents
    case adoc, doc, dbk, docx, html, ipynb, key, tex, man, markdown, wiki, odt, opml, org
    case pages, pdf, pptx, rst, rtf, rtfd, txt, typst
    // E-books / mail
    case azw, azw3, epub, mobi, eml, emlx, msg
    // Config / tables
    case json, jsonl, plist, toml, xml, yaml, csv, numbers, parquet, sqlite, tsv, xls, xlsx
    case ini, env, properties, strings
    case gpx, kml, geojson, tcx, nmea, igc, vcf, ics, b64
    case webloc, url, rss, atom, m3u, cue
    case bib, ldif
    case gpl, hex, clr, css
    // Archives
    case sevenZ = "7z", bz2, cbr, cbt, cbz, gzip, tar, tbz2, tgz, txz, tzst, xz, zip, npz, pt, zstd
    // Fonts / 3D / subtitles / certs
    case otf, ttf, woff, woff2
    case threeDS = "3ds", dae, fbx, glb, gltf, obj, ply, stl, usda, usdc, usdz
    case ass, microdvd, ssa, srt, sub, vtt, lrc, sbv, smi
    case der, pem
    case folder
}

public enum FormatRegistry {
    public static let all: [FormatDescriptor] = makeAll()

    public static func descriptor(for id: FormatID) -> FormatDescriptor {
        all.first { $0.id == id }!
    }

    public static func resolve(_ token: String) -> FormatID? {
        let key = token.lowercased()
        if let exact = FormatID(rawValue: key) { return exact }
        switch key {
        case "jpg", "jpe", "jfif": return .jpeg
        case "tif": return .tiff
        case "md", "markdown": return .markdown
        case "htm": return .html
        case "yml": return .yaml
        case "jpegxl": return .jxl
        case "wave": return .wav
        case "m4b": return .m4a
        case "qt": return .mov
        case "m4v": return .mp4
        case "mpg", "mpeg2", "m2v": return .mpeg
        case "text": return .txt
        case "latex": return .tex
        case "typ": return .typst
        case "numbers": return .numbers
        case "keynote": return .key
        case "webloc": return nil
        case "gz": return .gzip
        case "7zip": return .sevenZ
        case "rar": return .cbr
        case "tar.bz2": return .tbz2
        case "tar.xz": return .txz
        case "targa": return .tga
        case "usd": return .usdc
        case "subrip": return .srt
        case "webvtt": return .vtt
        case "p12", "pfx": return nil
        case "folder": return .folder
        default:
            return all.first { $0.extensions.contains(key) }?.id
        }
    }

    public static func knows(_ token: String) -> Bool {
        resolve(token) != nil
    }

    public static func preferredExtension(for id: FormatID) -> String {
        switch id {
        case .jpeg: return "jpg"
        case .markdown: return "md"
        case .threeGP: return "3gp"
        case .threeDS: return "3ds"
        case .sevenZ: return "7z"
        case .typst: return "typ"
        default: return id.rawValue
        }
    }

    public static func isIdentity(_ from: FormatID, _ to: FormatID) -> Bool {
        from == to
    }

    /// Honest matrix: only pairs we can actually produce.
    public static func support(from: FormatID, to: FormatID) -> EncodeBackend {
        if to == .folder { return .native }
        if from == .folder {
            return archiveWritable.contains(to) ? .ditto : .unavailable
        }

        let src = descriptor(for: from)
        let dst = descriptor(for: to)

        if src.category == .image && imageEncodable.contains(to) && imageDecodable.contains(from) {
            return dst.encode == .unavailable ? .unavailable : .native
        }
        // A PDF is a document by category, but its pages render to any image format.
        if from == .pdf && to != .pdf && imageEncodable.contains(to) { return .native }
        if src.category == .video && to == .gif { return .ffmpeg }
        if src.category == .video && imageEncodable.contains(to) { return .native }
        if src.category == .audio && videoContainers.contains(to) { return .ffmpeg }
        if (src.category == .audio || src.category == .video) && audioEncodable.contains(to) {
            return nativeAudioEncodable.contains(to) && nativeAudioDecodable.contains(from) ? .native : .ffmpeg
        }
        if (src.category == .audio || src.category == .video) && videoEncodable.contains(to) {
            return nativeVideo.contains(from) && nativeVideo.contains(to) ? .native : .ffmpeg
        }
        if src.category == .video && subtitleFormats.contains(to) { return .ffmpeg }
        if subtitleFormats.contains(from) && subtitleFormats.contains(to) { return .native }
        if documentLike.contains(from) && documentLike.contains(to) {
            if nativeDocuments.contains(from) && nativeDocuments.contains(to) { return .native }
            return .unavailable
        }
        if [.csv, .tsv, .xlsx].contains(from) && nativeDocuments.contains(to) { return .native }
        if configFormats.contains(from) && configFormats.contains(to) {
            return .native
        }
        if [.json, .yaml, .plist, .xml, .toml].contains(from) && tableFormats.contains(to) {
            return .native
        }
        if tableFormats.contains(from) && (tableFormats.contains(to) || configFormats.contains(to)) {
            return nativeTables.contains(from) && nativeTables.contains(to) ? .native : .unavailable
        }
        if from == .zip && (to == .npz || to == .pt) { return .native }
        if (from == .npz || from == .pt) && to == .zip { return .native }
        if archiveFormats.contains(from) && archiveFormats.contains(to) {
            return archiveReadable.contains(from) && archiveWritable.contains(to) ? .ditto : .unavailable
        }
        if modelReadable.contains(from) && modelWritable.contains(to) { return .native }
        if (from == .der && to == .pem) || (from == .pem && to == .der) { return .native }
        if from == .emlx && nativeDocuments.contains(to) { return .native }
        if BeyondConverter.handles(from: from, to: to) { return .native }
        return .unavailable
    }

    public static func canConvert(from: FormatID, to: FormatID) -> Bool {
        support(from: from, to: to) != .unavailable
    }

    /// Formats the user can turn off. Types with no encoder stay hidden.
    public static var configurable: [FormatDescriptor] {
        all.filter { $0.decode != .unavailable || $0.encode != .unavailable }
    }
}

/// Camera RAW formats ImageIO develops into a regular bitmap.
public let rawImageFormats: Set<FormatID> = [.arw, .cr2, .cr3, .dng, .nef, .orf, .pef, .raf, .rw2, .sr2]
public let imageDecodable: Set<FormatID> = rawImageFormats.union([
    .apng, .astc, .avif, .bmp, .exr, .gif, .heic, .icns, .ico, .jpeg, .jp2, .jxl, .png, .ppm, .psd, .svg, .svgz, .tga, .tiff, .webp, .pdf
])
public let imageEncodable: Set<FormatID> = [
    .astc, .avif, .bmp, .exr, .gif, .heic, .icns, .ico, .jpeg, .jp2, .png, .ppm, .psd, .tga, .tiff, .webp, .pdf
]
public let nativeAudio: Set<FormatID> = [.aac, .aiff, .alac, .caf, .m4a, .wav]
/// Core Audio reads MP3 and FLAC and writes FLAC, so these need no ffmpeg.
public let nativeAudioDecodable: Set<FormatID> = nativeAudio.union([.mp3, .flac])
public let nativeAudioEncodable: Set<FormatID> = nativeAudio.union([.flac])
public let audioEncodable: Set<FormatID> = nativeAudio.union([.mp3, .flac, .ogg, .opus, .mka])
public let nativeVideo: Set<FormatID> = [.mov, .mp4, .m4a]
public let videoEncodable: Set<FormatID> = [.mov, .mp4, .mkv, .webm, .avi, .gif]
public let videoContainers: Set<FormatID> = [.mov, .mp4, .mkv, .webm, .avi]
public let subtitleFormats: Set<FormatID> = [.srt, .vtt, .ass, .ssa, .sub, .microdvd, .lrc, .sbv, .smi]
public let documentLike: Set<FormatID> = [
    .txt, .markdown, .html, .rtf, .rtfd, .pdf, .docx, .doc, .odt, .adoc, .rst, .org, .opml, .tex, .eml
]
public let nativeDocuments: Set<FormatID> = [.txt, .markdown, .html, .rtf, .pdf, .docx, .doc, .odt, .opml, .eml]
public let configFormats: Set<FormatID> = [.json, .yaml, .plist, .xml, .toml, .ini, .env, .properties, .strings]
public let tableFormats: Set<FormatID> = [.csv, .tsv, .xlsx, .json, .yaml, .sqlite, .jsonl]
public let nativeTables: Set<FormatID> = [.csv, .tsv, .xlsx, .json, .yaml, .sqlite, .jsonl]
public let archiveFormats: Set<FormatID> = [
    .zip, .tar, .tgz, .tbz2, .txz, .tzst, .cbz, .cbt, .cbr, .sevenZ, .gzip, .bz2
]
/// RAR (and CBR) can only be unpacked: the system libarchive has no RAR writer.
public let archiveReadable: Set<FormatID> = [.zip, .tar, .tgz, .tbz2, .txz, .cbz, .cbt, .cbr, .sevenZ]
public let archiveWritable: Set<FormatID> = [.zip, .tar, .tgz, .tbz2, .txz, .cbz, .cbt, .sevenZ]
/// 3D formats Model I/O reads and writes. USDZ is read-only there.
public let modelReadable: Set<FormatID> = [.obj, .stl, .ply, .usda, .usdc, .usdz]
public let modelWritable: Set<FormatID> = [.obj, .stl, .ply, .usda, .usdc]
/// Formats with no reliable signature: the name the file had before the rename decides.
public let extensionOnlyFormats: Set<FormatID> = [.obj, .stl, .tga, .clr]
/// Tracks, contacts and calendars.
public let geoFormats: Set<FormatID> = [.gpx, .kml, .geojson, .tcx, .nmea, .igc]
public let bookmarkFormats: Set<FormatID> = [.webloc, .url]
public let feedFormats: Set<FormatID> = [.rss, .atom]
public let paletteFormats: Set<FormatID> = [.gpl, .hex, .clr, .css]

private func makeAll() -> [FormatDescriptor] {
    func d(
        _ id: FormatID,
        _ category: FormatCategory,
        _ exts: [String],
        _ ut: UTType?,
        decode: EncodeBackend,
        encode: EncodeBackend,
        _ notes: String = ""
    ) -> FormatDescriptor {
        FormatDescriptor(id: id, utType: ut, extensions: exts, category: category, decode: decode, encode: encode, notes: notes)
    }

    return [
        d(.ai, .image, ["ai"], nil, decode: .unavailable, encode: .unavailable),
        d(.apng, .image, ["apng"], nil, decode: .native, encode: .native),
        d(.arw, .image, ["arw"], UTType("com.sony.arw-raw-image"), decode: .native, encode: .unavailable),
        d(.avif, .image, ["avif"], UTType("public.avif"), decode: .native, encode: .native),
        d(.bmp, .image, ["bmp"], .bmp, decode: .native, encode: .native),
        d(.cr2, .image, ["cr2"], UTType("com.canon.cr2-raw-image"), decode: .native, encode: .unavailable),
        d(.cr3, .image, ["cr3"], UTType("com.canon.cr3-raw-image"), decode: .native, encode: .unavailable),
        d(.dng, .image, ["dng"], UTType("com.adobe.raw-image"), decode: .native, encode: .unavailable),
        d(.eps, .image, ["eps"], UTType("com.adobe.encapsulated-postscript"), decode: .unavailable, encode: .unavailable),
        d(.gif, .image, ["gif"], .gif, decode: .native, encode: .native),
        d(.heic, .image, ["heic", "heif"], .heic, decode: .native, encode: .native),
        d(.icns, .image, ["icns"], .icns, decode: .native, encode: .native),
        d(.ico, .image, ["ico"], UTType("com.microsoft.ico"), decode: .native, encode: .native),
        d(.icon, .image, ["icon"], nil, decode: .unavailable, encode: .unavailable),
        d(.jpeg, .image, ["jpg", "jpeg"], .jpeg, decode: .native, encode: .native),
        d(.jp2, .image, ["jp2", "j2k", "jpf"], UTType("public.jpeg-2000"), decode: .native, encode: .native),
        d(.ppm, .image, ["ppm", "pbm", "pgm", "pnm"], UTType("public.pbm"), decode: .native, encode: .native, "Netpbm bitmap, written as an 8-bit PPM."),
        d(.exr, .image, ["exr"], UTType("com.ilm.openexr-image"), decode: .native, encode: .native),
        d(.astc, .image, ["astc"], UTType("org.khronos.astc"), decode: .native, encode: .native, "GPU texture block."),
        d(.jxl, .image, ["jxl"], UTType("public.jpeg-xl"), decode: .native, encode: .unavailable, "ImageIO reads JPEG XL but cannot write it."),
        d(.nef, .image, ["nef"], UTType("com.nikon.raw-image"), decode: .native, encode: .unavailable),
        d(.orf, .image, ["orf"], UTType("com.olympus.raw-image"), decode: .native, encode: .unavailable),
        d(.pcx, .image, ["pcx"], nil, decode: .unavailable, encode: .unavailable),
        d(.pef, .image, ["pef"], UTType("com.pentax.raw-image"), decode: .native, encode: .unavailable),
        d(.png, .image, ["png"], .png, decode: .native, encode: .native),
        d(.ps, .image, ["ps"], UTType("com.adobe.postscript"), decode: .unavailable, encode: .unavailable),
        d(.psd, .image, ["psd"], UTType("com.adobe.photoshop-image"), decode: .native, encode: .native, "Written as a flattened single layer."),
        d(.raf, .image, ["raf"], UTType("com.fuji.raw-image"), decode: .native, encode: .unavailable),
        d(.rw2, .image, ["rw2"], UTType("com.panasonic.raw-image"), decode: .native, encode: .unavailable),
        d(.sr2, .image, ["sr2"], UTType("com.sony.sr2-raw-image"), decode: .native, encode: .unavailable),
        d(.svg, .image, ["svg"], .svg, decode: .native, encode: .unavailable, "SVG is rasterized on decode."),
        d(.svgz, .image, ["svgz"], nil, decode: .native, encode: .unavailable),
        d(.tga, .image, ["tga"], UTType("com.truevision.tga-image"), decode: .native, encode: .native),
        d(.tiff, .image, ["tiff", "tif"], .tiff, decode: .native, encode: .native),
        d(.webp, .image, ["webp"], UTType("org.webmproject.webp"), decode: .native, encode: .native),

        d(.aac, .audio, ["aac"], .mpeg4Audio, decode: .native, encode: .native),
        d(.ac3, .audio, ["ac3"], nil, decode: .ffmpeg, encode: .ffmpeg),
        d(.aiff, .audio, ["aiff", "aif"], .aiff, decode: .native, encode: .native),
        d(.alac, .audio, ["alac"], nil, decode: .native, encode: .native),
        d(.au, .audio, ["au"], nil, decode: .ffmpeg, encode: .ffmpeg),
        d(.caf, .audio, ["caf"], UTType("com.apple.coreaudio-format"), decode: .native, encode: .native),
        d(.eac3, .audio, ["eac3"], nil, decode: .ffmpeg, encode: .ffmpeg),
        d(.flac, .audio, ["flac"], UTType("org.xiph.flac"), decode: .native, encode: .native),
        d(.m4a, .audio, ["m4a", "m4b"], .mpeg4Audio, decode: .native, encode: .native),
        d(.mka, .audio, ["mka"], nil, decode: .ffmpeg, encode: .ffmpeg),
        d(.mp3, .audio, ["mp3"], .mp3, decode: .native, encode: .ffmpeg),
        d(.ogg, .audio, ["ogg", "oga"], UTType("org.xiph.ogg-audio"), decode: .ffmpeg, encode: .ffmpeg),
        d(.opus, .audio, ["opus"], nil, decode: .ffmpeg, encode: .ffmpeg),
        d(.tta, .audio, ["tta"], nil, decode: .ffmpeg, encode: .unavailable),
        d(.wav, .audio, ["wav"], .wav, decode: .native, encode: .native),
        d(.wma, .audio, ["wma"], nil, decode: .ffmpeg, encode: .unavailable),
        d(.wv, .audio, ["wv"], nil, decode: .ffmpeg, encode: .unavailable),

        d(.threeGP, .video, ["3gp"], nil, decode: .ffmpeg, encode: .unavailable),
        d(.avi, .video, ["avi"], UTType("public.avi"), decode: .ffmpeg, encode: .ffmpeg),
        d(.flv, .video, ["flv"], nil, decode: .ffmpeg, encode: .unavailable),
        d(.m2ts, .video, ["m2ts", "mts"], nil, decode: .ffmpeg, encode: .ffmpeg),
        d(.mkv, .video, ["mkv"], nil, decode: .ffmpeg, encode: .ffmpeg),
        d(.mov, .video, ["mov"], .quickTimeMovie, decode: .native, encode: .native),
        d(.mp4, .video, ["mp4", "m4v"], .mpeg4Movie, decode: .native, encode: .native),
        d(.mpeg, .video, ["mpeg", "mpg"], UTType("public.mpeg"), decode: .ffmpeg, encode: .ffmpeg),
        d(.mxf, .video, ["mxf"], nil, decode: .ffmpeg, encode: .unavailable),
        d(.ts, .video, ["ts"], nil, decode: .ffmpeg, encode: .ffmpeg),
        d(.vob, .video, ["vob"], nil, decode: .ffmpeg, encode: .unavailable),
        d(.webm, .video, ["webm"], nil, decode: .ffmpeg, encode: .ffmpeg),
        d(.wmv, .video, ["wmv"], nil, decode: .ffmpeg, encode: .unavailable),

        d(.adoc, .document, ["adoc", "asciidoc"], nil, decode: .unavailable, encode: .unavailable),
        d(.doc, .document, ["doc"], UTType("com.microsoft.word.doc"), decode: .native, encode: .native, "Text and basic styling through TextKit."),
        d(.dbk, .document, ["dbk"], nil, decode: .unavailable, encode: .unavailable),
        d(.docx, .document, ["docx"], UTType("org.openxmlformats.wordprocessingml.document"), decode: .native, encode: .native, "Native DOCX preserves paragraphs, not full layout."),
        d(.html, .document, ["html", "htm"], .html, decode: .native, encode: .native),
        d(.ipynb, .document, ["ipynb"], nil, decode: .unavailable, encode: .unavailable),
        d(.key, .document, ["key"], nil, decode: .unavailable, encode: .unavailable),
        d(.tex, .document, ["tex", "latex"], nil, decode: .unavailable, encode: .unavailable),
        d(.man, .document, ["man"], nil, decode: .unavailable, encode: .unavailable),
        d(.markdown, .document, ["md", "markdown"], .plainText, decode: .native, encode: .native),
        d(.wiki, .document, ["wiki"], nil, decode: .unavailable, encode: .unavailable),
        d(.odt, .document, ["odt"], UTType("org.oasis-open.opendocument.text"), decode: .native, encode: .native, "Text and basic styling through TextKit."),
        d(.opml, .document, ["opml"], .xml, decode: .native, encode: .native, "Outline titles, including nested ones."),
        d(.org, .document, ["org"], .plainText, decode: .native, encode: .native),
        d(.pages, .document, ["pages"], nil, decode: .unavailable, encode: .unavailable),
        d(.pdf, .document, ["pdf"], .pdf, decode: .native, encode: .native),
        d(.pptx, .document, ["pptx"], nil, decode: .unavailable, encode: .unavailable),
        d(.rst, .document, ["rst"], .plainText, decode: .native, encode: .native),
        d(.rtf, .document, ["rtf"], .rtf, decode: .native, encode: .native),
        d(.rtfd, .document, ["rtfd"], UTType("com.apple.rtfd"), decode: .native, encode: .unavailable),
        d(.txt, .document, ["txt", "text"], .plainText, decode: .native, encode: .native),
        d(.typst, .document, ["typ"], nil, decode: .unavailable, encode: .unavailable),

        d(.azw, .ebook, ["azw"], nil, decode: .unavailable, encode: .unavailable),
        d(.azw3, .ebook, ["azw3"], nil, decode: .unavailable, encode: .unavailable),
        d(.epub, .ebook, ["epub"], UTType("org.idpf.epub-container"), decode: .unavailable, encode: .unavailable),
        d(.mobi, .ebook, ["mobi"], nil, decode: .unavailable, encode: .unavailable),
        d(.eml, .email, ["eml"], nil, decode: .native, encode: .native, "Headers and the text body. HTML parts are kept as text."),
        d(.emlx, .email, ["emlx"], nil, decode: .native, encode: .unavailable),
        d(.msg, .email, ["msg"], nil, decode: .unavailable, encode: .unavailable),

        d(.json, .config, ["json"], .json, decode: .native, encode: .native),
        d(.jsonl, .spreadsheet, ["jsonl", "ndjson"], .plainText, decode: .native, encode: .native, "One JSON value per line."),
        d(.plist, .config, ["plist"], .propertyList, decode: .native, encode: .native),
        d(.toml, .config, ["toml"], .plainText, decode: .native, encode: .native),
        d(.xml, .config, ["xml"], .xml, decode: .native, encode: .native),
        d(.yaml, .config, ["yaml", "yml"], .plainText, decode: .native, encode: .native),
        d(.ini, .config, ["ini", "cfg", "editorconfig"], .plainText, decode: .native, encode: .native, "Sections become nested objects. .editorconfig is INI."),
        d(.env, .config, ["env"], .plainText, decode: .native, encode: .native, "KEY=VALUE files, including export lines."),
        d(.properties, .config, ["properties"], .plainText, decode: .native, encode: .native, "Java properties."),
        d(.strings, .config, ["strings"], .plainText, decode: .native, encode: .native, "Apple strings files."),

        d(.csv, .spreadsheet, ["csv"], .commaSeparatedText, decode: .native, encode: .native),
        d(.numbers, .spreadsheet, ["numbers"], nil, decode: .unavailable, encode: .unavailable),
        d(.parquet, .spreadsheet, ["parquet"], nil, decode: .unavailable, encode: .unavailable),
        d(.sqlite, .spreadsheet, ["sqlite", "sqlite3", "db"], nil, decode: .native, encode: .native, "Every user table, through the system sqlite3."),
        d(.tsv, .spreadsheet, ["tsv"], .tabSeparatedText, decode: .native, encode: .native),
        d(.xls, .spreadsheet, ["xls"], nil, decode: .unavailable, encode: .unavailable),
        d(.xlsx, .spreadsheet, ["xlsx"], UTType("org.openxmlformats.spreadsheetml.sheet"), decode: .native, encode: .native),

        d(.sevenZ, .archive, ["7z"], nil, decode: .ditto, encode: .ditto),
        d(.bz2, .archive, ["bz2"], nil, decode: .unavailable, encode: .unavailable),
        d(.cbr, .archive, ["cbr", "rar"], nil, decode: .ditto, encode: .unavailable),
        d(.cbt, .archive, ["cbt"], nil, decode: .ditto, encode: .ditto),
        d(.cbz, .archive, ["cbz"], nil, decode: .ditto, encode: .ditto),
        d(.gzip, .archive, ["gz", "gzip"], UTType("org.gnu.gnu-zip-archive"), decode: .ditto, encode: .ditto),
        d(.tar, .archive, ["tar"], UTType("public.tar-archive"), decode: .ditto, encode: .ditto),
        d(.tbz2, .archive, ["tbz2", "tbz"], nil, decode: .ditto, encode: .ditto),
        d(.tgz, .archive, ["tgz", "tar.gz"], UTType("org.gnu.gnu-zip-tar-archive"), decode: .ditto, encode: .ditto),
        d(.txz, .archive, ["txz"], nil, decode: .ditto, encode: .ditto),
        d(.tzst, .archive, ["tzst"], nil, decode: .unavailable, encode: .unavailable),
        d(.xz, .archive, ["xz"], nil, decode: .unavailable, encode: .unavailable),
        d(.zip, .archive, ["zip"], .zip, decode: .ditto, encode: .ditto),
        d(.npz, .archive, ["npz"], nil, decode: .native, encode: .native, "NumPy archive. Each file in the zip becomes a uint8 array."),
        d(.pt, .archive, ["pt", "pth"], nil, decode: .native, encode: .native, "PyTorch zip. torch.load with weights_only off returns a dict of the original file bytes."),
        d(.zstd, .archive, ["zst", "zstd"], nil, decode: .unavailable, encode: .unavailable),

        d(.otf, .font, ["otf"], UTType("public.opentype-font"), decode: .native, encode: .unavailable, "Rendered to an image. A font file is not written back."),
        d(.ttf, .font, ["ttf", "ttc"], UTType("public.truetype-ttf-font"), decode: .native, encode: .unavailable, "Rendered to an image. A font file is not written back."),
        d(.woff, .font, ["woff"], nil, decode: .unavailable, encode: .unavailable),
        d(.woff2, .font, ["woff2"], nil, decode: .unavailable, encode: .unavailable),

        d(.threeDS, .model, ["3ds"], nil, decode: .unavailable, encode: .unavailable),
        d(.dae, .model, ["dae"], nil, decode: .unavailable, encode: .unavailable),
        d(.fbx, .model, ["fbx"], nil, decode: .unavailable, encode: .unavailable),
        d(.glb, .model, ["glb"], nil, decode: .unavailable, encode: .unavailable),
        d(.gltf, .model, ["gltf"], nil, decode: .unavailable, encode: .unavailable),
        d(.obj, .model, ["obj"], nil, decode: .native, encode: .native),
        d(.ply, .model, ["ply"], nil, decode: .native, encode: .native),
        d(.stl, .model, ["stl"], nil, decode: .native, encode: .native),
        d(.usda, .model, ["usda"], nil, decode: .native, encode: .native),
        d(.usdc, .model, ["usdc"], nil, decode: .native, encode: .native),
        d(.usdz, .model, ["usdz"], UTType("com.pixar.universal-scene-description-mobile"), decode: .native, encode: .unavailable),

        d(.ass, .subtitle, ["ass"], nil, decode: .native, encode: .native),
        d(.microdvd, .subtitle, ["sub"], nil, decode: .native, encode: .native),
        d(.ssa, .subtitle, ["ssa"], nil, decode: .native, encode: .native),
        d(.srt, .subtitle, ["srt"], nil, decode: .native, encode: .native),
        d(.sub, .subtitle, ["sub"], nil, decode: .native, encode: .native),
        d(.vtt, .subtitle, ["vtt"], nil, decode: .native, encode: .native),
        d(.lrc, .subtitle, ["lrc"], nil, decode: .native, encode: .native, "Timed lyrics."),
        d(.sbv, .subtitle, ["sbv"], nil, decode: .native, encode: .native, "YouTube subtitles."),
        d(.smi, .subtitle, ["smi", "sami"], nil, decode: .native, encode: .native, "SAMI captions."),

        d(.nmea, .geo, ["nmea"], .plainText, decode: .native, encode: .native, "NMEA 0183 sentences."),
        d(.igc, .geo, ["igc"], .plainText, decode: .native, encode: .native, "IGC flight logs."),
        d(.gpx, .geo, ["gpx"], .xml, decode: .native, encode: .native),
        d(.kml, .geo, ["kml"], .xml, decode: .native, encode: .native),
        d(.geojson, .geo, ["geojson"], .json, decode: .native, encode: .native),
        d(.tcx, .geo, ["tcx"], .xml, decode: .native, encode: .native, "Garmin Training Center tracks."),
        d(.webloc, .document, ["webloc"], nil, decode: .native, encode: .native, "macOS web location."),
        d(.url, .document, ["url"], nil, decode: .native, encode: .native, "Windows internet shortcut."),
        d(.rss, .document, ["rss"], .xml, decode: .native, encode: .native, "RSS items."),
        d(.atom, .document, ["atom"], .xml, decode: .native, encode: .native, "Atom entries."),
        d(.m3u, .document, ["m3u", "m3u8"], .plainText, decode: .native, encode: .native, "Playlists, including HLS media playlists."),
        d(.cue, .document, ["cue"], .plainText, decode: .native, encode: .native, "CD cue sheets."),
        d(.bib, .document, ["bib"], .plainText, decode: .native, encode: .native, "BibTeX bibliography."),
        d(.ldif, .document, ["ldif"], .plainText, decode: .native, encode: .native, "LDAP directory entries."),
        d(.gpl, .palette, ["gpl"], .plainText, decode: .native, encode: .native, "GIMP palette."),
        d(.hex, .palette, ["hex"], .plainText, decode: .native, encode: .native, "Hex color list."),
        d(.clr, .palette, ["clr"], nil, decode: .native, encode: .native, "macOS color list."),
        d(.css, .palette, ["css"], UTType("public.css"), decode: .native, encode: .native, "CSS custom properties for the colors."),
        d(.vcf, .document, ["vcf", "vcard"], nil, decode: .native, encode: .native, "Contacts."),
        d(.ics, .document, ["ics", "ical"], nil, decode: .native, encode: .native, "Calendar events."),
        d(.b64, .document, ["b64", "base64"], .plainText, decode: .native, encode: .native, "Base64 of the original bytes."),

        d(.der, .certificate, ["der", "cer"], nil, decode: .native, encode: .native),
        d(.pem, .certificate, ["pem", "crt"], nil, decode: .native, encode: .native),
        d(.folder, .folder, ["folder"], .folder, decode: .native, encode: .native)
    ]
}
