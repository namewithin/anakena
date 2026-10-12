import XCTest
@testable import Anakena

/// Exercise the extracted Engine behavior; system-speller checks skip when XPC is unavailable.
final class WordPipelineTests: XCTestCase {
    private struct WordSpeller: Speller {
        func isCorrect(_ word: String, in lang: Lang) -> Bool {
            let words: Set<String> = lang == .en ? ["hello", "do", "here"]
                : ["привіт", "напишу", "запит", "дякую", "одне", "ще", "думаю", "встиг", "ти", "не"]
            return words.contains(word.lowercased())
        }
    }

    private func corrector() throws -> Corrector {
        let layouts = LayoutSet(ids: [.en: "com.apple.keylayout.ABC", .uk: "com.apple.keylayout.Ukrainian-PC"])
        guard layouts.tables[.en] != nil, layouts.tables[.uk] != nil else {
            throw XCTSkip("EN/UK keyboard layouts unavailable")
        }
        return Corrector(layouts: layouts, speller: WordSpeller())
    }

    private func strokes(_ text: String, on lang: Lang, using corrector: Corrector) throws -> [Stroke] {
        try text.map { try XCTUnwrap(corrector.layouts.tables[lang]?.stroke(for: String($0))) }
    }

    private static let currentLayoutSentences = [
        "Принеси, будь ласка, зарядку до мого ноутбука.",
        "Будь ласка, не забудьте заповнити табель.",
        "Дай доступ до репозиторію, будь ласка.",
        // The other four distinct CLEAN failures in the external fuzz report.
        "Зроби, будь ласка, PR до кінця дня.",
        "Скинь скріншот у thread, будь ласка.",
        "Please check the task, будь ласка, до обіду.",
        "Встав у конфіг рядок max_retries = 5, будь ласка.",
    ]

    func testCurrentLayoutWordWinsOverConvertedPunctuationCore() throws {
        struct CollisionSpeller: Speller {
            func isCorrect(_ word: String, in lang: Lang) -> Bool {
                // Both words are real, but only the untrimmed Ukrainian token was typed.
                word.lowercased() == (lang == .uk ? "будь" : "elm")
            }
        }
        let corrector = Corrector(layouts: try corrector().layouts, speller: CollisionSpeller())
        for text in ["будь", "Будь", "будь,", "(Будь!)"] {
            let keys = try strokes(text, on: .uk, using: corrector)
            XCTAssertTrue(corrector.isWord(keys, in: .uk), text)
            for afterFix in [false, true] {
                var pipeline = WordPipeline(afterFix: afterFix)
                guard case .unchanged = pipeline.end(keys, boundary: 49, lang: .uk,
                                                      automatic: true, corrector: corrector) else {
                    XCTFail("Correctly typed \(text) must stay Ukrainian")
                    continue
                }
                XCTAssertFalse(pipeline.afterFix)
            }
        }
        for text in Self.currentLayoutSentences {
            let (prefix, words) = FuzzGenerator.words(text, layouts: corrector.layouts)
            var replay = FuzzReplay(corrector: corrector)
            XCTAssertEqual(replay.process(FuzzInput(prefix: prefix, words: words, mistaken: [])), text)
        }
        var learned = corrector
        learned.always = ["удь"]
        XCTAssertNil(learned.decide(try strokes("будь", on: .uk, using: learned), current: .uk),
                     "A learned partial word must not override the correctly typed full word")
    }

    private func systemCorrector() throws -> Corrector {
        try requireSystemDictionary(.en, word: "hello", misspelled: "ghbdsn")
        try requireSystemDictionary(.uk, word: "привіт", misspelled: "руддщ")
        return Corrector(layouts: try corrector().layouts, speller: SystemSpeller())
    }

