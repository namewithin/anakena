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
    func testSwitchConsequencesAreNotDetectorFalsePositives() throws {
        struct Words: Speller {
            func isCorrect(_ word: String, in lang: Lang) -> Bool {
                lang == .uk && word.lowercased() == "нова"
            }
        }
        let corrector = Corrector(layouts: try layouts(), speller: Words())
        let (prefix, words) = FuzzGenerator.words("Нова PR", layouts: corrector.layouts)
        let input = FuzzInput(prefix: prefix, words: words, mistaken: [0])
        var replay = FuzzReplay(corrector: corrector)
        let got = replay.process(input)
        XCTAssertEqual(input.typed, "Yjdf PR")
        XCTAssertEqual(replay.presented, "Yjdf ЗК")
        XCTAssertEqual(got, "Нова ЗК")
        XCTAssertEqual(replay.decisions.map(\.typed), ["Yjdf"])
        XCTAssertEqual(replay.decisions.map(\.converted), ["Нова"])
        var stats = FuzzStats()
        _ = stats.record(typed: input.typed, got: got, expected: "Нова PR", presented: replay.presented)
        XCTAssertEqual(stats.falsePositives, 1, "Baseline metric retains the end-to-end consequence")
        XCTAssertEqual(stats.detectorFalsePositives, 0)
        XCTAssertEqual(stats.layoutAffected, 1)
        XCTAssertEqual(stats.layoutUnresolved, 1)
        XCTAssertEqual(stats.detectorMissed, 1)
        // Reusing the replay must not retain the previous run's state or trace.
        XCTAssertEqual(replay.process(input), got)
        XCTAssertEqual(replay.presentedWords.count, 2)
        XCTAssertEqual(replay.decisions.count, 1)
    }

    func testActualInputMetricsKeepDirectErrorsAndPreventedErrorsSeparate() {
        var stats = FuzzStats()
        _ = stats.record(typed: "hello руддщ руддщ", got: "руддщ hello wrong",
                         expected: "hello hello hello", presented: "hello hello руддщ")
        XCTAssertEqual(stats.detectorFalsePositives, 1)
        XCTAssertEqual(stats.detectorWrong, 1)
        XCTAssertEqual(stats.detectorMissed, 0)
        XCTAssertEqual(stats.layoutAffected, 1)
        XCTAssertEqual(stats.layoutUnresolved, 0, "An automatic switch prevented the second error")
    }

    func testRetroChangeIsRecordedAsDetectorFalsePositive() throws {
        struct Words: Speller {
            func isCorrect(_ word: String, in lang: Lang) -> Bool {
                lang == .uk && ["одне", "і"].contains(word.lowercased())
            }
        }
        let corrector = Corrector(layouts: try layouts(), speller: Words())
        let (prefix, words) = FuzzGenerator.words("s одне", layouts: corrector.layouts)
        var replay = FuzzReplay(corrector: corrector)
        let input = FuzzInput(prefix: prefix, words: words, mistaken: [])
        let got = replay.process(input)
        XCTAssertEqual(replay.presented, "s одне")
        XCTAssertEqual(got, "і одне")
        XCTAssertEqual(replay.decisions.map(\.kind), ["retro"])
        var stats = FuzzStats()
        _ = stats.record(typed: input.typed, got: got, expected: "s одне", presented: replay.presented)
        XCTAssertEqual(stats.detectorFalsePositives, 1)
        XCTAssertEqual(stats.layoutAffected, 0)
    }

}
