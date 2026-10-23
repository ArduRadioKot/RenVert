import Foundation
import UniformTypeIdentifiers

public enum FormatCategory: String, Codable, CaseIterable, Sendable {
    case image, audio, video, document, ebook, email, config, spreadsheet
    case archive, font, model, subtitle, certificate, folder
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
    case jpeg, jxl, nef, orf, pcx, pef, png, ps, psd, raf, rw2, sr2, svg, svgz, tga, tiff, webp
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
    case json, plist, toml, xml, yaml, csv, numbers, parquet, sqlite, tsv, xls, xlsx
    // Archives
    case sevenZ = "7z", bz2, cbr, cbt, cbz, gzip, tar, tbz2, tgz, txz, tzst, xz, zip, zstd
    // Fonts / 3D / subtitles / certs
    case otf, ttf, woff, woff2
    case threeDS = "3ds", dae, fbx, glb, gltf, obj, ply, stl, usda, usdc, usdz
    case ass, microdvd, ssa, srt, sub, vtt
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
        case "subrip": return .srt
        case "webvtt": return .vtt
        case "p12", "pfx": return nil
        case "folder": return .folder
        default: return FormatID(rawValue: key)
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
            return [.zip, .tgz, .tar, .cbz, .cbt].contains(to) ? .ditto : .unavailable
        }

        let src = descriptor(for: from)
        let dst = descriptor(for: to)

        if src.category == .image && imageEncodable.contains(to) && imageDecodable.contains(from) {
            return dst.encode == .unavailable ? .unavailable : .native
        }
        if src.category == .video && to == .gif { return .ffmpeg }
        if src.category == .video && imageEncodable.contains(to) { return .native }
        if src.category == .audio && videoContainers.contains(to) { return .ffmpeg }
        if (src.category == .audio || src.category == .video) && audioEncodable.contains(to) {
            return nativeAudio.contains(to) && nativeAudio.contains(from) ? .native : .ffmpeg
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
        if configFormats.contains(from) && (configFormats.contains(to) || tableFormats.contains(to)) {
            return .native
        }
        if tableFormats.contains(from) && (tableFormats.contains(to) || configFormats.contains(to)) {
            return nativeTables.contains(from) && nativeTables.contains(to) ? .native : .unavailable
        }
        if archiveFormats.contains(from) && archiveFormats.contains(to) {
            return [.zip, .tar, .tgz, .cbz, .cbt].contains(from) && [.zip, .tar, .tgz, .cbz, .cbt].contains(to)
                ? .ditto : .unavailable
        }
        if (from == .der && to == .pem) || (from == .pem && to == .der) { return .native }
        return .unavailable
    }

    public static func canConvert(from: FormatID, to: FormatID) -> Bool {
        support(from: from, to: to) != .unavailable
    }
}

