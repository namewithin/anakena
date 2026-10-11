import XCTest
@testable import Anakena

final class CorrectorTests: XCTestCase {
    static let layouts = LayoutSet(ids: [.en: "com.apple.keylayout.ABC", .uk: "com.apple.keylayout.Ukrainian-PC"])
    let corrector = Corrector(layouts: CorrectorTests.layouts, speller: SystemSpeller())

    private func strokes(_ text: String, on lang: Lang) throws -> [Stroke] {
        guard let table = Self.layouts.tables[lang] else { throw XCTSkip("\(lang.title) keyboard layout unavailable") }
        return try text.map { try XCTUnwrap(table.stroke(for: String($0)), "no key for \($0) on \(lang)") }
    }

    private func decide(_ text: String, on lang: Lang) throws -> Correction? {
        corrector.decide(try strokes(text, on: lang), current: lang)
    }

    private func requireDictionaries() throws {
        try requireSystemDictionary(.en, word: "hello", misspelled: "ghbdsn")
        try requireSystemDictionary(.uk, word: "привіт", misspelled: "руддщ")
    }

    private func retro(_ words: [(String, Lang)], before word: String, on lang: Lang,
                       using candidate: Corrector? = nil) throws -> String {
        let corrector = candidate ?? self.corrector
        let run = try words.map { (strokes: try strokes($0.0, on: $0.1), lang: $0.1) }
        guard corrector.isWord(try strokes(word, on: lang), in: lang) else {
            return (words.map { $0.0 } + [word]).joined(separator: " ")
        }
        let fixed = corrector.fixShortWords(run, before: lang).map(\.converted)
        return (words.dropLast(fixed.count).map { $0.0 } + fixed + [word]).joined(separator: " ")
    }

    func testLayoutsLoaded() {
        XCTAssertTrue(Self.layouts.isComplete)
    }

    func testEnglishKeysMeantUkrainian() throws {
        try requireDictionaries()
        let c = try XCTUnwrap(try decide("ghbdsn", on: .en))
        XCTAssertEqual(c.typed, "ghbdsn")
        XCTAssertEqual(c.converted, "привіт")
        XCTAssertEqual(c.word, "ghbdsn")
        XCTAssertEqual(c.target, .uk)
        XCTAssertEqual(c.deleteCount, 6)
    }

    func testUkrainianKeysMeantEnglish() throws {
        try requireDictionaries()
        let c = try XCTUnwrap(try decide("руддщ", on: .uk))
        XCTAssertEqual(c.converted, "hello")
        XCTAssertEqual(c.target, .en)
    }

    func testCapitalIsKept() throws {
        try requireDictionaries()
        let c = try XCTUnwrap(try decide("Ghbdsn", on: .en))
        XCTAssertEqual(c.converted, "Привіт")
    }

    func testTrailingPunctuationUsesTargetTable() throws {
        try requireDictionaries()
        let c = try XCTUnwrap(try decide("Ghbdsn?", on: .en))
        XCTAssertEqual(c.typed, "Ghbdsn?")
        XCTAssertEqual(c.converted, "Привіт,")
        XCTAssertEqual(c.word, "Ghbdsn")
        XCTAssertEqual(c.deleteCount, 7)
    }

    func testWordWithLetterOnPunctuationKey() throws {
        try requireDictionaries()
        // "дякую" on EN keys is "lzre." - the "ю" key is "." there.
        let c = try XCTUnwrap(try decide("lzre.", on: .en))
        XCTAssertEqual(c.converted, "дякую")
    }

    func testPunctuationLetterInterpretationAndHyphenatedWord() throws {
        struct CollisionSpeller: Speller {
            func isCorrect(_ word: String, in lang: Lang) -> Bool {
                let words: Set<String> = lang == .en ? ["elm", "hello"]
                    : ["будь", "обід", "обіду", "олею", "дякую", "будь-який", "привіт", "хто", "жити", "єнот", "їжак", "ґанок"]
                return words.contains(word.lowercased())
            }
        }
        let candidate = Corrector(layouts: Self.layouts, speller: CollisionSpeller())
        for (typed, expected) in [(",elm", "будь"), ("j,sl", "обід"), ("j,sle", "обіду"),
                                  ("Lzre.", "Дякую"), ("lzre.", "дякую"), (",elm-zrbq", "будь-який"),
                                  ("[nj", "хто"), (";bnb", "жити"), ("'yjn", "єнот"),
                                  ("];fr", "їжак"), ("`fyjr", "ґанок")] {
            let c = try XCTUnwrap(candidate.decide(try strokes(typed, on: .en), current: .en), typed)
            XCTAssertEqual(c.converted, expected, typed)
            XCTAssertEqual(c.typed, typed)
            XCTAssertEqual(c.deleteCount, typed.count)
        }
        for typed in ["будь", "Будь", "будь,", "Привіт.", "(Будь!)", "будь-який"] {
            for afterFix in [false, true] {
                XCTAssertNil(candidate.decide(try strokes(typed, on: .uk), current: .uk, afterFix: afterFix), typed)
            }
        }
        var ignored = candidate
        ignored.ignored = [",elm"]
        XCTAssertNil(ignored.decide(try strokes(",elm", on: .en), current: .en))
    }

