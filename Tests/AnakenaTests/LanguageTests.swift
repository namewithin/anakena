import AppKit
import Carbon
import XCTest
@testable import Anakena

/// Keep preference tests entirely in memory, away from the user's app preferences.
private final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]

    override func string(forKey key: String) -> String? { values[key] as? String }
    override func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    override func dictionaryRepresentation() -> [String: Any] { values }
}

func requireSystemDictionary(_ lang: Lang, word: String, misspelled: String) throws {
    let speller = SystemSpeller()
    guard speller.supports(lang) else {
        throw XCTSkip("\(lang.title) spell-check dictionary unavailable")
    }
    // availableLanguages can list dictionaries even when sandboxing blocks the spell server.
    guard speller.isCorrect(word, in: lang), !speller.isCorrect(misspelled, in: lang) else {
        throw XCTSkip("\(lang.title) NSSpellChecker service unavailable: failed known-word/misspelling probe (sandbox may block XPC)")
    }
}

final class LanguageTests: XCTestCase {
    private let pl = Lang(rawValue: "pl")
    private let de = Lang(rawValue: "de")

    func testPrimaryCodesAndTitles() throws {
        for code in ["en-US", "EN_us", "en"] { XCTAssertEqual(Lang(rawValue: code), .en) }
        for code in ["uk-UA", "UK_ua", "uk"] { XCTAssertEqual(Lang(rawValue: code), .uk) }
        for code in ["pl", "de", "ru", "es", "fr"] {
            let lang = Lang(rawValue: code)
            XCTAssertEqual(lang.rawValue, code)
            XCTAssertEqual(lang.title, code.uppercased())
            XCTAssertEqual(try JSONDecoder().decode(Lang.self, from: JSONEncoder().encode(lang)), lang)
        }
        XCTAssertEqual(Lang.en.title, "EN")
        XCTAssertEqual(Lang.uk.title, "УК")
        XCTAssertEqual(Set([Lang(rawValue: "pl-PL"), pl]).count, 1)
    }

    func testDictionaryMatchingUsesPrimaryCode() {
        XCTAssertEqual(SystemSpeller.dictionary(for: .en, available: ["en_US", "en"]), "en")
        XCTAssertEqual(SystemSpeller.dictionary(for: .en, available: ["fr", "en-GB"]), "en-GB")
        XCTAssertEqual(SystemSpeller.dictionary(for: pl, available: ["pl_PL"]), "pl_PL")
        XCTAssertNil(SystemSpeller.dictionary(for: de, available: ["en", "pl"]))
    }

    func testAutoPickPrefersEnglishAndUkrainian() {
        XCTAssertEqual(LangPair.pick(enabled: [pl, .uk, de, .en]), LangPair(a: .en, b: .uk))
    }

    func testAutoPickPrefersEnglishThenFirstDistinctLanguage() {
        XCTAssertEqual(LangPair.pick(enabled: [pl, pl, de, .en]), LangPair(a: .en, b: pl))
        XCTAssertEqual(LangPair.pick(enabled: [de, de, pl]), LangPair(a: de, b: pl))
    }

    func testStoredPairAndUnavailableLanguage() {
        let pair = LangPair(a: pl, b: .uk)
        XCTAssertEqual(LangPair.pick(enabled: [.en, .uk, pl], stored: pair), pair)
        XCTAssertEqual(LangPair.pick(enabled: [.en, de], stored: pair), LangPair(a: .en, b: de))
        XCTAssertEqual(LangPair.pick(enabled: [pl, de], stored: LangPair(a: pl, b: pl)),
                       LangPair(a: pl, b: de))
        XCTAssertEqual(pair.other(.uk), pl)
        XCTAssertNil(pair.other(.en))
    }

    func testFewerThanTwoDistinctLanguages() {
        XCTAssertNil(LangPair.pick(enabled: []))
        XCTAssertNil(LangPair.pick(enabled: [pl, pl]))
        XCTAssertNil(LangPair.pick(enabled: [.en], stored: LangPair(a: .en, b: .uk)))
    }

