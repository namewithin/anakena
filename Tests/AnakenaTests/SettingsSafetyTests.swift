import Foundation
import XCTest
@testable import Anakena

final class SettingsSafetyTests: XCTestCase {
    func testBufferExpiresAfterTenSeconds() {
        XCTAssertFalse(Engine.bufferExpired(since: nil, at: 20_000_000_000))
        XCTAssertFalse(Engine.bufferExpired(since: 1, at: 10_000_000_001))
        XCTAssertTrue(Engine.bufferExpired(since: 1, at: 10_000_000_002))
        XCTAssertFalse(Engine.bufferExpired(since: 20, at: 10))
    }
    func testIgnoredAppMigrationKeepsRemovalAndAddsNewDefaults() throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["com.apple.Terminal", "my.editor"], forKey: "ignoredApps")
        let settings = Settings(defaults: defaults)
        XCTAssertFalse(settings.ignores("com.googlecode.iterm2"))
        XCTAssertTrue(settings.ignores("my.editor"))
        XCTAssertTrue(settings.ignores("net.kovidgoyal.kitty"))
        XCTAssertNil(defaults.object(forKey: "ignoredApps"))
        XCTAssertTrue(settings.ignores("com.jetbrains.intellij"))
        XCTAssertFalse(settings.ignores("com.jetbrainsx.intellij"))
        settings.ignoredApps = settings.ignoredApps.filter { $0 != "com.jetbrains." }
        XCTAssertFalse(settings.ignores("com.jetbrains.intellij"))
    }

    func testResetLearningRemovesAllPairsAndLegacyValues() throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = Settings(defaults: defaults)
        for key in ["alwaysWords", "ignoredWords", "alwaysWords.en-uk", "ignoredWords.pl-uk"] {
            defaults.set(["word"], forKey: key)
        }
        defaults.set(false, forKey: "enabled")
        settings.resetLearning()
        for key in ["alwaysWords", "ignoredWords", "alwaysWords.en-uk", "ignoredWords.pl-uk"] {
            XCTAssertNil(defaults.object(forKey: key))
        }
        XCTAssertFalse(settings.enabled)
    }
}
