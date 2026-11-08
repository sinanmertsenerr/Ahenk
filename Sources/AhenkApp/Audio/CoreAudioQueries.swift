import AhenkKit
import AppKit
import CoreAudio
import Darwin

/// Reads the audio processes and output devices from the Core Audio HAL.
/// Only property reads: nothing here needs a permission or changes any
/// device. HAL calls can block briefly on the audio server, so call them
/// off the main thread.
enum CoreAudioQueries {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) -> T? {
        var address = address(selector, scope: scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &value) { bytes in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, bytes.baseAddress!)
        }
        return status == noErr ? value : nil
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        // Core Audio hands out CF strings retained.
        return value?.takeRetainedValue() as String?
    }

    static func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var result = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr else { return [] }
        return result.filter { $0 != kAudioObjectUnknown }
    }

    // MARK: Processes

    /// Every process that has used Core Audio, with its PID, bundle,
    /// responsible process and parents.
    static func processes() -> [AudioProcess] {
        objects(system, kAudioHardwarePropertyProcessObjectList).compactMap { object in
            guard let pid: pid_t = value(object, kAudioProcessPropertyPID, initial: 0), pid > 0 else { return nil }
            let running: UInt32 = value(object, kAudioProcessPropertyIsRunningOutput, initial: 0) ?? 0
            return AudioProcess(
                objectID: object, pid: pid, bundleIdentifier: string(object, kAudioProcessPropertyBundleID).flatMap { $0.isEmpty ? nil : $0 },
                responsiblePID: responsiblePID(of: pid), ancestors: ancestors(of: pid), isRunningOutput: running != 0
            )
        }
    }

    /// PIDs of the running apps with `bundleIdentifier`.
    static func appPIDs(_ bundleIdentifier: String?) -> Set<Int32> {
        guard let bundleIdentifier else { return [] }
        return Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).map(\.processIdentifier))
    }

    private typealias ResponsibilityFunction = @convention(c) (pid_t) -> pid_t
    /// `responsibility_get_pid_responsible_for_pid` (libSystem; what
    /// Activity Monitor uses to put a helper under its app). Looked up at
    /// run time; without it the matcher falls back to ancestry.
    private static let responsibility: ResponsibilityFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibilityFunction.self)
    }()

    static func responsiblePID(of pid: pid_t) -> Int32? {
        guard let responsibility else { return nil }
        let responsible = responsibility(pid)
        return responsible > 0 ? responsible : nil
    }

    /// Parent, grandparent, … up to launchd.
    static func ancestors(of pid: pid_t) -> [Int32] {
        var chain: [Int32] = []
        var current = pid
        for _ in 0..<12 {
            var info = proc_bsdinfo()
            let read = proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
            guard read == MemoryLayout<proc_bsdinfo>.size, info.pbi_ppid > 0 else { break }
            let parent = pid_t(info.pbi_ppid)
            chain.append(parent)
            guard parent > 1 else { break }
            current = parent
        }
        return chain
    }

    // MARK: Devices

    static var defaultOutputDevice: AudioObjectID? {
        let device: AudioObjectID? = value(system, kAudioHardwarePropertyDefaultOutputDevice, initial: kAudioObjectUnknown)
        return device == kAudioObjectUnknown ? nil : device
    }

    static func uid(of device: AudioObjectID) -> String? {
        string(device, kAudioDevicePropertyDeviceUID)
    }

    static func hasStreams(_ device: AudioObjectID, input: Bool) -> Bool {
        !objects(device, kAudioDevicePropertyStreams, scope: input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput).isEmpty
    }

    /// The device that clocks Ahenk's tap: the default output when it has
    /// no inputs, or else another output-only device (the built-in speakers
    /// first). A device with inputs (a USB headset, an audio interface)
    /// must never join the tap's aggregate device: starting it would start
    /// its microphone. `nil` when no such device exists.
    static func clockDevice() -> AudioObjectID? {
        if let output = defaultOutputDevice, !hasStreams(output, input: true) { return output }
        let candidates = objects(system, kAudioHardwarePropertyDevices).filter { device in
            hasStreams(device, input: false) && !hasStreams(device, input: true)
        }
        let builtIn = candidates.first { value($0, kAudioDevicePropertyTransportType, initial: UInt32(0)) == kAudioDeviceTransportTypeBuiltIn }
        return builtIn ?? candidates.first
    }

    static func nominalSampleRate(of device: AudioObjectID) -> Double? {
        value(device, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)).flatMap { $0 > 0 ? $0 : nil }
    }

    /// Seconds from a sample leaving an app to its sound leaving the
    /// default output (device and stream latency, safety offset, buffer).
    static func outputLatency() -> Double {
        guard let device = defaultOutputDevice, let rate = nominalSampleRate(of: device) else { return 0 }
        let scope = kAudioObjectPropertyScopeOutput
        var frames = Double(value(device, kAudioDevicePropertyLatency, scope: scope, initial: UInt32(0)) ?? 0)
        frames += Double(value(device, kAudioDevicePropertySafetyOffset, scope: scope, initial: UInt32(0)) ?? 0)
        frames += Double(value(device, kAudioDevicePropertyBufferFrameSize, scope: scope, initial: UInt32(0)) ?? 0)
        if let stream = objects(device, kAudioDevicePropertyStreams, scope: scope).first {
            frames += Double(value(stream, kAudioStreamPropertyLatency, initial: UInt32(0)) ?? 0)
        }
        return min(0.5, frames / rate)
    }

    /// Ahenk's own process object, if it has one.
    static func processObject(of pid: pid_t) -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }
}
