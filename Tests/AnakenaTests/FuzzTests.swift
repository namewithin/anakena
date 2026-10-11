import XCTest
@testable import Anakena

final class FuzzTests: XCTestCase {
    func testRandomizedQuality() throws {
        let env = ProcessInfo.processInfo.environment
        let seedText = env["ANAKENA_FUZZ_SEED"] ?? "1"
        let passesText = env["ANAKENA_FUZZ_PASSES"] ?? "3"
        guard let seed = UInt64(seedText), let passes = Int(passesText), passes > 0 else {
            throw NSError(domain: "AnakenaFuzz", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "ANAKENA_FUZZ_SEED must be UInt64; ANAKENA_FUZZ_PASSES must be a positive Int",
            ])
        }
        guard let url = Bundle.module.url(forResource: "corpus", withExtension: "json", subdirectory: "Fixtures") else {
            throw NSError(domain: "AnakenaFuzz", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing corpus.json test resource"])
        }
        let corpus = try JSONDecoder().decode([FuzzSentence].self, from: Data(contentsOf: url))
        let layouts = LayoutSet(ids: [.en: "com.apple.keylayout.ABC", .uk: "com.apple.keylayout.Ukrainian-PC"])
        let header = "# Anakena fuzz quality\n\nSeed: \(seed); passes: \(passes); corpus: \(corpus.count) sentences.\n"
        func skip(_ reason: String) throws -> Never {
            try FuzzReports.write(failures: [], summary: header + "\nSKIPPED: \(reason)\nNo quality measurements were collected.\n")
            throw XCTSkip(reason)
        }
        guard layouts.tables[.en] != nil, layouts.tables[.uk] != nil else {
            try skip("EN/UK keyboard layouts unavailable")
        }
        let speller = SystemSpeller()
        for (lang, word, misspelled) in [(Lang.en, "hello", "ghbdsn"), (.uk, "привіт", "руддщ")] {
            guard speller.supports(lang) else { try skip("\(lang.title) spell-check dictionary unavailable") }
            guard speller.isCorrect(word, in: lang), !speller.isCorrect(misspelled, in: lang) else {
                try skip("\(lang.title) NSSpellChecker unavailable: known-word/misspelling probe failed (sandbox may block XPC)")
            }
        }

        let corrector = Corrector(layouts: layouts, speller: speller)
        var rng = SplitMix64(seed: seed)
        var stats: [String: [FuzzMode: FuzzStats]] = [:]
        var failures: [FuzzFailure] = []
        var ran = 0
        for sentence in corpus {
            let (prefix, words) = FuzzGenerator.words(sentence.text, layouts: layouts)
            for pass in 1...passes {
                for mode in FuzzMode.allCases {
                    let input = FuzzGenerator.input(prefix: prefix, words: words, mode: mode, rng: &rng)
                    var replay = FuzzReplay(corrector: corrector)
                    let got = replay.process(input)
                    var row = stats[sentence.category, default: [:]][mode, default: FuzzStats()]
                    if let reason = row.record(typed: input.typed, got: got, expected: sentence.text) {
                        failures.append(FuzzFailure(id: sentence.id, category: sentence.category,
                                                    mode: mode.rawValue, pass: pass, seed: seed,
                                                    typed: input.typed, got: got, expected: sentence.text,
                                                    reason: reason))
                    }
                    stats[sentence.category, default: [:]][mode] = row
                    ran += 1
                }
            }
        }

        var summary = header + """

        Replay: physical letter keys and user layout transitions through the shared Engine word pipeline.
        `typed` is the baseline without Anakena; automatic layout switches affect later keys in `got`.
        Words are whitespace-delimited; attached punctuation follows the same physical keys.
        Tokens containing digits or unmapped characters are not mutated; their own layout is
        explicitly selected before typing so automatic switches do not manufacture FP. Separators stay literal.
        The final word is flushed with a virtual Space. Learned lists are empty.
        Fix rate = correct output / baseline wrong words (includes errors prevented by layout switching).
        FP = baseline clean words changed, including CLEAN mode; missed = wrong words left unchanged;
        wrong = wrong words changed to another wrong output. n/a means a zero denominator.

        | Category | Mode | Exact sentences | Word fix rate | FP / clean words | Missed | Wrong |
        |---|---|---:|---:|---:|---:|---:|

        """
        for category in stats.keys.sorted() {
            for mode in FuzzMode.allCases {
                guard let row = stats[category]?[mode] else { continue }
                summary += "| \(category) | \(mode.rawValue) | \(row.exact)/\(row.sentences) (\(FuzzStats.rate(row.exact, row.sentences)))"
                    + " | \(row.fixed)/\(row.needsFix) (\(FuzzStats.rate(row.fixed, row.needsFix)))"
                    + " | \(row.falsePositives)/\(row.cleanWords) | \(row.missed) | \(row.wrong) |\n"
            }
        }
        summary += "\nRuns: \(ran); failed sentences: \(failures.count). Quality outside CLEAN guards is report-only.\n"
        print(summary)
        try FuzzReports.write(failures: failures, summary: summary)
        XCTAssertGreaterThan(ran, 0)
        for category in stats.keys.sorted() {
            let cleanFailures = failures.filter { $0.category == category && $0.mode == FuzzMode.clean.rawValue }
            XCTAssertTrue(cleanFailures.isEmpty, "CLEAN \(category): \(cleanFailures.count) changes; inspect fuzz report")
        }
    }
}