    func testSystemSpellerKeepsCurrentLayoutWords() throws {
        let corrector = try systemCorrector()
        XCTAssertTrue(corrector.speller.isCorrect("elm", in: .en))
        for text in ["будь", "Будь", "будь,", "(Будь!)"] {
            let keys = try strokes(text, on: .uk, using: corrector)
            XCTAssertTrue(corrector.isWord(keys, in: .uk), text)
            for afterFix in [false, true] {
                var pipeline = WordPipeline(afterFix: afterFix)
                guard case .unchanged = pipeline.end(keys, boundary: 49, lang: .uk,
                                                      automatic: true, corrector: corrector) else {
                    XCTFail("Correctly typed \(text) must stay Ukrainian")
                    continue
                }
            }
        }
    }

    func testSystemSpellerKeepsCleanRegressionSentences() throws {
        let corrector = try systemCorrector()
        for text in Self.currentLayoutSentences {
            let (prefix, words) = FuzzGenerator.words(text, layouts: corrector.layouts)
            var replay = FuzzReplay(corrector: corrector)
            XCTAssertEqual(replay.process(FuzzInput(prefix: prefix, words: words, mistaken: [])), text)
        }
    }

    func testWrongLayoutPunctuationInBothDirections() throws {
        let corrector = try corrector()
        for (typed, expected, lang) in [
            ("Ghbdsn?", "Привіт,", Lang.en),
            ("yfgbie/", "напишу.", .en),
            ("pfgbn&", "запит?", .en),
            ("?Ghbdsn&", ",Привіт?", .en),
            ("(Ghbdsn?!)", "(Привіт,!)", .en),
            ("lzre.", "дякую", .en),
            ("lzre.,", "дякуюб", .en),
            ("Руддщ,", "Hello?", .uk),
            ("Руддщб", "Hello,", .uk),
            ("Руддщю", "Hello.", .uk),
            ("Руддщ!", "Hello!", .uk),
            ("бРуддщб", ",Hello,", .uk),
            ("(Руддщб!)", "(Hello,!)", .uk),
        ] {
            var pipeline = WordPipeline()
            guard case let .correction(c) = pipeline.end(try strokes(typed, on: lang, using: corrector),
                                                         boundary: 49, lang: lang, automatic: true, corrector: corrector) else {
                XCTFail("Expected correction for \(typed)")
                continue
            }
            // Replace only the token, preserving text before it and the boundary after it.
            XCTAssertEqual("prefix " + String(typed.dropLast(c.deleteCount)) + c.converted + " ",
                           "prefix " + expected + " ", typed)
            XCTAssertEqual(c.deleteCount, typed.count, typed)
            XCTAssertEqual(c.typed, typed, "Undo must restore the original punctuation")
            XCTAssertEqual(c.target, corrector.layouts.other(lang), typed)
        }
    }

    func testUnchangedTokensKeepPunctuation() throws {
        let corrector = try corrector()
        for (typed, lang) in [("hello?", Lang.en), ("(hello!)", .en), ("привіт,", .uk),
                              ("qzx?", .en), ("https://ghbdsn.com/", .en), ("/ghbdsn", .en),
                              ("a/ghbdsn", .en), ("ghbdsn/file", .en), ("ghbdsn_case!", .en),
                              ("ghbdsn_", .en), ("@ghbdsn", .en), ("ghbdsn\\", .en),
                              ("ghbdsn()", .en), ("ghbdsn=[]", .en),
                              ("camelCase?", .en), ("word42!", .en)] {
            var pipeline = WordPipeline()
            guard case .unchanged = pipeline.end(try strokes(typed, on: lang, using: corrector),
                                                  boundary: 49, lang: lang, automatic: true, corrector: corrector) else {
                XCTFail("Must preserve \(typed)")
                continue
            }
            XCTAssertFalse(pipeline.afterFix)
        }
        var ignored = corrector
        ignored.ignored = ["ghbdsn"]
        XCTAssertNil(ignored.decide(try strokes("Ghbdsn?", on: .en, using: ignored), current: .en))
    }