    func testCapitalizedDictionaryRetriesLowercaseAndKeepsCase() throws {
        struct LowercaseSpeller: Speller {
            func isCorrect(_ word: String, in lang: Lang) -> Bool {
                word == (lang == .uk ? "тікет" : "hello")
            }
        }
        let candidate = Corrector(layouts: Self.layouts, speller: LowercaseSpeller())
        let c = try XCTUnwrap(candidate.decide(try strokes("Nsrtn", on: .en), current: .en))
        XCTAssertEqual(c.converted, "Тікет")
        XCTAssertNil(candidate.decide(try strokes("Тікет", on: .uk), current: .uk))
        XCTAssertNil(candidate.decide(try strokes("Hello", on: .en), current: .en))
        XCTAssertNil(candidate.decide(try strokes("NSRTN", on: .en), current: .en), "Only retry title case")
    }

    func testSystemDictionaryPunctuationAndCapitalizedRegressions() throws {
        try requireDictionaries()
        for (typed, expected) in [(",elm", "будь"), ("j,sl", "обід"), ("j,sle", "обіду"),
                                  ("Lzre.", "Дякую"), ("lzre.", "дякую"),
                                  (",elm-zrbq", "будь-який"), ("Nsrfnb", "Тікати")] {
            XCTAssertEqual(try decide(typed, on: .en)?.converted, expected, typed)
        }
    }

    func testUkrainianSpecificLettersRoundTrip() throws {
        let table = try XCTUnwrap(Self.layouts.tables[.uk])
        for ch in ["і", "ї", "є", "ґ", "І", "Ї", "Є", "Ґ"] {
            let s = try XCTUnwrap(table.stroke(for: ch), "no key for \(ch)")
            XCTAssertEqual(table.char(for: s), ch)
        }
    }

    func testRealWordsAreLeftAlone() throws {
        try requireDictionaries()
        XCTAssertNil(try decide("hello", on: .en))
        XCTAssertNil(try decide("world", on: .en))
        XCTAssertNil(try decide("привіт", on: .uk))
        XCTAssertNil(try decide("дякую", on: .uk))
    }

    func testShortWordIsLeftAlone() throws {
        XCTAssertNil(try decide("yt", on: .en)) // "не"
    }

    func testShortWordsBeforeRealWord() throws {
        try requireDictionaries()
        XCTAssertEqual(try retro([("s", .en), ("ot", .en)], before: "одне", on: .uk), "і ще одне")
    }

    func testShortWordsBeforeRealWordOtherOrder() throws {
        try requireDictionaries()
        XCTAssertEqual(try retro([("ot", .en), ("s", .en)], before: "одне", on: .uk), "ще і одне")
    }

    func testShortWordsBeforeEnglishWord() throws {
        try requireDictionaries()
        XCTAssertEqual(try retro([("Ш", .uk), ("фь", .uk)], before: "here", on: .en), "I am here")
        XCTAssertEqual(try retro([("шт", .uk)], before: "here", on: .en), "in here")
    }

    func testRealShortWordsStay() throws {
        try requireDictionaries()
        XCTAssertEqual(try retro([("a", .en)], before: "одне", on: .uk), "a одне")
        XCTAssertEqual(try retro([("і", .uk)], before: "here", on: .en), "і here")
        XCTAssertEqual(try retro([("in", .en)], before: "одне", on: .uk), "in одне")
        XCTAssertEqual(try retro([("s", .en), ("a", .en)], before: "одне", on: .uk), "s a одне")
    }

    func testLongWordBeforeIsNotRetroFixed() throws {
        try requireDictionaries()
        XCTAssertEqual(try retro([("ghbdsn", .en), ("s", .en)], before: "одне", on: .uk), "ghbdsn і одне")
    }

    func testRetroNeedsRealWord() throws {
        try requireDictionaries()
        XCTAssertFalse(corrector.isWord(try strokes("щвфк", on: .uk), in: .uk))
        XCTAssertEqual(try retro([("s", .en), ("ot", .en)], before: "щвфк", on: .uk), "s ot щвфк")
        XCTAssertTrue(corrector.fixShortWords([], before: .uk).isEmpty)
        XCTAssertEqual(try retro([], before: "одне", on: .uk), "одне")
    }

