import Foundation
import XCTest
@testable import Anakena

/// Menu text comes from Localization/<lang>.lproj; English is the fallback.
final class MenuTextTests: XCTestCase {
    private static let localization = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Localization")

    private func bundle(_ lang: String) throws -> Bundle {
        try XCTUnwrap(Bundle(path: Self.localization.appendingPathComponent("\(lang).lproj").path))
    }

    private func texts(_ b: Bundle) -> [String] {
        [
            MenuText.enabled(b),
            MenuText.automatic(b),
            MenuText.manualOnly(b),
            MenuText.languages(b),
            MenuText.last("привіт", b),
            MenuText.undoLast(b),
            MenuText.learned(always: 3, ignored: 12, b),
            MenuText.resetLearning(b),
            MenuText.ignoreIn("Safari", b),
            MenuText.launchAtLogin(b),
            MenuText.missingLayouts(b),
            MenuText.missingDictionary("EN/УК", b),
            MenuText.grantAccess(b),
            MenuText.needInputMonitoring(b),
            MenuText.secureInput(b),
            MenuText.accessGranted(b),
            MenuText.quit(b),
        ]
    }

    private let english = [
        "Enabled",
        "Automatic",
        "Manual only",
        "Languages",
        "Last: привіт",
        "Undo last fix (⌃⌥Space)",
        "Learned: 3 always, 12 ignored",
        "Reset learning",
        "Ignore in Safari",
        "Launch at login",
        "⚠︎ Add keyboard layouts for two languages in System Settings → Keyboard",
        "⚠︎ No EN/УК spell-check dictionary",
        "⚠︎ Grant access…",
        "⚠︎ Input Monitoring needed…",
        "⚠︎ Secure Input is on — keys are hidden (log out and back in)",
        "✓ Access granted",
        "Quit",
    ]

    func testEnglish() throws {
        XCTAssertEqual(texts(try bundle("en")), english)
    }

    func testUkrainianMatchesTheOriginalMenu() throws {
        XCTAssertEqual(texts(try bundle("uk")), [
            "Увімкнено",
            "Автоматично",
            "Тільки вручну",
            "Мови",
            "Останнє: привіт",
            "Скасувати останнє (⌃⌥Space)",
            "Навчено: 3 завжди, 12 ігнор",
            "Скинути навчання",
            "Не чіпати в Safari",
            "Запускати при вході",
            "⚠︎ Додай розкладки двох мов у Системні параметри → Клавіатура",
            "⚠︎ Немає словника EN/УК для перевірки правопису",
            "⚠︎ Дати доступ…",
            "⚠︎ Потрібен Input Monitoring…",
            "⚠︎ Secure Input активний — клавіші не видно (вийди/зайди в акаунт)",
            "✓ Доступ є",
            "Вийти",
        ])
    }

    func testLanguageWithoutTranslationFallsBackToEnglish() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        XCTAssertEqual(texts(try XCTUnwrap(Bundle(path: empty.path))), english)
    }

    func testTestHostUsesEnglish() {
        XCTAssertEqual(texts(.main), english)
    }
}