    func testRetroactiveShortWordsConvertAttachedPunctuation() throws {
        let corrector = try corrector()
        for (text, expected) in [("і, ще. одне", "і, ще. одне"), ("(і) ще! одне", "(і) ще! одне"),
                                 ("do, here", "do, here")] {
            let (prefix, words) = FuzzGenerator.words(text, layouts: corrector.layouts)
            var replay = FuzzReplay(corrector: corrector)
            XCTAssertEqual(replay.process(FuzzInput(prefix: prefix, words: words,
                                                   mistaken: Set(words.indices.dropLast()))), expected)
        }
        let (prefix, words) = FuzzGenerator.words("hello? одне", layouts: corrector.layouts)
        var replay = FuzzReplay(corrector: corrector)
        XCTAssertEqual(replay.process(FuzzInput(prefix: prefix, words: words, mistaken: [])), "hello? одне")

        let run = try ["s?", "ot/"].map { (strokes: try strokes($0, on: .en, using: corrector), lang: Lang.en) }
        let fixes = corrector.fixShortWords(run, before: .uk)
        XCTAssertEqual(fixes.map(\.typed), ["s?", "ot/"], "Undo retains the original affixes")
        XCTAssertEqual(fixes.map(\.converted), ["і,", "ще."])
        XCTAssertEqual(fixes.map(\.word), ["s", "ot"], "Undo learns words without punctuation")
        var ignored = corrector
        for fix in fixes { ignored.learn(fix.word, always: false) }
        XCTAssertTrue(ignored.fixShortWords(run, before: .uk).isEmpty)
    }

    func testCorrectionSwitchesLayoutForFollowingKeys() throws {
        let corrector = try corrector()
        let (prefix, words) = FuzzGenerator.words("привіт ще одне", layouts: corrector.layouts)
        var replay = FuzzReplay(corrector: corrector)
        let input = FuzzInput(prefix: prefix, words: words, mistaken: Set(words.indices))
        XCTAssertEqual(input.typed, "ghbdsn ot jlyt")
        XCTAssertEqual(replay.process(input), "привіт ще одне")
    }

    func testLeadingShortWordsBeforeAutomaticCorrection() throws {
        let corrector = try corrector()
        for (typed, intended) in [("Z levf.?", "Я думаю,"), ("Ot yt dcnbu?", "Ще не встиг,"),
                                  ("F nb yt", "А ти не")] {
            let (prefix, words) = FuzzGenerator.words(intended, layouts: corrector.layouts)
            let input = FuzzInput(prefix: prefix, words: words, mistaken: Set(words.indices))
            XCTAssertEqual(input.typed, typed)
            var replay = FuzzReplay(corrector: corrector)
            XCTAssertEqual(replay.process(input), intended)
        }
        var pipeline = WordPipeline()
        _ = pipeline.end(try strokes("Z", on: .en, using: corrector), boundary: 49,
                         lang: .en, automatic: true, corrector: corrector)
        guard case let .correctionGroup(group) = pipeline.end(
            try strokes("levf.?", on: .en, using: corrector), boundary: 49,
            lang: .en, automatic: true, corrector: corrector) else {
            return XCTFail("Expected one replacement for the leading word and anchor")
        }
        XCTAssertEqual(group.map(\.typed).joined(separator: " "), "Z levf.?")
        XCTAssertEqual(group.map(\.converted).joined(separator: " "), "Я думаю,")
        XCTAssertEqual(group.map(\.word), ["Z", "levf."], "Undo learns every corrected word")
        XCTAssertTrue(pipeline.afterFix)
        XCTAssertTrue(pipeline.run.isEmpty)
    }

    func testLeadingShortWordsRespectSeparatorsAndSourceWords() throws {
        let corrector = try corrector()
        for (intended, expected) in [("Я  думаю,", "Z  думаю,"), ("Я\tдумаю,", "Z\tдумаю,"),
                                     ("Я\nдумаю,", "Z\nдумаю,")] {
            let (prefix, words) = FuzzGenerator.words(intended, layouts: corrector.layouts)
            var replay = FuzzReplay(corrector: corrector)
            XCTAssertEqual(replay.process(FuzzInput(prefix: prefix, words: words, mistaken: Set(words.indices))), expected)
        }
        var ignored = corrector
        ignored.ignored = ["z"]
        let (prefix, words) = FuzzGenerator.words("Я думаю,", layouts: corrector.layouts)
        var replay = FuzzReplay(corrector: ignored)
        XCTAssertEqual(replay.process(FuzzInput(prefix: prefix, words: words, mistaken: [0, 1])), "Z думаю,")
        // A valid English single-letter word supplies no Ukrainian context.
        var pipeline = WordPipeline()
        _ = pipeline.end(try strokes("a", on: .en, using: corrector), boundary: 49,
                         lang: .en, automatic: true, corrector: corrector)
        guard case .unchanged = pipeline.end(try strokes("nb", on: .en, using: corrector), boundary: 49,
                                             lang: .en, automatic: true, corrector: corrector) else {
            return XCTFail("Do not use a real source word as a short-word anchor")
        }
    }

