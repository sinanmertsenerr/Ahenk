import Foundation
import Observation

/// Calls `onChange` on the main actor whenever the observable state read by
/// `value` changes to a different value. The app uses this to react to
/// settings (e.g. `{ settings.general.language }` → rebuild the main menu).
///
/// Observation reports changes before they are applied, so the new value is
/// read on the next main-actor turn; bursts of changes coalesce into one call.
@MainActor
public final class ChangeObserver<Value: Equatable & Sendable> {
    private let value: @MainActor () -> Value
    private let onChange: @MainActor (Value) -> Void
    private var last: Value
    private var isActive = true

    public init(_ value: @escaping @MainActor () -> Value, onChange: @escaping @MainActor (Value) -> Void) {
        self.value = value
        self.onChange = onChange
        self.last = value()
        arm()
    }

    /// Stops observing; `onChange` is not called again.
    public func cancel() {
        isActive = false
    }

    private func arm() {
        guard isActive else { return }
        withObservationTracking {
            _ = value()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.fire() }
        }
    }

    private func fire() {
        guard isActive else { return }
        let current = value()
        if current != last {
            last = current
            onChange(current)
        }
        arm()
    }
}