    func testRetroRespectsIgnoreList() throws {
        try requireDictionaries()
        var corrector = self.corrector
        corrector.ignored = ["ot"]
        XCTAssertEqual(try retro([("s", .en), ("ot", .en)], before: "одне", on: .uk, using: corrector), "s ot одне")
    }

    func testPhraseWordByWord() throws {
        try requireDictionaries()
        let words = ["агслштп", "вщ", "ше", "фдкуфвн!"]
        var afterFix = false
        var output: [String] = []
        for w in words {
            let c = corrector.decide(try strokes(w, on: .uk), current: .uk, afterFix: afterFix)
            output.append(c.map { $0.converted } ?? w)
            afterFix = c != nil
        }
        XCTAssertEqual(output.joined(separator: " "), "fucking do it already!")
    }

    func testIgnoredWordIsSkipped() throws {
        var corrector = self.corrector
        corrector.ignored = ["ghbdsn"]
        XCTAssertNil(corrector.decide(try strokes("ghbdsn", on: .en), current: .en))
        XCTAssertNil(corrector.decide(try strokes("Ghbdsn", on: .en), current: .en))
    }

    func testAlwaysWordIsConverted() throws {
        var corrector = self.corrector
        corrector.always = ["yt"]
        let c = try XCTUnwrap(corrector.decide(try strokes("yt", on: .en), current: .en))
        XCTAssertEqual(c.converted, "не")
        XCTAssertEqual(c.target, .uk)
        corrector.ignored = ["yt"]
        XCTAssertNil(corrector.decide(try strokes("yt", on: .en), current: .en))
    }

    func testLearnLatestWins() {
        var corrector = self.corrector
        corrector.learn("Ghbdsn", always: true)
        XCTAssertTrue(corrector.always.contains("ghbdsn"))
        XCTAssertFalse(corrector.ignored.contains("ghbdsn"))
        corrector.learn("ghbdsn", always: false)
        XCTAssertFalse(corrector.always.contains("ghbdsn"))
        XCTAssertTrue(corrector.ignored.contains("ghbdsn"))

        corrector.always = Set((0..<Corrector.maxLearned).map { "word\($0)" })
        corrector.learn("newword", always: true)
        XCTAssertFalse(corrector.always.contains("newword"))
        XCTAssertEqual(corrector.always.count, Corrector.maxLearned)
    }

    func testShortWordAfterFixIsConverted() throws {
        try requireDictionaries()
        let doWord = try XCTUnwrap(corrector.decide(try strokes("вщ", on: .uk), current: .uk, afterFix: true))
        XCTAssertEqual(doWord.converted, "do")
        let itWord = try XCTUnwrap(corrector.decide(try strokes("ше", on: .uk), current: .uk, afterFix: true))
        XCTAssertEqual(itWord.converted, "it")
    }

    func testShortWordWithoutFixIsLeftAlone() throws {
        XCTAssertNil(corrector.decide(try strokes("вщ", on: .uk), current: .uk))
        XCTAssertNil(corrector.decide(try strokes("ше", on: .uk), current: .uk, afterFix: false))
    }

    func testOneLetterIsLeftAlone() throws {
        var corrector = self.corrector
        XCTAssertNil(corrector.decide(try strokes("ф", on: .uk), current: .uk, afterFix: true))
        corrector.always = ["ф"]
        XCTAssertNil(corrector.decide(try strokes("ф", on: .uk), current: .uk, afterFix: true))
    }

    func testLearnableWord() throws {
        XCTAssertEqual(corrector.learnableWord(try strokes("lzre.", on: .en), current: .en), "lzre.")
        XCTAssertEqual(corrector.learnableWord(try strokes("фдкуфвн!", on: .uk), current: .uk), "фдкуфвн")
        XCTAssertNil(corrector.learnableWord(try strokes("a/b", on: .en), current: .en))
        XCTAssertNil(corrector.learnableWord(try strokes("z", on: .en), current: .en))
    }

    func testWordWithDigitIsLeftAlone() throws {
        XCTAssertNil(try decide("ghb2dsn", on: .en))
    }

    func testLooksLikeCode() {
        XCTAssertTrue(Corrector.looksLikeCode("camelCase"))
        XCTAssertTrue(Corrector.looksLikeCode("a/b"))
        XCTAssertTrue(Corrector.looksLikeCode("NASA"))
        XCTAssertFalse(Corrector.looksLikeCode("ghbdsn"))
    }

    func testConvertText() {
        XCTAssertEqual(corrector.convertText("ghbdsn"), "привіт")
        XCTAssertEqual(corrector.convertText("привіт"), "ghbdsn")
    }
}
