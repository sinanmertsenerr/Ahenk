@preconcurrency import AVFoundation
import Foundation

/// Song files made from generated sound, for tests and the smoke check (no
/// real music anywhere): WAV without tags, and AAC in M4A with tags and an
/// optional cover.
public enum GeneratedSongFiles {
    public enum Failure: Error, Equatable {
        case cannotWrite(String)
    }

    /// A 16-bit PCM WAV of `samples` (mono, −1…1).
    public static func writeWAV(_ samples: [Float], sampleRate: Int, to url: URL) throws {
        var data = Data(capacity: 44 + samples.count * 2)
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + samples.count * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append32(16)
        append16(1)
        append16(1)
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 2))
        append16(2)
        append16(16)
        data.append(contentsOf: Array("data".utf8))
        append32(UInt32(samples.count * 2))
        for sample in samples {
            let clamped = max(-1, min(1, sample.isFinite ? sample : 0))
            append16(UInt16(bitPattern: Int16(clamped * Float(Int16.max))))
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw Failure.cannotWrite(error.localizedDescription)
        }
    }

    /// An M4A (AAC) of `samples` with the given tags.
    public static func writeM4A(
        _ samples: [Float], sampleRate: Int, to url: URL, title: String?, artist: String?, album: String?,
        trackNumber: Int? = nil, artwork: Data? = nil
    ) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        } catch {
            throw Failure.cannotWrite(error.localizedDescription)
        }
        var metadata: [AVMetadataItem] = []
        func item(_ identifier: AVMetadataIdentifier, _ value: (NSCopying & NSObjectProtocol)?, dataType: String? = nil) {
            guard let value else { return }
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value
            if let dataType { item.dataType = dataType }
            metadata.append(item)
        }
        item(.iTunesMetadataSongName, title as NSString?)
        item(.iTunesMetadataArtist, artist as NSString?)
        item(.iTunesMetadataAlbum, album as NSString?)
        if let trackNumber {
            // trkn: two reserved bytes, the number, the total, two reserved.
            var bytes = [UInt8](repeating: 0, count: 8)
            bytes[2] = UInt8((trackNumber >> 8) & 0xFF)
            bytes[3] = UInt8(trackNumber & 0xFF)
            item(.iTunesMetadataTrackNumber, Data(bytes) as NSData, dataType: kCMMetadataBaseDataType_RawData as String)
        }
        if let artwork {
            item(.iTunesMetadataCoverArt, artwork as NSData, dataType: kCMMetadataBaseDataType_PNG as String)
        }
        writer.metadata = metadata

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw Failure.cannotWrite("no audio input") }
        writer.add(input)
        guard writer.startWriting() else { throw Failure.cannotWrite(writer.error?.localizedDescription ?? "startWriting") }
        writer.startSession(atSourceTime: .zero)

        var description = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
            mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0,
            magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDescription
        )
        guard let formatDescription else { throw Failure.cannotWrite("format") }

        let chunk = 8_192
        var offset = 0
        while offset < samples.count {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            let count = min(chunk, samples.count - offset)
            guard let buffer = try sampleBuffer(samples[offset..<(offset + count)], at: offset, rate: sampleRate, format: formatDescription),
                  input.append(buffer)
            else { throw Failure.cannotWrite(writer.error?.localizedDescription ?? "append") }
            offset += count
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw Failure.cannotWrite(writer.error?.localizedDescription ?? "finish") }
    }

    private static func sampleBuffer(_ samples: ArraySlice<Float>, at offset: Int, rate: Int, format: CMAudioFormatDescription) throws -> CMSampleBuffer? {
        let byteCount = samples.count * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block
        ) == noErr, let block else { return nil }
        let status = samples.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard status == noErr else { return nil }
        var buffer: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: samples.count,
            presentationTimeStamp: CMTime(value: CMTimeValue(offset), timescale: CMTimeScale(rate)), packetDescriptions: nil,
            sampleBufferOut: &buffer
        ) == noErr else { return nil }
        return buffer
    }

    /// A short generated song: a kick on every beat at `bpm` under a soft
    /// tone at `frequency`, quiet enough to be harmless if ever heard.
    public static func tone(seconds: Double, sampleRate: Int, bpm: Double = 120, frequency: Double = 330, amplitude: Float = 0.25) -> [Float] {
        let rate = Double(sampleRate)
        var samples = SyntheticSignal.kickTrain(bpm: bpm, seconds: seconds, sampleRate: rate).samples
        let tone = SyntheticSignal.sine(frequency: frequency, seconds: seconds, sampleRate: rate, amplitude: 0.12)
        for index in samples.indices where index < tone.count {
            samples[index] = (samples[index] + tone[index]) * amplitude
        }
        return samples
    }
}
