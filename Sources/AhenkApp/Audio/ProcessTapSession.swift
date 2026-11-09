import Accelerate
import AhenkKit
import AudioToolbox
import CoreAudio
import Foundation

/// One running Core Audio process tap (macOS 14.2+): a private stereo tap
/// on some processes (or on everything but some), inside a private
/// aggregate device clocked by an output-only device, with an IOProc that
/// mixes each buffer to mono and writes it into the analysis ring.
///
/// The tap is unmuted: the app is heard as always. The one exception is
/// the sound effects (`muted`): then the tapped processes fall silent for
/// as long as the tap is read, the IOProc also hands the stereo sound to
/// the effects' output, and Ahenk plays it instead. A muted tap is only
/// ever made on the processes of one app, never on everything, and only in
/// a normal run (``mutingAllowed``); when the tap or Ahenk goes away,
/// macOS gives the app its own sound back.
///
/// The IOProc is real-time safe: a C function with a plain context (raw
/// pointers, no reference counting), vDSP for the mixdown and the ring's
/// lock-free writer. Nothing is recorded, saved or sent anywhere; the
/// samples live in the ring until the analysis reads them.
///
/// Build and stop it on one serial queue (HAL calls block on the audio
/// server for milliseconds, longer while macOS shows a prompt); never on
/// the main thread.
/// Which processes a tap hears.
enum TapScope: Equatable {
    /// These process objects only.
    case processes([AudioObjectID])
    /// Every process except these.
    case everythingExcept([AudioObjectID])
}

@available(macOS 14.2, *)
final class ProcessTapSession {
    struct Failure: Error, CustomStringConvertible {
        let stage: String
        let status: OSStatus

        var description: String { "\(stage) failed (OSStatus \(status))" }
    }

    let scope: TapScope
    let sampleRate: Double
    let channelCount: Int
    /// The output's latency, for the presentation delay.
    let outputLatency: Double
    /// The device that clocks the tap (normally the default output).
    let clockDeviceUID: String
    /// The tapped processes are silent while this tap runs (sound effects).
    let isMuted: Bool

    /// Set once at launch: true in a normal run only. Demo and smoke runs
    /// can never silence an app, whatever asks for it.
    nonisolated(unsafe) static var mutingAllowed = false

    private let ring: AudioRingBuffer
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let context: UnsafeMutablePointer<TapIOContext>
    private var isStopped = false

    /// - Parameter effects: where the stereo sound goes for the sound
    ///   effects. With it the tap mutes the processes it hears, so it is
    ///   refused for a tap on everything and outside a normal run.
    init(scope: TapScope, ring: AudioRingBuffer, effects: AudioRingBuffer? = nil) throws {
        if effects != nil {
            guard Self.mutingAllowed else {
                throw Failure(stage: "muting an app in a demo or smoke run (refused)", status: OSStatus(kAudioHardwareIllegalOperationError))
            }
            guard case .processes = scope else {
                throw Failure(stage: "muting every app (refused)", status: OSStatus(kAudioHardwareIllegalOperationError))
            }
        }
        self.scope = scope
        self.ring = ring
        isMuted = effects != nil
        let context = UnsafeMutablePointer<TapIOContext>.allocate(capacity: 1)
        context.initialize(to: TapIOContext(writer: ring.writer, stereo: effects?.writer, scratchCapacity: 8_192))
        self.context = context

        // Fill everything in a local first so a failure can tear down what
        // exists without touching half-initialized properties.
        var tap = AudioObjectID(kAudioObjectUnknown)
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        var procID: AudioDeviceIOProcID?
        func cleanUp() {
            if let procID, aggregate != kAudioObjectUnknown { AudioDeviceDestroyIOProcID(aggregate, procID) }
            if aggregate != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregate) }
            if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
            context.pointee.release()
            context.deinitialize(count: 1)
            context.deallocate()
        }

        let description: CATapDescription
        switch scope {
        case .processes(let objects): description = CATapDescription(stereoMixdownOfProcesses: objects)
        case .everythingExcept(let objects): description = CATapDescription(stereoGlobalTapButExcludeProcesses: objects)
        }
        description.uuid = UUID()
        description.name = "Ahenk"
        description.isPrivate = true
        // Never silence the music while listening to it, except to play it
        // again with the sound effects.
        description.muteBehavior = effects != nil ? .mutedWhenTapped : .unmuted

        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != kAudioObjectUnknown else {
            cleanUp()
            throw Failure(stage: "AudioHardwareCreateProcessTap", status: status)
        }

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = CoreAudioQueries.address(kAudioTapPropertyFormat)
        status = AudioObjectGetPropertyData(tap, &formatAddress, 0, nil, &size, &format)
        guard status == noErr, format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32, format.mSampleRate > 0, format.mChannelsPerFrame > 0
        else {
            cleanUp()
            throw Failure(stage: "reading the tap format", status: status)
        }

        // A bare tap delivers nothing; it rides in an aggregate device with
        // a real output device as its clock.
        guard let clock = CoreAudioQueries.clockDevice(), let clockUID = CoreAudioQueries.uid(of: clock) else {
            cleanUp()
            throw Failure(stage: "finding an output device", status: OSStatus(kAudioHardwareBadDeviceError))
        }
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Ahenk Listening",
            kAudioAggregateDeviceUIDKey: "com.sinanmertsener.Ahenk.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: clockUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: clockUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate)
        guard status == noErr, aggregate != kAudioObjectUnknown else {
            cleanUp()
            throw Failure(stage: "AudioHardwareCreateAggregateDevice", status: status)
        }

        status = AudioDeviceCreateIOProcID(aggregate, tapIOProc, UnsafeMutableRawPointer(context), &procID)
        guard status == noErr, let procID else {
            cleanUp()
            throw Failure(stage: "AudioDeviceCreateIOProcID", status: status)
        }
        status = AudioDeviceStart(aggregate, procID)
        guard status == noErr else {
            cleanUp()
            throw Failure(stage: "AudioDeviceStart", status: status)
        }

        tapID = tap
        aggregateID = aggregate
        ioProcID = procID
        clockDeviceUID = clockUID
        // The aggregate runs at its clock's rate; the tap is resampled to it.
        sampleRate = CoreAudioQueries.nominalSampleRate(of: aggregate) ?? format.mSampleRate
        channelCount = Int(format.mChannelsPerFrame)
        outputLatency = CoreAudioQueries.outputLatency()
    }

    /// Stops the IOProc and destroys the aggregate device and the tap
    /// (in that order). Idempotent.
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = kAudioObjectUnknown
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = kAudioObjectUnknown
        // The IOProc is gone, so nothing reads the context any more.
        context.pointee.release()
        context.deinitialize(count: 1)
        context.deallocate()
    }

    deinit {
        stop()
    }
}

