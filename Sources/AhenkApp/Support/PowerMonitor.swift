import AhenkKit
import AppKit
import Foundation
import IOKit.ps
import Observation

/// Battery, Low Power Mode and heat, as things that make the app run
/// lighter (Settings › General › Run lighter on battery). Event-driven: the
/// power source's run-loop notification and ProcessInfo's notifications;
/// nothing polls.
@MainActor
@Observable
final class PowerMonitor {
    private(set) var isOnBattery = false
    /// Low Power Mode (System Settings › Battery › Low Power Mode, also
    /// "Energy Mode: Low Power").
    private(set) var isLowPowerMode = false
    /// Thermal state serious or critical.
    private(set) var isThermallyConstrained = false

    @ObservationIgnored private var source: CFRunLoopSource?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// `--power` (demo only): acts as if the Mac were in this state, for
    /// measurements; the Mac's own settings are never touched.
    @ObservationIgnored private let simulated: LaunchOptions.SimulatedPower?
    private static let log = AhenkLogger(category: "power")

    init(simulated: LaunchOptions.SimulatedPower? = nil) {
        self.simulated = simulated
    }

    func start() {
        guard source == nil else { return }
        refresh()
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.refresh() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            self.source = source
        }
        let center = NotificationCenter.default
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        source = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    private func refresh() {
        var battery = Self.readIsOnBattery()
        var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let thermal = ProcessInfo.processInfo.thermalState
        var hot = thermal == .serious || thermal == .critical
        switch simulated {
        case .battery: battery = true
        case .lowPower: lowPower = true
        case .hot: hot = true
        case nil: break
        }
        if battery != isOnBattery || lowPower != isLowPowerMode || hot != isThermallyConstrained {
            Self.log.info("Power: \(battery ? "battery" : "power adapter"), Low Power Mode \(lowPower ? "on" : "off"), thermal \(thermal.rawValue)\(simulated.map { " (acting as \($0.rawValue), --power)" } ?? "")")
        }
        if battery != isOnBattery { isOnBattery = battery }
        if lowPower != isLowPowerMode { isLowPowerMode = lowPower }
        if hot != isThermallyConstrained { isThermallyConstrained = hot }
    }

    private static func readIsOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }
}