    func testRetroactiveShortWordsAcrossUserSwitch() throws {
        let corrector = try corrector()
        let (prefix, words) = FuzzGenerator.words("і ще одне", layouts: corrector.layouts)
        var replay = FuzzReplay(corrector: corrector)
        XCTAssertEqual(replay.process(FuzzInput(prefix: prefix, words: words, mistaken: [0, 1])), "і ще одне")
        // A double Space breaks the run; never delete across it.
        let (p, w) = FuzzGenerator.words("і  ще одне", layouts: corrector.layouts)
        var separated = FuzzReplay(corrector: corrector)
        XCTAssertEqual(separated.process(FuzzInput(prefix: p, words: w, mistaken: [0, 1])), "s  ще одне")
    }

    func testShortWordContextAndNonSpaceBoundary() throws {
        let corrector = try corrector()
        var pipeline = WordPipeline()
        let hello = try strokes("руддщ", on: .uk, using: corrector)
        let doWord = try strokes("вщ", on: .uk, using: corrector)
        guard case .correction = pipeline.end(hello, boundary: 49, lang: .uk, automatic: true, corrector: corrector) else {
            return XCTFail("Expected a long-word correction")
        }
        // Repeated Space retains the after-fix context, just as Engine does.
        _ = pipeline.end([], boundary: 49, lang: .uk, automatic: true, corrector: corrector)
        guard case let .correction(c) = pipeline.end(doWord, boundary: 49, lang: .uk, automatic: true, corrector: corrector) else {
            return XCTFail("Expected short-word correction after a fix")
        }
        XCTAssertEqual(c.converted, "do")
        _ = pipeline.end([], boundary: 36, lang: .uk, automatic: true, corrector: corrector)
        guard case .unchanged = pipeline.end(doWord, boundary: 49, lang: .uk, automatic: true, corrector: corrector) else {
            return XCTFail("Return must clear short-word context")
        }
    }

    func testManualModeDoesNotCorrectAndRunIsBounded() throws {
        let corrector = try corrector()
        var pipeline = WordPipeline()
        for _ in 0..<5 {
            guard case .unchanged = pipeline.end(try strokes("ghbdsn", on: .en, using: corrector),
                                                 boundary: 49, lang: .en, automatic: false, corrector: corrector) else {
                return XCTFail("Manual mode must preserve typed text")
            }
        }
        XCTAssertEqual(pipeline.run.count, 3)
        XCTAssertFalse(pipeline.afterFix)
        _ = pipeline.end([], boundary: 49, lang: .en, automatic: false, corrector: corrector)
        XCTAssertTrue(pipeline.run.isEmpty)
    }

    func testSeedAndSeparatorsAreReproducible() throws {
        var rng = SplitMix64(seed: 0)
        XCTAssertEqual(rng.next(), 0xE220A8397B1DCDAF)
        let corrector = try corrector()
        let text = "  Привіт,  hello!\t42 🙂\nодне"
        let (prefix, words) = FuzzGenerator.words(text, layouts: corrector.layouts)
        var a = SplitMix64(seed: 91), b = SplitMix64(seed: 91)
        for _ in 0..<10 {
            for mode in FuzzMode.allCases {
                let first = FuzzGenerator.input(prefix: prefix, words: words, mode: mode, rng: &a)
                let second = FuzzGenerator.input(prefix: prefix, words: words, mode: mode, rng: &b)
                XCTAssertEqual(first.typed, second.typed)
                XCTAssertEqual(first.words.map(\.following), words.map(\.following))
                XCTAssertTrue(first.typed.contains("42 🙂\n"))
            }
        }
        var clean = FuzzReplay(corrector: corrector)
        XCTAssertEqual(clean.process(FuzzInput(prefix: prefix, words: words, mistaken: [])), text)
    }


