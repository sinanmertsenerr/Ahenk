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
    private static let log = AhenkLogger(category: "power")

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
        let battery = Self.readIsOnBattery()
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let thermal = ProcessInfo.processInfo.thermalState
        let hot = thermal == .serious || thermal == .critical
        if battery != isOnBattery || lowPower != isLowPowerMode || hot != isThermallyConstrained {
            Self.log.info("Power: \(battery ? "battery" : "power adapter"), Low Power Mode \(lowPower ? "on" : "off"), thermal \(thermal.rawValue)")
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
