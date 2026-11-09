import AhenkKit
import AppKit
import Observation
import SwiftUI

/// The clock's text, updated once a minute (and when the format, the
/// language or the Mac's clock changes). Nothing ticks while the clock is
/// hidden.
@MainActor
@Observable
final class ClockModel {
    private(set) var time = ClockText.Time(digits: "", dayPeriod: nil)
    private(set) var date = ""

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var timer: DispatchWorkItem?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var settingsObserver: ChangeObserver<String>?
    @ObservationIgnored private(set) var isRunning = false

    init(settings: AppSettings) {
        self.settings = settings
        refresh()
    }

    /// Starts ticking at every full minute.
    func resume() {
        guard !isRunning else { return }
        isRunning = true
        let center = NotificationCenter.default
        for name in [NSNotification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange, NSLocale.currentLocaleDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            })
        }
        // Waking from sleep: the minute moved on meanwhile.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        })
        let settings = self.settings
        settingsObserver = ChangeObserver({ "\(settings.player.clockFormat.rawValue)|\(settings.general.language.rawValue)" }) { [weak self] _ in
            self?.refresh()
        }
        tick()
    }

    func pause() {
        guard isRunning else { return }
        isRunning = false
        timer?.cancel()
        timer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        settingsObserver = nil
    }

    private func tick() {
        refresh()
        timer?.cancel()
        guard isRunning else { return }
        let work = DispatchWorkItem { [weak self] in self?.tick() }
        timer = work
        let wait = ClockText.secondsToNextMinute(after: Date(), timeZone: .current) + 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    func refresh() {
        let now = Date()
        let locale = settings.general.language.locale()
        let twentyFour = ClockText.uses24Hour(settings.player.clockFormat, systemUses24Hour: ClockText.localeUses24Hour(.current))
        let newTime = ClockText.time(now, twentyFourHour: twentyFour, locale: locale, timeZone: .current)
        let newDate = ClockText.date(now, locale: locale, timeZone: .current)
        if newTime != time { time = newTime }
        if newDate != date { date = newDate }
    }

    /// The widest the clock gets in this format (for the window's size).
    var template: ClockText.Time {
        ClockText.Time(digits: "88:88", dayPeriod: time.dayPeriod)
    }
}

/// The big thin clock with the date above it.
struct ClockWidget: View {
    let clock: ClockModel
    let model: DesktopPlayerModel
    let settings: PlayerSettings
    /// Draws the widest time instead of the current one (measuring).
    var measuring = false

    var body: some View {
        let scale = settings.clockScale
        let time = measuring ? clock.template : clock.time
        let theme = model.theme
        VStack(alignment: .leading, spacing: -14 * scale) {
            if settings.showDate {
                Text(clock.date.isEmpty ? " " : clock.date)
                    .font(.system(size: 17 * scale, weight: .semibold))
                    .foregroundStyle(theme.clock)
                    .padding(.leading, 6 * scale)
                    .lineLimit(1)
                    .fixedSize()
            }
            HStack(alignment: .firstTextBaseline, spacing: 8 * scale) {
                Text(time.digits)
                    .font(.system(size: 150 * scale, weight: .ultraLight).width(.compressed))
                    .monospacedDigit()
                    .tracking(-2 * scale)
                    .foregroundStyle(
                        LinearGradient(colors: [.white, theme.clock], startPoint: .top, endPoint: .bottom)
                    )
                if let period = time.dayPeriod {
                    Text(period)
                        .font(.system(size: 26 * scale, weight: .light).width(.condensed))
                        .foregroundStyle(theme.clock)
                }
            }
            .fixedSize()
        }
        .shadow(color: .black.opacity(0.28), radius: 14, y: 4)
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .fixedSize()
        .hitArea()
        .movesWidget()
        .accessibilityElement(children: .combine)
        .animation(.smooth(duration: 0.6), value: theme)
    }
}