    func testSingleLetterAnchorRepairsOnlyEligiblePredecessors() throws {
        struct Words: Speller {
            func isCorrect(_ word: String, in lang: Lang) -> Bool {
                lang == .uk && ["на", "ми", "я", "і", "у"].contains(word.lowercased())
            }
        }
        let c = Corrector(layouts: try corrector().layouts, speller: Words())
        for text in ["на я", "ми я"] {
            let (prefix, words) = FuzzGenerator.words(text, layouts: c.layouts)
            var replay = FuzzReplay(corrector: c)
            XCTAssertEqual(replay.process(FuzzInput(prefix: prefix, words: words, mistaken: [0])), text)
        }
        for text in ["a я", "I я", "s я", "s, а", "30 s, а", "yf  я", "yf\tя", "yf\nя", "yf"] {
            let (prefix, words) = FuzzGenerator.words(text, layouts: c.layouts)
            var replay = FuzzReplay(corrector: c)
            XCTAssertEqual(replay.process(FuzzInput(prefix: prefix, words: words, mistaken: [])), text)
        }
        var ignored = c
        ignored.ignored = ["yf"]
        let (prefix, words) = FuzzGenerator.words("yf я", layouts: c.layouts)
        var replay = FuzzReplay(corrector: ignored)
        XCTAssertEqual(replay.process(FuzzInput(prefix: prefix, words: words, mistaken: [])), "yf я")
    }

    func testSingleLetterAfterFixUsesExistingShortWordSafetyRules() throws {
        let c = try corrector()
        for (typed, expected) in [("s", "і"), ("e", "у")] {
            var pipeline = WordPipeline(afterFix: true)
            guard case let .correction(fix) = pipeline.end(try strokes(typed, on: .en, using: c),
                    boundary: 49, lang: .en, automatic: true, corrector: c) else {
                XCTFail("Expected contextual single-letter correction for \(typed)"); continue
            }
            XCTAssertEqual(fix.converted, expected)
            XCTAssertEqual(fix.typed, typed)
            XCTAssertTrue(pipeline.afterFix)
        }
        for (typed, context, automatic) in [("s", false, true), ("a", true, true),
                                            ("I", true, true), (";", true, true), ("s", true, false)] {
            var pipeline = WordPipeline(afterFix: context)
            guard case .unchanged = pipeline.end(try strokes(typed, on: .en, using: c),
                    boundary: 49, lang: .en, automatic: automatic, corrector: c) else {
                XCTFail("Must preserve \(typed)"); continue
            }
        }
        var ignored = c
        ignored.ignored = ["s"]
        var pipeline = WordPipeline(afterFix: true)
        guard case .unchanged = pipeline.end(try strokes("s", on: .en, using: c), boundary: 49,
                lang: .en, automatic: true, corrector: ignored) else {
            return XCTFail("Ignored single letters must remain unchanged")
        }
    }

    func testSystemDictionaryProtectedShortWordsStayUnchangedWithAnchor() throws {
        let c = try systemCorrector()
        for text in ["wt я", "Vb я", "pf я", "Yt я", "a я", "I я",
                     "Таймаут встановлено на 30 s, а потрібно 60 s."] {
            let (prefix, words) = FuzzGenerator.words(text, layouts: c.layouts)
            var replay = FuzzReplay(corrector: c)
            XCTAssertEqual(replay.process(FuzzInput(prefix: prefix, words: words, mistaken: [])), text)
        }
        let (prefix, words) = FuzzGenerator.words("на я", layouts: c.layouts)
        var replay = FuzzReplay(corrector: c)
        XCTAssertEqual(replay.process(FuzzInput(prefix: prefix, words: words, mistaken: [0])), "на я")
    }

}
