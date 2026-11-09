import AhenkKit
import AVFoundation
import MediaToolbox

/// Puts Ahenk's own audio tap on a player item: MediaToolbox's processing
/// tap hands every buffer the item plays to `OwnAudioTap`, which mixes it to
/// mono for the analysis. The sound itself passes through untouched, unless
/// the sound effects are on: then their processor changes it in place
/// (`LocalEffectsProcessor`), after the analysis took the dry sound.
///
/// The callbacks are plain C functions; the tap keeps the `OwnAudioTap`
/// alive (retained when created, released in `finalize`) and reaches it
/// without reference counting on the audio thread.
enum LocalAudioTap {
    /// An audio mix with the tap on the asset's first audio track; `nil`
    /// when the asset has no audio track or the tap cannot be made.
    static func audioMix(for asset: AVAsset, tap: OwnAudioTap) async -> AVAudioMix? {
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let owner = Unmanaged.passRetained(tap)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: owner.toOpaque(),
            init: tapInit, finalize: tapFinalize, prepare: tapPrepare, unprepare: tapUnprepare, process: tapProcess
        )
        var processingTap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &processingTap)
        guard status == noErr, let processingTap else {
            owner.release()
            return nil
        }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = processingTap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }
}

private let tapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, storageOut in
    storageOut.pointee = clientInfo
}

private let tapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    Unmanaged<OwnAudioTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private let tapPrepare: MTAudioProcessingTapPrepareCallback = { tap, maxFrames, format in
    let rate = format.pointee.mSampleRate
    let isFloat = format.pointee.mFormatID == kAudioFormatLinearPCM
        && format.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0
        && format.pointee.mBitsPerChannel == 32
    Unmanaged<OwnAudioTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap))._withUnsafeGuaranteedRef { owner in
        owner.context.pointee.prepare(sampleRate: rate, maxFrames: Int(maxFrames), isFloat: isFloat)
    }
}

private let tapUnprepare: MTAudioProcessingTapUnprepareCallback = { _ in }

private let tapProcess: MTAudioProcessingTapProcessCallback = { tap, numberFrames, _, bufferList, framesOut, flagsOut in
    var range = CMTimeRange()
    guard MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferList, flagsOut, &range, framesOut) == noErr else { return }
    let end = range.isValid ? CMTimeGetSeconds(CMTimeAdd(range.start, range.duration)) : Double.nan
    Unmanaged<OwnAudioTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap))._withUnsafeGuaranteedRef { owner in
        let frames = Int(framesOut.pointee)
        // The dry sound first: the analysis never hears the effects.
        owner.context.pointee.mix(bufferList, frames: frames, mediaTimeEnd: end.isFinite ? end : nil)
        // Then the sound effects, in place, when they are on.
        if let effects = owner.effectsHook.pointer(0) {
            effects.assumingMemoryBound(to: LocalEffectsContext.self).pointee
                .process(bufferList, frames: frames, sampleRate: owner.context.pointee.sampleRate)
        }
    }
}
