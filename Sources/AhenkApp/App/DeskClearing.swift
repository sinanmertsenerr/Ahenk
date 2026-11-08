import Foundation

/// Clear Desk: one click hides every other app, a second click brings each
/// one back exactly as it was. Step 9 provides the implementation; until
/// then the menu shows the item disabled.
@MainActor
protocol DeskClearing: AnyObject {
    var isAvailable: Bool { get }
    var isActive: Bool { get }
    func toggle()
}

@MainActor
final class UnavailableDeskClearing: DeskClearing {
    var isAvailable: Bool { false }
    var isActive: Bool { false }
    func toggle() {}
}