/// What the IOProc needs: the ring's writer and a mono scratch buffer, and
/// for the sound effects a second writer for the stereo sound. Plain
/// values and raw pointers only, so the I/O thread does no reference
/// counting.
struct TapIOContext {
    let writer: AudioRingBuffer.Writer
    /// Interleaved stereo for the sound effects' output, when they are on.
    let stereo: AudioRingBuffer.Writer?
    let scratch: UnsafeMutablePointer<Float>
    let scratchCapacity: Int
    let stereoScratch: UnsafeMutablePointer<Float>?

    init(writer: AudioRingBuffer.Writer, stereo: AudioRingBuffer.Writer? = nil, scratchCapacity: Int) {
        self.writer = writer
        self.stereo = stereo
        self.scratchCapacity = scratchCapacity
        scratch = .allocate(capacity: scratchCapacity)
        scratch.initialize(repeating: 0, count: scratchCapacity)
        if stereo != nil {
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacity * 2)
            buffer.initialize(repeating: 0, count: scratchCapacity * 2)
            stereoScratch = buffer
        } else {
            stereoScratch = nil
        }
    }

    func release() {
        scratch.deallocate()
        stereoScratch?.deallocate()
    }

    /// Hands the buffer on as interleaved stereo for the sound effects'
    /// output: the first two channels as they are (one channel twice).
    /// Whole chunks only, so left and right can never swap; a chunk that
    /// does not fit is dropped.
    func feed(_ list: UnsafePointer<AudioBufferList>) {
        guard let stereo, let stereoScratch else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        // Where the left and the right channel are, and how far apart
        // their samples.
        var left: (data: UnsafeMutablePointer<Float>, stride: Int)?
        var right: (data: UnsafeMutablePointer<Float>, stride: Int)?
        var frames = Int.max
        for buffer in buffers {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self), buffer.mNumberChannels > 0 else { continue }
            let channels = Int(buffer.mNumberChannels)
            frames = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels))
            for channel in 0..<channels {
                if left == nil {
                    left = (data + channel, channels)
                } else if right == nil {
                    right = (data + channel, channels)
                }
            }
            if right != nil { break }
        }
        guard let left, frames > 0, frames != Int.max else { return }
        let second = right ?? left
        var done = 0
        while done < frames {
            let count = min(scratchCapacity, frames - done)
            guard stereo.free >= count * 2 else { return }
            var one: Float = 1
            vDSP_vsmul(left.data + done * left.stride, left.stride, &one, stereoScratch, 2, vDSP_Length(count))
            vDSP_vsmul(second.data + done * second.stride, second.stride, &one, stereoScratch + 1, 2, vDSP_Length(count))
            stereo.write(stereoScratch, count: count * 2)
            done += count
        }
    }

    /// Averages every channel of every buffer into mono and writes it to the
    /// ring. Taps deliver interleaved or separate channels depending on
    /// the device; both are handled.
    func mix(_ list: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        var frames = Int.max
        var channels = 0
        for buffer in buffers where buffer.mData != nil && buffer.mNumberChannels > 0 {
            frames = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * Int(buffer.mNumberChannels)))
            channels += Int(buffer.mNumberChannels)
        }
        guard channels > 0, frames > 0, frames != Int.max else { return }
        var gain = 1 / Float(channels)
        var done = 0
        while done < frames {
            let count = min(scratchCapacity, frames - done)
            var first = true
            for buffer in buffers {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self), buffer.mNumberChannels > 0 else { continue }
                let stride = Int(buffer.mNumberChannels)
                for channel in 0..<stride {
                    let source = data + done * stride + channel
                    if first {
                        vDSP_vsmul(source, stride, &gain, scratch, 1, vDSP_Length(count))
                        first = false
                    } else {
                        vDSP_vsma(source, stride, &gain, scratch, 1, scratch, 1, vDSP_Length(count))
                    }
                }
            }
            writer.write(scratch, count: count)
            done += count
        }
    }
}

/// The tap's IOProc, on Core Audio's real-time I/O thread.
private func tapIOProc(
    _ device: AudioObjectID,
    _ now: UnsafePointer<AudioTimeStamp>,
    _ inputData: UnsafePointer<AudioBufferList>,
    _ inputTime: UnsafePointer<AudioTimeStamp>,
    _ outputData: UnsafeMutablePointer<AudioBufferList>,
    _ outputTime: UnsafePointer<AudioTimeStamp>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let context = clientData?.assumingMemoryBound(to: TapIOContext.self) else { return noErr }
    // The analysis hears the sound as the app made it; the effects' output
    // gets its own copy in stereo.
    context.pointee.mix(inputData)
    context.pointee.feed(inputData)
    return noErr
}
