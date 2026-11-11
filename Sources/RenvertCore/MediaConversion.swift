import Foundation
import AVFoundation
import AppKit

enum FFmpegArguments {
    static func make(source: URL, spec: OutputSpec, destination: URL) -> [String] {
        var args = ["-y", "-hide_banner", "-loglevel", "error", "-i", source.path]
        let muted = spec.modifiers.contains(.mute)
        if muted { args += ["-an"] }
        if let q = spec.quality() {
            args += ["-q:v", String(max(1, 31 - Int(Double(q) / 100.0 * 30)))]
        }
        if spec.modifiers.contains(.min) {
            args += ["-crf", "32", "-preset", "fast"]
        }
        if let bitrate = spec.bitrate() {
            args += ["-b:a", "\(bitrate)k"]
        }
        if spec.modifiers.contains(.mono) { args += ["-ac", "1"] }

        let videoTarget = videoContainers.contains(spec.format) || spec.format == .gif
        var videoFilters: [String] = []
        var audioFilters: [String] = []
        if videoTarget, let height = spec.maxHeight() {
            videoFilters.append("scale=-2:\(height)")
        } else if videoTarget, let width = spec.modifiers.compactMap({ modifier -> Int? in
            if case .width(let value) = modifier { return value }
            return nil
        }).first {
            videoFilters.append("scale=\(width):-2")
        }
        if !muted && spec.modifiers.contains(.normalize) {
            audioFilters.append("loudnorm=I=-16")
        }
        if let speed = spec.speed() {
            if videoTarget {
                videoFilters.append("setpts=\(1 / speed)*PTS")
            }
            if !muted {
                audioFilters.append("atempo=\(min(2.0, max(0.5, speed)))")
            }
        }
        if spec.modifiers.contains(.reverse) {
            if videoTarget { videoFilters.append("reverse") }
            if !muted { audioFilters.append("areverse") }
        }
        if spec.format == .gif {
            videoFilters.append("fps=12,scale=480:-1:flags=lanczos")
        }
        if !videoFilters.isEmpty {
            args += ["-vf", videoFilters.joined(separator: ",")]
        }
        if !audioFilters.isEmpty {
            args += ["-af", audioFilters.joined(separator: ",")]
        }

        if let fps = spec.fps() {
            args += ["-r", String(fps)]
        }
        if let codec = spec.videoCodec(), spec.format != .mp4 {
            switch codec {
            case .vp9: args += ["-c:v", "libvpx-vp9"]
            case .av1: args += ["-c:v", "libaom-av1"]
            case .prores: args += ["-c:v", "prores_ks"]
            }
        }
        if let codec = spec.audioCodec() {
            switch codec {
            case .aac: args += ["-c:a", "aac"]
            case .alac: args += ["-c:a", "alac"]
            case .pcm: args += ["-c:a", "pcm_s24le"]
            case .vorbis: args += ["-c:a", "libvorbis"]
            case .opus: args += ["-c:a", "libopus"]
            case .flac: args += ["-c:a", "flac"]
            }
        }
        if spec.format == .mp3 { args += ["-c:a", "libmp3lame"] }
        if spec.format == .mp4 { args += ["-c:v", "libx264", "-pix_fmt", "yuv420p"] }
        if let trim = spec.trimRange() {
            if let start = trim.0 { args += ["-ss", String(start.seconds)] }
            if let end = trim.1 { args += ["-to", String(end.seconds)] }
        }
        args.append(destination.path)
        return args
    }
}

public struct MediaConverter: Converter {
    public init() {}

    public func convert(from source: URL, detected: FormatID, spec: OutputSpec, to destination: URL, context: ConversionContext) throws {
        try context.cancellation.throwIfCancelled()
        if spec.format == .gif {
            if let ffmpeg = ExternalToolLocator.ffmpeg {
                try runFFmpeg(from: source, spec: spec, to: destination, ffmpeg: ffmpeg, context: context)
                return
            }
            try extractFrame(from: source, spec: spec, to: destination, context: context)
            return
        }
        if imageEncodable.contains(spec.format) {
            try extractFrame(from: source, spec: spec, to: destination, context: context)
            return
        }
        if spec.modifiers.contains(.transcribe) || subtitleFormats.contains(spec.format) && spec.modifiers.contains(.transcribe) || spec.format == .txt && spec.modifiers.contains(.transcribe) {
            try IntelligenceConverter().convert(from: source, detected: detected, spec: spec, to: destination, context: context)
            return
        }
        if subtitleFormats.contains(spec.format) {
            try extractSubtitles(from: source, spec: spec, to: destination)
            return
        }

        if let ffmpeg = ExternalToolLocator.ffmpeg, needsFFmpeg(detected: detected, spec: spec) {
            try runFFmpeg(from: source, spec: spec, to: destination, ffmpeg: ffmpeg, context: context)
            return
        }
        // The export session only writes M4A for audio; Core Audio covers WAV, AIFF, CAF and
        // FLAC targets and MP3 or FLAC sources.
        if FormatRegistry.descriptor(for: detected).category == .audio, NativeAudio.canWrite(spec.format) {
            try NativeAudio.transcode(from: source, spec: spec, to: destination, context: context)
            return
        }
        try exportWithAVFoundation(from: source, spec: spec, to: destination, context: context)
    }

    private func needsFFmpeg(detected: FormatID, spec: OutputSpec) -> Bool {
        let ffmpegFormats: Set<FormatID> = [.mp3, .flac, .ogg, .opus, .mkv, .webm, .avi, .gif, .mka, .mpeg, .ts, .m2ts]
        if ffmpegFormats.contains(spec.format) || ffmpegFormats.contains(detected) { return true }
        if spec.modifiers.contains(where: {
            switch $0 {
            case .videoCodec, .speed, .reverse, .normalize, .trim, .fps, .width, .height, .maxHeight, .mute, .mono:
                return true
            default: return false
            }
        }) { return true }
        return false
    }

