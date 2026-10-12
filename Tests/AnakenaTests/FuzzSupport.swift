import Foundation
@testable import Anakena

struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    // Explicit bounded sampling keeps the sequence independent of Swift's random APIs.
    mutating func index(_ count: Int) -> Int {
        precondition(count > 0)
        let bound = UInt64(count)
        let threshold = (0 &- bound) % bound
        var value = next()
        while value < threshold { value = next() }
        return Int(value % bound)
    }
}

struct FuzzSentence: Decodable {
    let id: String
    let category: String
    let text: String
}

enum FuzzMode: String, CaseIterable {
    case clean = "CLEAN"
    case wrongAll = "WRONG_ALL"
    case wrongSome = "WRONG_SOME"
    case switchMid = "SWITCH_MID"
}

/// A word is a whitespace-delimited chunk, matching the Engine's Space boundary.
/// Eligible tokens are remapped through physical keys, including attached punctuation.
/// Tokens containing digits or characters unavailable in either table stay unchanged.
struct FuzzWord {
    let intended: String
    let following: String
    let own: Lang?
    let wrong: String
    let keys: [Stroke?]

    var canMistype: Bool { own != nil && wrong != intended }
}

struct FuzzInput {
    let prefix: String
    let words: [FuzzWord]
    let mistaken: Set<Int>

    var typed: String {
        prefix + words.enumerated().map { i, word in
            (mistaken.contains(i) ? word.wrong : word.intended) + word.following
        }.joined()
    }
}

enum FuzzGenerator {
    static func words(_ text: String, layouts: LayoutSet) -> (String, [FuzzWord]) {
        let chars = Array(text)
        var i = 0
        var prefix = ""
        while i < chars.count, chars[i].isWhitespace { prefix.append(chars[i]); i += 1 }
        var words: [FuzzWord] = []
        while i < chars.count {
            let start = i
            while i < chars.count, !chars[i].isWhitespace { i += 1 }
            let body = Array(chars[start..<i])
            let separator = i
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            let letters = body.filter(\.isLetter)
            let own = [Lang.en, .uk].first { lang in
                guard !letters.isEmpty, let src = layouts.tables[lang],
                      let other = layouts.other(lang), let dst = layouts.tables[other] else { return false }
                return letters.allSatisfy { ch in
                    guard let key = src.stroke(for: String(ch)) else { return false }
                    return dst.char(for: key) != nil
                }
            }
            let src = own.flatMap { layouts.tables[$0] }
            let dst = own.flatMap { layouts.other($0) }.flatMap { layouts.tables[$0] }
            let keys = body.map { src?.stroke(for: String($0)) }
            let converted = keys.map { key in key.flatMap { dst?.char(for: $0) } }
            let wrong = !body.contains(where: \.isNumber) && converted.allSatisfy { $0 != nil }
                ? converted.compactMap { $0 }.joined() : String(body)
            words.append(FuzzWord(intended: String(body), following: String(chars[separator..<i]),
                                  own: own, wrong: wrong, keys: keys))
        }
        return (prefix, words)
    }

    static func input(prefix: String, words: [FuzzWord], mode: FuzzMode,
                      rng: inout SplitMix64) -> FuzzInput {
        let eligible = words.indices.filter { words[$0].canMistype }
        var chosen: Set<Int> = []
        switch mode {
        case .clean: break
        case .wrongAll: chosen = Set(eligible)
        case .wrongSome:
            if !eligible.isEmpty {
                if rng.index(2) == 0 {
                    chosen = Set(eligible.filter { _ in rng.index(2) == 0 })
                } else {
                    let start = rng.index(words.count)
                    let end = start + rng.index(words.count - start) + 1
                    chosen = Set(eligible.filter { (start..<end).contains($0) })
                }
                if chosen.isEmpty { chosen.insert(eligible[rng.index(eligible.count)]) }
            }
        case .switchMid:
            // Keep at least the first word right. A one-word sentence has no switch boundary.
            if words.count > 1 {
                let boundary = 1 + rng.index(words.count - 1)
                chosen = Set(eligible.filter { $0 >= boundary })
            }
        }
        return FuzzInput(prefix: prefix, words: words, mistaken: chosen)
    }
}

