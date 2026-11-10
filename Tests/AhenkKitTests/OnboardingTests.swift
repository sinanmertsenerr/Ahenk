import Foundation
import Testing
@testable import AhenkKit

@Suite("First-run guide")
struct OnboardingTests {
    @Test("The pages go from the welcome to the last touches, one step at a time")
    func pageOrder() {
        #expect(OnboardingPage.allCases == [.welcome, .listening, .musicApps, .browser, .finish])
        #expect(OnboardingPage.welcome.previous == nil)
        #expect(OnboardingPage.welcome.next == .listening)
        #expect(OnboardingPage.browser.next == .finish)
        #expect(OnboardingPage.finish.next == nil)
        #expect(OnboardingPage.finish.previous == .browser)
        #expect(OnboardingPage.allCases.map(\.index) == Array(0..<5))
    }

    @Test("The guide opens by itself only on a normal launch that has not seen it")
    func showsAtLaunch() {
        #expect(OnboardingPolicy.showsAtLaunch(mode: .normal, completed: false, requested: false))
        #expect(!OnboardingPolicy.showsAtLaunch(mode: .normal, completed: true, requested: false))
        #expect(OnboardingPolicy.showsAtLaunch(mode: .normal, completed: true, requested: true))
        #expect(!OnboardingPolicy.showsAtLaunch(mode: .demo, completed: false, requested: false), "a demo never opens it uninvited")
        #expect(OnboardingPolicy.showsAtLaunch(mode: .demo, completed: true, requested: true))
        #expect(!OnboardingPolicy.showsAtLaunch(mode: .smoke, completed: false, requested: true), "a smoke run shows no window")
    }

    @Test("Only a normal run's guide is marked seen when it closes")
    func closingCounts() {
        #expect(OnboardingPolicy.closingCountsAsSeen(mode: .normal))
        #expect(!OnboardingPolicy.closingCountsAsSeen(mode: .demo), "a demo shares the stored settings and asked for nothing")
        #expect(!OnboardingPolicy.closingCountsAsSeen(mode: .smoke))
    }

    @Test("Extension versions are read and compared as numbers")
    func versions() {
        #expect(ExtensionVersion("1.2.0") == ExtensionVersion(major: 1, minor: 2, patch: 0))
        #expect(ExtensionVersion("1.2") == ExtensionVersion(major: 1, minor: 2, patch: 0))
        #expect(ExtensionVersion("v1.10.3")?.description == "1.10.3")
        #expect(ExtensionVersion("1.10.0")! > ExtensionVersion("1.9.9")!)
        for bad in ["", "test", "1..2", "1.2.3.4", "1.-2", "1.2b", "١.٢"] {
            #expect(ExtensionVersion(bad) == nil, "\(bad) is not a version")
        }
    }

    @Test("An extension older than the one Ahenk carries must be reloaded")
    func needsReload() {
        #expect(ExtensionVersion.needsReload(reported: "1.1.0"))
        #expect(ExtensionVersion.needsReload(reported: "1.0.0"))
        #expect(!ExtensionVersion.needsReload(reported: ExtensionVersion.shipped.description))
        #expect(!ExtensionVersion.needsReload(reported: "2.0.0"))
        #expect(!ExtensionVersion.needsReload(reported: "test"), "an unreadable version is not flagged")
    }

    @Test("The version Ahenk expects is the one in the extension's manifests")
    func shippedMatchesManifest() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for path in ["Extension/manifest.json", "Extension/firefox/manifest.json"] {
            let data = try Data(contentsOf: root.appendingPathComponent(path))
            let manifest = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let version = try #require(manifest["version"] as? String)
            #expect(ExtensionVersion(version) == ExtensionVersion.shipped, "\(path) says \(version)")
        }
    }
}