    private func exportWithAVFoundation(from source: URL, spec: OutputSpec, to destination: URL, context: ConversionContext) throws {
        let asset = AVURLAsset(url: source)
        let preset = preset(for: spec)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            if let ffmpeg = ExternalToolLocator.ffmpeg {
                try runFFmpeg(from: source, spec: spec, to: destination, ffmpeg: ffmpeg, context: context)
                return
            }
            throw RenvertError.converterFailed(L("AVFoundation cannot export this asset."))
        }
        session.outputURL = destination
        session.outputFileType = fileType(for: spec.format)
        if spec.modifiers.contains(.mute) {
            let mix = AVMutableAudioMix()
            mix.inputParameters = asset.tracks(withMediaType: .audio).map { track in
                let input = AVMutableAudioMixInputParameters(track: track)
                input.setVolume(0, at: .zero)
                return input
            }
            session.audioMix = mix
        }
        if let range = timeRange(for: spec, asset: asset) {
            session.timeRange = range
        }
        if !context.settings.conversion.preserveMetadata || spec.modifiers.contains(.noMeta) {
            session.metadata = []
        }

        let semaphore = DispatchSemaphore(value: 0)
        var exportError: Error?
        session.exportAsynchronously {
            if session.status != .completed {
                exportError = session.error ?? RenvertError.converterFailed(L("Export failed."))
            }
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now() + 0.2) == .timedOut {
            context.onProgress?(Double(session.progress))
            if context.cancellation.isCancelled {
                session.cancelExport()
                throw RenvertError.cancelled
            }
        }
        if let exportError { throw exportError }
    }

    private func runFFmpeg(from source: URL, spec: OutputSpec, to destination: URL, ffmpeg: URL, context: ConversionContext) throws {
        let args = FFmpegArguments.make(source: source, spec: spec, destination: destination)
        let result = ProcessRunner.run(executable: ffmpeg.path, arguments: args, cancellation: context.cancellation)
        if result.exitCode == -2 { throw RenvertError.cancelled }
        guard result.exitCode == 0 else {
            throw RenvertError.converterFailed(result.stderr.isEmpty ? "ffmpeg failed" : result.stderr)
        }
    }

    private func extractFrame(from source: URL, spec: OutputSpec, to destination: URL, context: ConversionContext) throws {
        if let ffmpeg = ExternalToolLocator.ffmpeg {
            var args = ["-y", "-hide_banner", "-loglevel", "error", "-i", source.path]
            if let at = spec.atTime() {
                args = ["-y", "-hide_banner", "-loglevel", "error", "-ss", String(at.seconds), "-i", source.path]
            }
            args += ["-frames:v", "1", destination.path]
            let result = ProcessRunner.run(executable: ffmpeg.path, arguments: args, cancellation: context.cancellation)
            if result.exitCode == 0 { return }
        }
        let asset = AVURLAsset(url: source)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        var time = CMTime(seconds: 0, preferredTimescale: 600)
        if let at = spec.atTime() {
            time = CMTime(seconds: at.seconds, preferredTimescale: 600)
        }
        let image = try generator.copyCGImage(at: time, actualTime: nil)
        let ns = NSImage(cgImage: image, size: .zero)
        try ImageConverter().writeImage(
            ns,
            to: destination,
            utType: ImageIOSupport.utType(for: spec.format) ?? .png,
            spec: spec,
            settings: context.settings
        )
    }

    private func extractSubtitles(from source: URL, spec: OutputSpec, to destination: URL) throws {
        guard let ffmpeg = ExternalToolLocator.ffmpeg else {
            throw RenvertError.toolMissing("ffmpeg")
        }
        let result = ProcessRunner.run(
            executable: ffmpeg.path,
            arguments: ["-y", "-hide_banner", "-loglevel", "error", "-i", source.path, "-map", "0:s:0", destination.path]
        )
        guard result.exitCode == 0 else {
            throw RenvertError.converterFailed(L("No embedded subtitle track was found. Use +transcribe to create one."))
        }
        _ = spec
    }

    private func preset(for spec: OutputSpec) -> String {
        if spec.modifiers.contains(.min) { return AVAssetExportPresetMediumQuality }
        if spec.format == .m4a || spec.format == .aac || spec.format == .wav || spec.format == .caf || spec.format == .aiff || spec.format == .alac {
            return AVAssetExportPresetAppleM4A
        }
        if let height = spec.maxHeight() {
            switch height {
            case ...480: return AVAssetExportPreset640x480
            case ...720: return AVAssetExportPreset1280x720
            case ...1080: return AVAssetExportPreset1920x1080
            default: return AVAssetExportPresetHighestQuality
            }
        }
        return AVAssetExportPresetHighestQuality
    }

    private func fileType(for format: FormatID) -> AVFileType {
        switch format {
        case .mp4: return .mp4
        case .mov: return .mov
        case .m4a, .aac, .alac: return .m4a
        case .wav: return .wav
        case .caf: return .caf
        case .aiff: return .aiff
        default: return .mp4
        }
    }

    private func timeRange(for spec: OutputSpec, asset: AVAsset) -> CMTimeRange? {
        guard let trim = spec.trimRange() else {
            return nil
        }
        let start = CMTime(seconds: trim.0?.seconds ?? 0, preferredTimescale: 600)
        let endSeconds = trim.1?.seconds ?? 0
        let resolvedEnd = endSeconds > 0 ? endSeconds : start.seconds + 3600
        let end = CMTime(seconds: resolvedEnd, preferredTimescale: 600)
        return CMTimeRange(start: start, end: end)
    }
}