/// Replays physical letter keys, literal separators, and user layout changes.
/// Automatic switches affect subsequent keys, as in the running app. No CGEvents,
/// TIS selection, preference writes, or synthetic input are sent to the user's Mac.
struct FuzzReplay {
    let corrector: Corrector
    private var pipeline = WordPipeline()
    private var current: Lang = .en
    private var planned: Lang?
    private var buffer: [Stroke] = []
    private var output = ""
    private(set) var presentedWords: [String] = []
    private(set) var decisions: [FuzzDecision] = []

    var presented: String { presentedWords.joined(separator: " ") }

    init(corrector: Corrector) { self.corrector = corrector }

    mutating func process(_ input: FuzzInput) -> String {
        pipeline = WordPipeline()
        current = .en
        planned = nil
        buffer = []
        presentedWords = []
        decisions = []
        output = input.prefix
        for (i, word) in input.words.enumerated() {
            if let own = word.own {
                let desired = input.mistaken.contains(i) ? corrector.layouts.other(own)! : own
                // The user switches only when the planned layout changes. An automatic
                // fix is allowed to keep the next word on the correct layout.
                // Excluded tokens are clean by construction. The user must select
                // their own layout even if an earlier automatic switch changed it.
                // Otherwise e.g. v2.1 becomes м2ю1 before the detector sees it.
                if desired != planned || !word.canMistype {
                    if desired != current {
                        pipeline.afterFix = false
                        if !buffer.isEmpty { pipeline.run = [] }
                        buffer = []
                        current = desired
                    }
                    planned = desired
                }
            }
            var presentedWord = ""
            for (ch, key) in zip(word.intended, word.keys) {
                if let key, let rendered = corrector.layouts.tables[current]?.char(for: key) {
                    presentedWord += rendered
                    output += rendered
                    append(key)
                } else {
                    presentedWord.append(ch)
                    literal(ch)
                }
            }
            presentedWords.append(presentedWord)
            for ch in word.following { literal(ch) }
        }
        // Finish the final word with a virtual Space, without changing the oracle text.
        if input.words.last?.following.isEmpty == true { end(boundary: 49) }
        return output
    }

    private mutating func append(_ key: Stroke) {
        buffer.append(key)
        if buffer.count > WordPipeline.maxBuffer { reset() }
    }

    private mutating func reset() {
        buffer = []
        pipeline = WordPipeline()
    }

    private mutating func literal(_ ch: Character) {
        let boundary: UInt16?
        switch ch {
        case " ": boundary = 49
        case "\t": boundary = 48
        case "\n", "\r", "\r\n": boundary = 36
        default: boundary = nil
        }
        if let boundary { end(boundary: boundary) }
        else if let key = corrector.layouts.tables[current]?.stroke(for: String(ch)) { append(key) }
        else { reset() }
        output.append(ch)
    }

    private mutating func end(boundary: UInt16) {
        let strokes = buffer
        let action = pipeline.end(strokes, boundary: boundary, lang: current,
                                  automatic: true, corrector: corrector)
        buffer = []
        let changes: [Correction]
        let kind: String
        switch action {
        case .unchanged: changes = []; kind = "unchanged"
        case let .correction(c): changes = [c]; kind = "current"
        case let .correctionGroup(group): changes = group; kind = "group"
        case let .shortWords(short): changes = short; kind = "retro"
        }
        decisions += changes.map { FuzzDecision(kind: kind, typed: $0.typed, converted: $0.converted) }
        switch action {
        case .unchanged: break
        case let .correction(c):
            output = String(output.dropLast(c.deleteCount)) + c.converted
            current = c.target
        case let .correctionGroup(group):
            let typed = group.map(\.typed).joined(separator: " ")
            output = String(output.dropLast(typed.count)) + group.map(\.converted).joined(separator: " ")
            current = group.last!.target
        case let .shortWords(short):
            let originals = short.map(\.typed)
            // Only the buffered suffix is the current word, exactly as in Engine.
            let currentWord = strokes.compactMap { corrector.layouts.tables[current]?.char(for: $0) }.joined()
            let count = (originals + [currentWord]).joined(separator: " ").count
            output = String(output.dropLast(count)) + (short.map(\.converted) + [currentWord]).joined(separator: " ")
        }
    }
}

