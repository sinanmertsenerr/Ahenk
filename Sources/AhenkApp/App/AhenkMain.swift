import AhenkKit
import AppKit

@main
enum AhenkMain {
    @MainActor
    static func main() {
        let options = LaunchOptions(arguments: CommandLine.arguments)
        let environment = AppEnvironment.bootstrap(options: options)
        configureLogging(verbose: environment.settings.general.verboseLogging)
        AhenkLogger(category: "app").notice("\(AppInfo.launchSummary), mode \(options.mode.rawValue)")

        let app = NSApplication.shared
        // A regular app with a Dock icon (the icon becomes the album cover in
        // Step 9); smoke runs stay invisible.
        app.setActivationPolicy(options.mode == .smoke ? .accessory : .regular)
        let delegate = AppDelegate(environment: environment)
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }

    private static func configureLogging(verbose: Bool) {
        do {
            Log.configure(file: try LogFile(directory: Log.directory), verbose: verbose)
        } catch {
            Log.configure(file: nil, verbose: verbose)
            AhenkLogger(category: "app").error("Log file unavailable: \(error)")
        }
    }
}