    func testAutoPickPrefersPairsWithDictionaries() {
        let be = Lang(rawValue: "be")
        XCTAssertEqual(LangPair.pick(enabled: [.en, be, pl], dictionaries: [.en, pl]),
                       LangPair(a: .en, b: pl))
        XCTAssertEqual(LangPair.pick(enabled: [be, de, pl], dictionaries: [de, pl]),
                       LangPair(a: de, b: pl))
        XCTAssertEqual(LangPair.pick(enabled: [pl, .uk, .en], dictionaries: [.en, .uk, pl]),
                       LangPair(a: .en, b: .uk))
        // Fewer than two supported languages preserves the old fallback.
        for dictionaries: Set<Lang> in [[], [.en]] {
            XCTAssertEqual(LangPair.pick(enabled: [.en, be, pl], dictionaries: dictionaries),
                           LangPair(a: .en, b: be))
            XCTAssertEqual(LangPair.pick(enabled: [pl, .uk, .en], dictionaries: dictionaries),
                           LangPair(a: .en, b: .uk))
        }
        let stored = LangPair(a: .uk, b: pl)
        XCTAssertEqual(LangPair.pick(enabled: [.en, .uk, pl], stored: stored, dictionaries: [.en, pl]), stored)
        XCTAssertNil(LangPair.pick(enabled: [.en], dictionaries: [.en, pl]))
    }

    func testLearningIsScopedToUnorderedPairAndKeepsLegacyEnglishUkrainian() {
        let defaults = MemoryDefaults()
        defaults.set(["ghbdsn"], forKey: "alwaysWords")
        defaults.set(["hello"], forKey: "ignoredWords")
        let settings = Settings(defaults: defaults)
        let enUK = LangPair(a: .en, b: .uk)
        let ukEN = LangPair(a: .uk, b: .en)
        let ukPL = LangPair(a: .uk, b: pl)
        XCTAssertEqual(settings.alwaysWords(for: enUK), ["ghbdsn"])
        XCTAssertEqual(settings.ignoredWords(for: ukEN), ["hello"])
        XCTAssertEqual(settings.alwaysWords(for: ukPL), [])
        XCTAssertEqual(settings.ignoredWords(for: ukPL), [])
        settings.setAlwaysWords(["цшефо"], for: ukPL)
        settings.setIgnoredWords(["ещ"], for: LangPair(a: pl, b: .uk))
        XCTAssertEqual(settings.alwaysWords(for: LangPair(a: pl, b: .uk)), ["цшефо"])
        XCTAssertEqual(settings.ignoredWords(for: ukPL), ["ещ"])
        XCTAssertEqual(settings.alwaysWords(for: enUK), ["ghbdsn"])
        settings.setAlwaysWords([], for: ukEN)
        settings.setIgnoredWords([], for: enUK)
        XCTAssertEqual(settings.alwaysWords(for: enUK), [])
        XCTAssertEqual(settings.ignoredWords(for: ukEN), [])
        XCTAssertEqual(settings.alwaysWords(for: ukPL), ["цшефо"])
        XCTAssertEqual(settings.ignoredWords(for: ukPL), ["ещ"])
    }

    func testUnicodeCodeHeuristics() {
        for word in ["zaŻółć", "äÖ", "a/b", "snake_case", "NASA", "ŁÓDŹ"] {
            XCTAssertTrue(Corrector.looksLikeCode(word), word)
        }
        for word in ["zażółć", "grüße", "привіт", "你好"] {
            XCTAssertFalse(Corrector.looksLikeCode(word), word)
        }
    }
}

final class MultiLanguageTests: XCTestCase {
    private let pl = Lang(rawValue: "pl")
    private let de = Lang(rawValue: "de")

    private struct WordSpeller: Speller {
        let words: [Lang: Set<String>]
        func isCorrect(_ word: String, in lang: Lang) -> Bool {
            words[lang, default: []].contains(word.lowercased())
        }
    }

    private func layouts(_ ids: [Lang: String]) throws -> LayoutSet {
        let layouts = LayoutSet(ids: ids)
        guard ids.keys.allSatisfy({ layouts.tables[$0] != nil }) else {
            throw XCTSkip("Required keyboard layout not installed: \(ids.values.sorted().joined(separator: ", "))")
        }
        return layouts
    }