struct FuzzDecision: Encodable {
    let kind: String
    let typed: String
    let converted: String
}

struct FuzzStats {
    var sentences = 0
    var exact = 0
    var words = 0
    var needsFix = 0
    var fixed = 0
    var cleanWords = 0
    var falsePositives = 0
    var missed = 0
    var wrong = 0
    var detectorFalsePositives = 0
    var detectorMissed = 0
    var detectorWrong = 0
    var layoutAffected = 0
    var layoutUnresolved = 0

    mutating func record(typed: String, got: String, expected: String, presented: String? = nil) -> String? {
        sentences += 1
        if got == expected { exact += 1 }
        let t = typed.split(whereSeparator: \.isWhitespace).map(String.init)
        let g = got.split(whereSeparator: \.isWhitespace).map(String.init)
        let e = expected.split(whereSeparator: \.isWhitespace).map(String.init)
        let actual = (presented ?? typed).split(whereSeparator: \.isWhitespace).map(String.init)
        var fp = 0, miss = 0, bad = 0
        var detectorFP = 0, detectorMiss = 0, detectorBad = 0, affected = 0, unresolved = 0
        words += e.count
        for i in e.indices {
            let typedWord = i < t.count ? t[i] : ""
            let gotWord = i < g.count ? g[i] : ""
            let actualWord = i < actual.count ? actual[i] : ""
            if actualWord != typedWord {
                affected += 1
                if gotWord != e[i] { unresolved += 1 }
            }
            if actualWord == e[i] {
                if gotWord != e[i] { detectorFP += 1 }
            } else if gotWord != e[i] {
                if gotWord == actualWord { detectorMiss += 1 }
                else { detectorBad += 1 }
            }
            if typedWord == e[i] {
                cleanWords += 1
                if gotWord != e[i] { fp += 1 }
            } else {
                needsFix += 1
                if gotWord == e[i] { fixed += 1 }
                else if gotWord == typedWord { miss += 1 }
                else { bad += 1 }
            }
        }
        // Extra output words count as wrong output rather than disappearing from the report.
        bad += max(0, g.count - e.count)
        detectorBad += max(0, g.count - e.count)
        detectorFalsePositives += detectorFP
        detectorMissed += detectorMiss
        detectorWrong += detectorBad
        layoutAffected += affected
        layoutUnresolved += unresolved
        falsePositives += fp
        missed += miss
        wrong += bad
        guard got != expected else { return nil }
        return "baseline_false_positives=\(fp), baseline_missed=\(miss), baseline_wrong=\(bad)"
            + ", detector_false_positives=\(detectorFP), detector_missed=\(detectorMiss), detector_wrong=\(detectorBad)"
            + ", layout_affected=\(affected), layout_unresolved=\(unresolved)"
            + (g.count != e.count ? ", word_count_mismatch" : "")
            + (fp + miss + bad == 0 ? ", separator_mismatch" : "")
    }

    static func rate(_ count: Int, _ total: Int) -> String {
        total == 0 ? "n/a" : String(format: "%.1f%%", Double(count) * 100 / Double(total))
    }
}

struct FuzzFailure: Encodable {
    let id: String
    let category: String
    let mode: String
    let pass: Int
    let seed: UInt64
    let typed: String
    let got: String
    let expected: String
    let reason: String
    var presented: String? = nil
    var decisions: [FuzzDecision] = []
}

enum FuzzReports {
    static func write(failures: [FuzzFailure], summary: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for failure in failures {
            data.append(try encoder.encode(failure))
            data.append(0x0A)
        }
        func save(in directory: URL, note: String = "") throws {
            let report = directory.appendingPathComponent("anakena-fuzz-report.jsonl")
            let markdown = directory.appendingPathComponent("anakena-fuzz-summary.md")
            try data.write(to: report, options: .atomic)
            try (summary + note).write(to: markdown, atomically: true, encoding: .utf8)
            print("Fuzz reports: \(report.path), \(markdown.path)")
        }
        do { try save(in: URL(fileURLWithPath: "/tmp", isDirectory: true)) }
        catch {
            let fallback = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            let note = "\n/tmp unavailable (\(error)); used NSTemporaryDirectory: \(fallback.path)\n"
            print(note)
            try save(in: fallback, note: note)
        }
    }
}
