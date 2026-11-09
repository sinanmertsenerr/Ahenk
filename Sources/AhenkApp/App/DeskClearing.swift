import Foundation

/// Clear Desk: one click hides every other app, a second click brings each
/// one back exactly as it was (`ClearDeskController`). The menu bar item
/// and the player's moon button only see this.
@MainActor
protocol DeskClearing: AnyObject {
    var isAvailable: Bool { get }
    var isActive: Bool { get }
    func toggle()
}

/// Before the services start (and in tests of the menus): nothing to do.
@MainActor
final class UnavailableDeskClearing: DeskClearing {
    var isAvailable: Bool { false }
    var isActive: Bool { false }
    func toggle() {}
}
