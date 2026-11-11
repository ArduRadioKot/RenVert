import Foundation
import AVFoundation

/// Audio transcoding through Core Audio, for the pairs that need no ffmpeg.
///
/// Reads anything Core Audio decodes (WAV, AIFF, CAF, M4A, MP3, FLAC) and writes WAV, AIFF,
/// CAF, M4A (AAC or Apple Lossless) and FLAC. Sample rate and channel count carry over.
enum NativeAudio {
    static func canWrite(_ format: FormatID) -> Bool {
        // AVAudioFile picks the container from the extension, and ".alac" is not one it knows.
        nativeAudioEncodable.contains(format) && format != .alac
    }

    static func transcode(from source: URL, spec: OutputSpec, to destination: URL, context: ConversionContext) throws {
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: source)
        } catch {
            throw RenvertError.invalidInput(L("Could not decode the audio."))
        }
        let format = input.processingFormat
        let output = try AVAudioFile(
            forWriting: destination,
            settings: settings(for: spec, sampleRate: format.sampleRate, channels: format.channelCount),
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )

        let chunk: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw RenvertError.converterFailed(L("Export failed."))
        }
        let total = max(input.length, 1)
        while input.framePosition < input.length {
            try context.cancellation.throwIfCancelled()
            try input.read(into: buffer, frameCount: chunk)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
            context.onProgress?(Double(input.framePosition) / Double(total))
        }
    }

    private static func settings(for spec: OutputSpec, sampleRate: Double, channels: AVAudioChannelCount) -> [String: Any] {
        var settings: [String: Any] = [
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channels)
        ]
        switch spec.format {
        case .flac:
            settings[AVFormatIDKey] = kAudioFormatFLAC
            settings[AVLinearPCMBitDepthKey] = 16
        case .alac:
            settings[AVFormatIDKey] = kAudioFormatAppleLossless
            settings[AVEncoderBitDepthHintKey] = 16
        case .m4a, .aac:
            if spec.audioCodec() == .alac {
                settings[AVFormatIDKey] = kAudioFormatAppleLossless
                settings[AVEncoderBitDepthHintKey] = 16
            } else {
                settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
                if let bitrate = spec.bitrate() {
                    settings[AVEncoderBitRateKey] = bitrate * 1000
                }
            }
        default:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = spec.format == .aiff
        }
        return settings
    }
}