    private func strokes(_ text: String, table: LayoutTable) throws -> [Stroke] {
        try text.map { try XCTUnwrap(table.stroke(for: String($0)), "no key for \($0)") }
    }

    func testPolishAndGermanDiacriticsUseOwnTables() throws {
        let layouts = try layouts([pl: "com.apple.keylayout.Polish", de: "com.apple.keylayout.German"])
        for (lang, letters) in [(pl, "łąćęńóśźżŁĄ"), (de, "äöüßÄÖÜ")] {
            let table = try XCTUnwrap(layouts.tables[lang])
            XCTAssertEqual(TIS.lang(try XCTUnwrap(layouts.sources[lang])), lang)
            for letter in letters {
                let key = try XCTUnwrap(table.stroke(for: String(letter)), "no key for \(letter)")
                XCTAssertEqual(table.char(for: key), String(letter))
            }
        }
    }

    func testPolishProOptionLetterRemainsInReverseMap() throws {
        let layouts = try layouts([.en: "com.apple.keylayout.ABC", pl: "com.apple.keylayout.PolishPro"])
        let table = try XCTUnwrap(layouts.tables[pl])
        let stroke = Stroke(keyCode: 37, shift: false, caps: false, option: true)
        XCTAssertEqual(table.char(for: stroke), "ł")
        XCTAssertEqual(table.stroke(for: "ł"), stroke)
        let english = try XCTUnwrap(layouts.tables[.en]?.char(for: stroke))
        let corrector = Corrector(layouts: layouts, speller: WordSpeller(words: [:]))
        XCTAssertEqual(corrector.convertText("ł", from: pl), english)
    }

    func testEnglishUkrainianSelectionKeepsQuotesDashesAndUnmappedLetters() throws {
        let layouts = try layouts([.en: "com.apple.keylayout.ABC", .uk: "com.apple.keylayout.Ukrainian-PC"])
        let corrector = Corrector(layouts: layouts, speller: WordSpeller(words: [:]))
        XCTAssertEqual(corrector.convertText("«руддщ»"), "«hello»")
        XCTAssertEqual(corrector.convertText("it’s “ghbdsn”"), "ше’і “привіт”")
        XCTAssertEqual(corrector.convertText("мы это"), "vы эnj")
        XCTAssertEqual(corrector.convertText("ghbdsn — hello – world"), "привіт — руддщ – цщкдв")
    }