public let imageDecodable: Set<FormatID> = [
    .avif, .bmp, .gif, .heic, .icns, .ico, .jpeg, .png, .svg, .svgz, .tiff, .webp, .pdf
]
public let imageEncodable: Set<FormatID> = [
    .avif, .bmp, .gif, .heic, .icns, .ico, .jpeg, .png, .tiff, .webp, .pdf
]
public let nativeAudio: Set<FormatID> = [.aac, .aiff, .alac, .caf, .m4a, .wav]
public let audioEncodable: Set<FormatID> = nativeAudio.union([.mp3, .flac, .ogg, .opus, .mka])
public let nativeVideo: Set<FormatID> = [.mov, .mp4, .m4a]
public let videoEncodable: Set<FormatID> = [.mov, .mp4, .mkv, .webm, .avi, .gif]
public let videoContainers: Set<FormatID> = [.mov, .mp4, .mkv, .webm, .avi]
public let subtitleFormats: Set<FormatID> = [.srt, .vtt, .ass, .ssa, .sub, .microdvd]
public let documentLike: Set<FormatID> = [
    .txt, .markdown, .html, .rtf, .rtfd, .pdf, .docx, .adoc, .rst, .org, .opml, .tex
]
public let nativeDocuments: Set<FormatID> = [.txt, .markdown, .html, .rtf, .pdf, .docx]
public let configFormats: Set<FormatID> = [.json, .yaml, .plist, .xml, .toml]
public let tableFormats: Set<FormatID> = [.csv, .tsv, .xlsx, .json, .yaml]
public let nativeTables: Set<FormatID> = [.csv, .tsv, .xlsx, .json, .yaml]
public let archiveFormats: Set<FormatID> = [
    .zip, .tar, .tgz, .tbz2, .txz, .tzst, .cbz, .cbt, .gzip, .bz2
]

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
        d(.jxl, .image, ["jxl"], UTType("public.jpeg-xl"), decode: .unavailable, encode: .unavailable, "Requires a JXL encoder that is not bundled yet."),
        d(.nef, .image, ["nef"], UTType("com.nikon.raw-image"), decode: .native, encode: .unavailable),
        d(.orf, .image, ["orf"], UTType("com.olympus.raw-image"), decode: .native, encode: .unavailable),
        d(.pcx, .image, ["pcx"], nil, decode: .unavailable, encode: .unavailable),
        d(.pef, .image, ["pef"], UTType("com.pentax.raw-image"), decode: .native, encode: .unavailable),
        d(.png, .image, ["png"], .png, decode: .native, encode: .native),
        d(.ps, .image, ["ps"], UTType("com.adobe.postscript"), decode: .unavailable, encode: .unavailable),
        d(.psd, .image, ["psd"], UTType("com.adobe.photoshop-image"), decode: .native, encode: .unavailable),
        d(.raf, .image, ["raf"], UTType("com.fuji.raw-image"), decode: .native, encode: .unavailable),
        d(.rw2, .image, ["rw2"], UTType("com.panasonic.raw-image"), decode: .native, encode: .unavailable),
        d(.sr2, .image, ["sr2"], UTType("com.sony.sr2-raw-image"), decode: .native, encode: .unavailable),
        d(.svg, .image, ["svg"], .svg, decode: .native, encode: .unavailable, "SVG is rasterized on decode."),
        d(.svgz, .image, ["svgz"], nil, decode: .native, encode: .unavailable),
        d(.tga, .image, ["tga"], nil, decode: .unavailable, encode: .unavailable),
        d(.tiff, .image, ["tiff", "tif"], .tiff, decode: .native, encode: .native),
        d(.webp, .image, ["webp"], UTType("org.webmproject.webp"), decode: .native, encode: .native),

        d(.aac, .audio, ["aac"], .mpeg4Audio, decode: .native, encode: .native),
        d(.ac3, .audio, ["ac3"], nil, decode: .ffmpeg, encode: .ffmpeg),
        d(.aiff, .audio, ["aiff", "aif"], .aiff, decode: .native, encode: .native),
        d(.alac, .audio, ["alac"], nil, decode: .native, encode: .native),
        d(.au, .audio, ["au"], nil, decode: .ffmpeg, encode: .ffmpeg),
        d(.caf, .audio, ["caf"], UTType("com.apple.coreaudio-format"), decode: .native, encode: .native),
        d(.eac3, .audio, ["eac3"], nil, decode: .ffmpeg, encode: .ffmpeg),
        d(.flac, .audio, ["flac"], UTType("org.xiph.flac"), decode: .ffmpeg, encode: .ffmpeg),
        d(.m4a, .audio, ["m4a", "m4b"], .mpeg4Audio, decode: .native, encode: .native),
        d(.mka, .audio, ["mka"], nil, decode: .ffmpeg, encode: .ffmpeg),
        d(.mp3, .audio, ["mp3"], .mp3, decode: .ffmpeg, encode: .ffmpeg),
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
        d(.doc, .document, ["doc"], .rtf, decode: .unavailable, encode: .unavailable, "Legacy DOC needs LibreOffice."),
        d(.dbk, .document, ["dbk"], nil, decode: .unavailable, encode: .unavailable),
        d(.docx, .document, ["docx"], UTType("org.openxmlformats.wordprocessingml.document"), decode: .native, encode: .native, "Native DOCX preserves paragraphs, not full layout."),
        d(.html, .document, ["html", "htm"], .html, decode: .native, encode: .native),
        d(.ipynb, .document, ["ipynb"], nil, decode: .unavailable, encode: .unavailable),
        d(.key, .document, ["key"], nil, decode: .unavailable, encode: .unavailable),
        d(.tex, .document, ["tex", "latex"], nil, decode: .unavailable, encode: .unavailable),
        d(.man, .document, ["man"], nil, decode: .unavailable, encode: .unavailable),
        d(.markdown, .document, ["md", "markdown"], .plainText, decode: .native, encode: .native),
        d(.wiki, .document, ["wiki"], nil, decode: .unavailable, encode: .unavailable),
        d(.odt, .document, ["odt"], nil, decode: .unavailable, encode: .unavailable),
        d(.opml, .document, ["opml"], .xml, decode: .native, encode: .native),
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
        d(.eml, .email, ["eml"], nil, decode: .native, encode: .native),
        d(.emlx, .email, ["emlx"], nil, decode: .native, encode: .unavailable),
        d(.msg, .email, ["msg"], nil, decode: .unavailable, encode: .unavailable),

        d(.json, .config, ["json"], .json, decode: .native, encode: .native),
        d(.plist, .config, ["plist"], .propertyList, decode: .native, encode: .native),
        d(.toml, .config, ["toml"], .plainText, decode: .native, encode: .native),
        d(.xml, .config, ["xml"], .xml, decode: .native, encode: .native),
        d(.yaml, .config, ["yaml", "yml"], .plainText, decode: .native, encode: .native),

        d(.csv, .spreadsheet, ["csv"], .commaSeparatedText, decode: .native, encode: .native),
        d(.numbers, .spreadsheet, ["numbers"], nil, decode: .unavailable, encode: .unavailable),
        d(.parquet, .spreadsheet, ["parquet"], nil, decode: .unavailable, encode: .unavailable),
        d(.sqlite, .spreadsheet, ["sqlite", "db", "sqlite3"], nil, decode: .unavailable, encode: .unavailable),
        d(.tsv, .spreadsheet, ["tsv"], .tabSeparatedText, decode: .native, encode: .native),
        d(.xls, .spreadsheet, ["xls"], nil, decode: .unavailable, encode: .unavailable),
        d(.xlsx, .spreadsheet, ["xlsx"], UTType("org.openxmlformats.spreadsheetml.sheet"), decode: .native, encode: .native),

        d(.sevenZ, .archive, ["7z"], nil, decode: .unavailable, encode: .unavailable),
        d(.bz2, .archive, ["bz2"], nil, decode: .unavailable, encode: .unavailable),
        d(.cbr, .archive, ["cbr"], nil, decode: .unavailable, encode: .unavailable),
        d(.cbt, .archive, ["cbt"], nil, decode: .ditto, encode: .ditto),
        d(.cbz, .archive, ["cbz"], nil, decode: .ditto, encode: .ditto),
        d(.gzip, .archive, ["gz", "gzip"], UTType("org.gnu.gnu-zip-archive"), decode: .ditto, encode: .ditto),
        d(.tar, .archive, ["tar"], UTType("public.tar-archive"), decode: .ditto, encode: .ditto),
        d(.tbz2, .archive, ["tbz2", "tbz"], nil, decode: .unavailable, encode: .unavailable),
        d(.tgz, .archive, ["tgz", "tar.gz"], UTType("org.gnu.gnu-zip-tar-archive"), decode: .ditto, encode: .ditto),
        d(.txz, .archive, ["txz"], nil, decode: .unavailable, encode: .unavailable),
        d(.tzst, .archive, ["tzst"], nil, decode: .unavailable, encode: .unavailable),
        d(.xz, .archive, ["xz"], nil, decode: .unavailable, encode: .unavailable),
        d(.zip, .archive, ["zip"], .zip, decode: .ditto, encode: .ditto),
        d(.zstd, .archive, ["zst", "zstd"], nil, decode: .unavailable, encode: .unavailable),

        d(.otf, .font, ["otf"], UTType("public.opentype-font"), decode: .unavailable, encode: .unavailable),
        d(.ttf, .font, ["ttf"], UTType("public.truetype-ttf-font"), decode: .unavailable, encode: .unavailable),
        d(.woff, .font, ["woff"], nil, decode: .unavailable, encode: .unavailable),
        d(.woff2, .font, ["woff2"], nil, decode: .unavailable, encode: .unavailable),

        d(.threeDS, .model, ["3ds"], nil, decode: .unavailable, encode: .unavailable),
        d(.dae, .model, ["dae"], nil, decode: .unavailable, encode: .unavailable),
        d(.fbx, .model, ["fbx"], nil, decode: .unavailable, encode: .unavailable),
        d(.glb, .model, ["glb"], nil, decode: .unavailable, encode: .unavailable),
        d(.gltf, .model, ["gltf"], nil, decode: .unavailable, encode: .unavailable),
        d(.obj, .model, ["obj"], nil, decode: .unavailable, encode: .unavailable),
        d(.ply, .model, ["ply"], nil, decode: .unavailable, encode: .unavailable),
        d(.stl, .model, ["stl"], nil, decode: .unavailable, encode: .unavailable),
        d(.usda, .model, ["usda"], nil, decode: .unavailable, encode: .unavailable),
        d(.usdc, .model, ["usdc"], nil, decode: .unavailable, encode: .unavailable),
        d(.usdz, .model, ["usdz"], UTType("com.pixar.universal-scene-description-mobile"), decode: .unavailable, encode: .unavailable),

        d(.ass, .subtitle, ["ass"], nil, decode: .native, encode: .native),
        d(.microdvd, .subtitle, ["sub"], nil, decode: .native, encode: .native),
        d(.ssa, .subtitle, ["ssa"], nil, decode: .native, encode: .native),
        d(.srt, .subtitle, ["srt"], nil, decode: .native, encode: .native),
        d(.sub, .subtitle, ["sub"], nil, decode: .native, encode: .native),
        d(.vtt, .subtitle, ["vtt"], nil, decode: .native, encode: .native),

        d(.der, .certificate, ["der", "cer"], nil, decode: .native, encode: .native),
        d(.pem, .certificate, ["pem", "crt"], nil, decode: .native, encode: .native),
        d(.folder, .folder, ["folder"], .folder, decode: .native, encode: .native)
    ]
}
