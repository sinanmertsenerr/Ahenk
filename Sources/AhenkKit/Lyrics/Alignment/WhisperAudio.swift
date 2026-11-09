import AVFoundation
import Foundation

/// Audio in the one form whisper reads everywhere: a 16 kHz, mono, 16-bit
/// WAV file. Written to a temporary place, read once, deleted.
public enum WhisperAudio {
    public static let sampleRate = 16_000.0

    public struct Failure: Error, Equatable, CustomStringConvertible {
        public var description: String
    }

    /// `samples` at `rate`, as they would sound at `target` (straight
    /// lines between samples: enough for a recogniser, and the captured
    /// audio is already band-limited).
    public static func resample(_ samples: [Float], from rate: Double, to target: Double = sampleRate) -> [Float] {
        guard rate > 0, target > 0, !samples.isEmpty else { return [] }
        if abs(rate - target) < 0.5 { return samples }
        let count = Int((Double(samples.count) * target / rate).rounded(.down))
        guard count > 0 else { return [] }
        let step = rate / target
        var output = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let position = Double(index) * step
            let whole = Int(position)
            let fraction = Float(position - Double(whole))
            let next = min(samples.count - 1, whole + 1)
            output[index] = samples[min(whole, samples.count - 1)] * (1 - fraction) + samples[next] * fraction
        }
        return output
    }

    /// The bytes of a 16 kHz mono WAV file with `samples` (already at
    /// 16 kHz), brought to a comfortable level when they are quiet.
    public static func wavData(_ samples: [Float]) -> Data {
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        // A tap hears a player at whatever volume it is set to.
        let gain: Float = peak > 0.001 && peak < 0.5 ? min(20, 0.7 / peak) : 1
        var data = Data(capacity: 44 + samples.count * 2)
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        append32(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append32(16)
        append16(1)
        append16(1)
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate) * 2)
        append16(2)
        append16(16)
        data.append(contentsOf: Array("data".utf8))
        append32(bytes)
        for sample in samples {
            let value = Int16(max(-1, min(1, sample * gain)) * 32_767)
            append16(UInt16(bitPattern: value))
        }
        return data
    }

    /// Writes captured mono samples (at `rate`) as a WAV file for whisper.
    public static func write(_ samples: [Float], rate: Double, to url: URL) throws {
        let resampled = resample(samples, from: rate)
        guard !resampled.isEmpty else { throw Failure(description: "no audio to write") }
        try wavData(resampled).write(to: url, options: .atomic)
    }

    /// Reads a song file (anything AVFoundation plays) and writes it as a
    /// WAV file for whisper; returns the seconds written.
    @discardableResult
    public static func convert(_ file: URL, to url: URL) async throws -> Double {
        let asset = AVURLAsset(url: file)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else {
            throw Failure(description: "the file has no sound")
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw Failure(description: "the file could not be opened: \(error.localizedDescription)")
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure(description: "the file's sound could not be read") }
        reader.add(output)
        guard reader.startReading() else {
            throw Failure(description: "the file's sound could not be read: \(reader.error?.localizedDescription ?? "unknown")")
        }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length >= MemoryLayout<Float>.size else { continue }
            let start = samples.count
            samples.append(contentsOf: repeatElement(0, count: length / MemoryLayout<Float>.size))
            samples.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length / MemoryLayout<Float>.size * MemoryLayout<Float>.size,
                                               destination: raw.baseAddress! + start * MemoryLayout<Float>.size)
            }
        }
        guard reader.status == .completed, !samples.isEmpty else {
            throw Failure(description: "the file's sound could not be read: \(reader.error?.localizedDescription ?? "nothing decoded")")
        }
        try wavData(samples).write(to: url, options: .atomic)
        return Double(samples.count) / sampleRate
    }
}