    // The pre-multilanguage table used NoDeadKeysMask; compare against that algorithm,
    // while separately asking Carbon which keys really begin a dead-key sequence.
    private func translation(_ source: TISInputSource, stroke: Stroke, noDeadKeys: Bool) throws
        -> (char: String?, dead: UInt32) {
        let data: Data = try XCTUnwrap(TIS.property(source, kTISPropertyUnicodeKeyLayoutData))
        return data.withUnsafeBytes { raw in
            let layout = raw.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self)
            let mods = UInt32((stroke.shift ? shiftKey : 0) | (stroke.caps ? alphaLock : 0)
                              | (stroke.option ? optionKey : 0)) >> 8
            var dead: UInt32 = 0
            var length = 0
            var buf = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, stroke.keyCode, UInt16(kUCKeyActionDown), mods,
                                        UInt32(LMGetKbdType()), noDeadKeys ? OptionBits(kUCKeyTranslateNoDeadKeysMask) : 0,
                                        &dead, buf.count, &length, &buf)
            guard status == noErr, length > 0 else { return (nil, dead) }
            let char = String(utf16CodeUnits: buf, count: length)
            guard !char.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
                return (nil, dead)
            }
            return (char, dead)
        }
    }

    func testEnglishUkrainianPlainKeysMatchPreviousReleaseExceptDeadKeys() throws {
        let layouts = try layouts([.en: "com.apple.keylayout.ABC", .uk: "com.apple.keylayout.Ukrainian-PC"])
        for lang in [Lang.en, .uk] {
            let source = try XCTUnwrap(layouts.sources[lang])
            let table = try XCTUnwrap(layouts.tables[lang])
            for caps in [false, true] {
                for shift in [false, true] {
                    for code in UInt16(0)...50 {
                        let stroke = Stroke(keyCode: code, shift: shift, caps: caps)
                        let current = try translation(source, stroke: stroke, noDeadKeys: false)
                        let old = try translation(source, stroke: stroke, noDeadKeys: true)
                        let expected = current.dead != 0 || LayoutTable.boundaryKeys.contains(code) ? nil : old.char
                        XCTAssertEqual(table.char(for: stroke), expected, "\(lang) \(stroke)")
                    }
                }
            }
        }
    }

    func testABCOptionDeadKeysHaveNoTableCharacter() throws {
        let layouts = try layouts([.en: "com.apple.keylayout.ABC", .uk: "com.apple.keylayout.Ukrainian-PC"])
        let table = try XCTUnwrap(layouts.tables[.en])
        let source = try XCTUnwrap(layouts.sources[.en])
        // Option+e/u/i/n/` must reset Engine's buffer rather than add a stroke.
        for code: UInt16 in [14, 32, 34, 45, 50] {
            let stroke = Stroke(keyCode: code, shift: false, caps: false, option: true)
            XCTAssertNotEqual(try translation(source, stroke: stroke, noDeadKeys: false).dead, 0)
            XCTAssertNil(table.char(for: stroke))
        }
        let corrector = Corrector(layouts: layouts, speller: WordSpeller(words: [.uk: ["тфшму"]]))
        let naive = [Stroke(keyCode: 45, shift: false, caps: false),
                     Stroke(keyCode: 0, shift: false, caps: false),
                     Stroke(keyCode: 32, shift: false, caps: false, option: true),
                     Stroke(keyCode: 34, shift: false, caps: false),
                     Stroke(keyCode: 9, shift: false, caps: false),
                     Stroke(keyCode: 14, shift: false, caps: false)]
        XCTAssertNil(corrector.decide(naive, current: .en))
    }

    func testGermanPlainDeadKeysHaveNoTableCharacter() throws {
        let layouts = try layouts([.en: "com.apple.keylayout.ABC", de: "com.apple.keylayout.German"])
        let table = try XCTUnwrap(layouts.tables[de])
        let source = try XCTUnwrap(layouts.sources[de])
        for code: UInt16 in [10, 24] {
            let stroke = Stroke(keyCode: code, shift: false, caps: false)
            XCTAssertNotEqual(try translation(source, stroke: stroke, noDeadKeys: false).dead, 0)
            XCTAssertNil(table.char(for: stroke))
        }
    }

    func testLearnedSharedAlphabetWordDoesNotFlipLayouts() throws {
        let layouts = try layouts([.en: "com.apple.keylayout.ABC", de: "com.apple.keylayout.German"])
        let speller = WordSpeller(words: [de: ["nicht", "in"]])
        var corrector = Corrector(layouts: layouts, speller: speller)
        corrector.learn("nicht", always: true)
        corrector.learn("in", always: true)
        for lang in [Lang.en, de] {
            let table = try XCTUnwrap(layouts.tables[lang])
            for text in ["nicht", "Nicht", "NICHT", "nicht,"] {
                XCTAssertNil(corrector.decide(try strokes(text, table: table), current: lang), text)
            }
            XCTAssertTrue(corrector.fixShortWords([(try strokes("in", table: table), lang)],
                                                 before: try XCTUnwrap(layouts.other(lang))).isEmpty)
        }
    }

    func testReloadKeepsUnavailableSavedPairAndDoesNotPersistAutomaticChoice() throws {
        let saved = LangPair(a: .uk, b: pl)
        let full = try layouts([.en: "com.apple.keylayout.ABC", .uk: "com.apple.keylayout.Ukrainian-PC",
                                pl: "com.apple.keylayout.Polish"])
        let fallback = try layouts([.en: "com.apple.keylayout.ABC", .uk: "com.apple.keylayout.Ukrainian-PC"])
        let single = try layouts([.en: "com.apple.keylayout.ABC"])
        let settings = Settings(defaults: MemoryDefaults())
        let speller = WordSpeller(words: [:])
        settings.languagePair = saved
        let engine = Engine(settings: settings, layouts: fallback, speller: speller)
        XCTAssertEqual(fallback.pair, LangPair(a: .en, b: .uk))
        XCTAssertEqual(settings.languagePair, saved)
        engine.reloadLanguages()
        XCTAssertEqual(settings.languagePair, saved)
        _ = Engine(settings: settings, layouts: single, speller: speller)
        XCTAssertNil(single.pair)
        XCTAssertEqual(settings.languagePair, saved)
        _ = Engine(settings: settings, layouts: full, speller: speller)
        XCTAssertEqual(full.pair, saved)
        XCTAssertEqual(settings.languagePair, saved)
        settings.languagePair = nil
        engine.reloadLanguages()
        XCTAssertEqual(fallback.pair, LangPair(a: .en, b: .uk))
        XCTAssertNil(settings.languagePair)
    }

    func testReloadAndResetLearningClearsEveryPairAndLegacyKeys() throws {
        let layouts = try layouts([.en: "com.apple.keylayout.ABC", .uk: "com.apple.keylayout.Ukrainian-PC",
                                   pl: "com.apple.keylayout.Polish"])
        let defaults = MemoryDefaults()
        defaults.set(["ghbdsn"], forKey: "alwaysWords")
        defaults.set(["hello", "world"], forKey: "ignoredWords")
        let settings = Settings(defaults: defaults)
        let enUK = LangPair(a: .en, b: .uk)
        let ukPL = LangPair(a: .uk, b: pl)
        settings.setAlwaysWords(["цшефо", "ещ"], for: ukPL)
        settings.setIgnoredWords(["одне"], for: ukPL)
        settings.languagePair = enUK
        let engine = Engine(settings: settings, layouts: layouts, speller: WordSpeller(words: [:]))
        XCTAssertEqual(engine.learnedCounts.always, 1)
        XCTAssertEqual(engine.learnedCounts.ignored, 2)
        settings.languagePair = ukPL
        engine.reloadLanguages()
        XCTAssertEqual(engine.learnedCounts.always, 2)
        XCTAssertEqual(engine.learnedCounts.ignored, 1)
        engine.resetLearning()
        XCTAssertEqual(engine.learnedCounts.always, 0)
        XCTAssertEqual(engine.learnedCounts.ignored, 0)
        XCTAssertEqual(settings.alwaysWords(for: ukPL), [])
        XCTAssertEqual(settings.ignoredWords(for: ukPL), [])
        XCTAssertEqual(settings.alwaysWords(for: enUK), [])
        XCTAssertEqual(settings.ignoredWords(for: enUK), [])
        settings.languagePair = enUK
        engine.reloadLanguages()
        XCTAssertEqual(engine.learnedCounts.always, 0)
        XCTAssertEqual(engine.learnedCounts.ignored, 0)
        engine.resetLearning()
        engine.reloadLanguages()
        XCTAssertEqual(engine.learnedCounts.always, 0)
        XCTAssertEqual(engine.learnedCounts.ignored, 0)
    }

    func testNonEnglishPairShortWordRulesAndLearning() throws {
        let layouts = try layouts([.uk: "com.apple.keylayout.Ukrainian-PC", pl: "com.apple.keylayout.Polish"])
        let uk = try XCTUnwrap(layouts.tables[.uk])
        var corrector = Corrector(layouts: layouts, speller: WordSpeller(words: [pl: ["to", "witaj"]]))
        let two = try strokes("ещ", table: uk)
        XCTAssertNil(corrector.decide(two, current: .uk))
        let c = try XCTUnwrap(corrector.decide(two, current: .uk, afterFix: true))
        XCTAssertEqual(c.converted, "to")
        XCTAssertEqual(c.target, pl)
        XCTAssertEqual(corrector.fixShortWords([(two, .uk)], before: pl).map(\.converted), ["to"])
        XCTAssertTrue(corrector.fixShortWords([(try strokes("щ", table: uk), .uk)], before: pl).isEmpty)
        XCTAssertNil(corrector.decide(try strokes("е2щ", table: uk), current: .uk, afterFix: true))
        corrector.learn("ЕЩ", always: true)
        XCTAssertEqual(corrector.decide(two, current: .uk)?.converted, "to")
        corrector.learn("ЕЩ", always: false)
        XCTAssertNil(corrector.decide(two, current: .uk, afterFix: true))
        XCTAssertEqual(corrector.ignored, ["ещ"])
    }

    func testMissingDictionaryPreventsAutomaticCorrection() throws {
        struct MissingSpeller: Speller {
            func supports(_ lang: Lang) -> Bool { lang != .uk }
            func isCorrect(_ word: String, in lang: Lang) -> Bool { lang != .uk }
        }
        let layouts = try layouts([.uk: "com.apple.keylayout.Ukrainian-PC", pl: "com.apple.keylayout.Polish"])
        var corrector = Corrector(layouts: layouts, speller: MissingSpeller())
        let uk = try XCTUnwrap(layouts.tables[.uk])
        XCTAssertNil(corrector.decide(try strokes("цшефо", table: uk), current: .uk))
        XCTAssertTrue(corrector.fixShortWords([(try strokes("ещ", table: uk), .uk)], before: pl).isEmpty)
        corrector.learn("ЦШЕФО", always: true)
        XCTAssertEqual(corrector.decide(try strokes("цшефо", table: uk), current: .uk)?.converted, "witaj")
    }

    func testGermanConversionWithDiacritics() throws {
        let layouts = try layouts([.en: "com.apple.keylayout.ABC", de: "com.apple.keylayout.German"])
        let german = try XCTUnwrap(layouts.tables[de])
        let english = try XCTUnwrap(layouts.tables[.en])
        let keys = try strokes("grüße", table: german)
        let typed = keys.compactMap { english.char(for: $0) }.joined()
        let corrector = Corrector(layouts: layouts, speller: WordSpeller(words: [de: ["grüße"]]))
        let c = try XCTUnwrap(corrector.decide(keys, current: .en))
        XCTAssertEqual(c.typed, typed)
        XCTAssertEqual(c.converted, "grüße")
        XCTAssertEqual(c.target, de)
        XCTAssertEqual(corrector.convertText(typed, from: .en), "grüße")
    }

    func testSelectionWithSharedAlphabetUsesCurrentLayout() throws {
        let layouts = try layouts([.en: "com.apple.keylayout.ABC", de: "com.apple.keylayout.German"])
        let corrector = Corrector(layouts: layouts, speller: WordSpeller(words: [:]))
        XCTAssertEqual(corrector.convertText("y", from: .en), "z")
        XCTAssertEqual(corrector.convertText("y", from: de), "z")
        XCTAssertEqual(corrector.convertText("-", from: .en), "ß")
        XCTAssertEqual(corrector.convertText("-", from: de), "/")
    }

    func testInactiveLanguageDoesNotConvert() throws {
        let layouts = try layouts([.en: "com.apple.keylayout.ABC", .uk: "com.apple.keylayout.Ukrainian-PC",
                                   pl: "com.apple.keylayout.Polish"])
        layouts.choosePair(stored: LangPair(a: .uk, b: pl))
        let corrector = Corrector(layouts: layouts, speller: WordSpeller(words: [pl: ["witaj"]]))
        XCTAssertTrue(layouts.isComplete)
        XCTAssertNil(corrector.decide(try strokes("witaj", table: XCTUnwrap(layouts.tables[.en])), current: .en))
        XCTAssertEqual(corrector.convertText("цшефо"), "witaj")
    }

    func testUkrainianToPolishWithSystemDictionary() throws {
        let layouts = try layouts([.uk: "com.apple.keylayout.Ukrainian-PC", pl: "com.apple.keylayout.Polish"])
        try requireSystemDictionary(.uk, word: "привіт", misspelled: "руддщ")
        try requireSystemDictionary(pl, word: "witaj", misspelled: "qzxqzxzz")
        let corrector = Corrector(layouts: layouts, speller: SystemSpeller())
        let c = try XCTUnwrap(corrector.decide(try strokes("цшефо", table: XCTUnwrap(layouts.tables[.uk])), current: .uk))
        XCTAssertEqual(c.converted, "witaj")
        XCTAssertEqual(c.target, pl)
    }
}
