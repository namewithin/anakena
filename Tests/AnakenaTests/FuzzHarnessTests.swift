import XCTest
@testable import Anakena

/// Structural replay checks use a fixed speller, not corpus quality measurements.
final class FuzzHarnessTests: XCTestCase {
    private func layouts() throws -> LayoutSet {
        let layouts = LayoutSet(ids: [.en: "com.apple.keylayout.ABC", .uk: "com.apple.keylayout.Ukrainian-PC"])
        guard layouts.tables[.en] != nil, layouts.tables[.uk] != nil else { throw XCTSkip("EN/UK layouts unavailable") }
        return layouts
    }

    func testMutationPreservesSeparatorsDigitsAndUnmappedTokens() throws {
        let layouts = try layouts()
        let (prefix, words) = FuzzGenerator.words("hello,  world\tодне\nword42 hi🙂", layouts: layouts)
        var random = SplitMix64(seed: 1)
        let input = FuzzGenerator.input(prefix: prefix, words: words, mode: .wrongAll, rng: &random)
        XCTAssertEqual(input.words.map(\.following), ["  ", "\t", "\n", " ", ""])
        XCTAssertFalse(input.mistaken.contains(3), "A token containing digits stays as typed")
        XCTAssertFalse(input.mistaken.contains(4), "A token containing an unmapped character stays as typed")
        for index in input.mistaken {
            let word = words[index]
            let restored = try word.wrong.map { char -> String in
                let other = try XCTUnwrap(layouts.other(try XCTUnwrap(word.own)))
                let stroke = try XCTUnwrap(layouts.tables[other]?.stroke(for: String(char)))
                return try XCTUnwrap(layouts.tables[try XCTUnwrap(word.own)]?.char(for: stroke))
            }.joined()
            XCTAssertEqual(restored, word.intended)
        }
    }

    func testMetricsSeparateMissedWrongAndFalsePositives() {
        var stats = FuzzStats()
        _ = stats.record(typed: "руддщ цщкдв", got: "hello цщкдв", expected: "hello world")
        XCTAssertEqual(stats.fixed, 1)
        XCTAssertEqual(stats.needsFix, 2)
        XCTAssertEqual(stats.missed, 1)
        XCTAssertEqual(stats.wrong, 0)
        _ = stats.record(typed: "руддщ", got: "wrong", expected: "hello")
        XCTAssertEqual(stats.wrong, 1)
        _ = stats.record(typed: "hello", got: "руддщ", expected: "hello")
        XCTAssertEqual(stats.falsePositives, 1)
    }

    func testExcludedTokensStayLiteralAfterAutomaticLayoutSwitch() throws {
        struct Words: Speller {
            func isCorrect(_ word: String, in lang: Lang) -> Bool {
                let words: Set<String> = lang == .uk ? ["нова", "версія", "обов'язковий"] : ["update"]
                return words.contains(word.lowercased())
            }
        }
        let corrector = Corrector(layouts: try layouts(), speller: Words())
        for text in ["Нова версія v2.1", "Нова ABC-123, UI-45. Q3. v3.",
                     "Нова п'ятницю, обов'язковий.", "Нова hi🙂"] {
            let (prefix, words) = FuzzGenerator.words(text, layouts: corrector.layouts)
            var rng = SplitMix64(seed: 1)
            let input = FuzzGenerator.input(prefix: prefix, words: words, mode: .wrongAll, rng: &rng)
            var replay = FuzzReplay(corrector: corrector)
            XCTAssertEqual(replay.process(input), text)
        }
    }
}
