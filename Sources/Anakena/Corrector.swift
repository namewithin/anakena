import AppKit

protocol Speller {
    func isCorrect(_ word: String, in lang: Lang) -> Bool
    func supports(_ lang: Lang) -> Bool
}

extension Speller {
    func supports(_ lang: Lang) -> Bool { true }
}

/// macOS system spell checker. Local, no network.
final class SystemSpeller: Speller {
    private let tag = NSSpellChecker.uniqueSpellDocumentTag()

    static func dictionary(for lang: Lang, available: [String]) -> String? {
        available.first { $0 == lang.rawValue }
            ?? available.first { Lang(rawValue: $0) == lang }
    }

    func supports(_ lang: Lang) -> Bool {
        Self.dictionary(for: lang, available: NSSpellChecker.shared.availableLanguages) != nil
    }

    func isCorrect(_ word: String, in lang: Lang) -> Bool {
        guard let dictionary = Self.dictionary(for: lang, available: NSSpellChecker.shared.availableLanguages)
        else { return false }
        let r = NSSpellChecker.shared.checkSpelling(
            of: word, startingAt: 0, language: dictionary, wrap: false,
            inSpellDocumentWithTag: tag, wordCount: nil)
        return r.location == NSNotFound
    }
}

struct Correction {
    let typed: String      // the whole token on screen, including punctuation
    let converted: String  // the whole token remapped through the target table
    let word: String       // the original word, without affixes, for learning
    let target: Lang       // layout to switch to

    var deleteCount: Int { typed.count }
}

struct Corrector {
    let layouts: LayoutSet
    let speller: Speller
    var always: Set<String> = []
    var ignored: Set<String> = []

    static let maxLearned = 2000
    private static let minLength = 3

    /// Real one-letter words. The spell checker accepts any single letter, so it cannot judge these.
    private static let oneLetterWords: [Lang: Set<String>] = [
        .en: ["a", "i"],
        .uk: ["а", "б", "в", "ж", "з", "й", "і", "о", "у", "я"],
    ]

    /// Decide whether a finished word was typed in the wrong layout.
    /// Honor learned choices; otherwise require a misspelling and a correct conversion.
    func decide(_ strokes: [Stroke], current: Lang, afterFix: Bool = false) -> Correction? {
        guard let target = layouts.other(current),
              let cur = layouts.tables[current], let oth = layouts.tables[target] else { return nil }
        let typedChars = strokes.compactMap { cur.char(for: $0) }
        let otherChars = strokes.compactMap { oth.char(for: $0) }
        guard typedChars.count == strokes.count, otherChars.count == strokes.count else { return nil }

        // A single letter needs an immediately preceding correction as context.
        // Reuse retro-fix guards: protect source a/I, ignored words and punctuation,
        // and accept only the existing language-specific one-letter whitelist.
        if strokes.count == 1, afterFix { return fixShort(strokes, typedIn: current) }

        let currentIsWord = isWord(strokes, in: current)
        let learnedToken = always.contains(typedChars.joined().lowercased())

        for range in Self.wordRanges(typed: typedChars, converted: otherChars) {
            let n = range.count
            guard n >= 2 else { continue }
            let typed = typedChars[range].joined()
            let other = otherChars[range].joined()
            let key = typed.lowercased()
            // A target split must never discard a letter from a valid source word
            // ("будь" must not become the English word "elm"). Punctuation may,
            // however, be a target letter: ",elm" is "будь", not the word "elm".
            if currentIsWord && !learnedToken {
                let excluded = typedChars[..<range.lowerBound] + typedChars[range.upperBound...]
                if excluded.joined().contains(where: \.isLetter) { continue }
                if Self.isLexicalWord(typed) { continue }
            }
            if ignored.contains(key) { return nil }
            guard other.lowercased() != key else { continue }
            if always.contains(key) {
                return Correction(typed: typedChars.joined(), converted: otherChars.joined(),
                                  word: typed, target: target)
            }
            guard n >= Self.minLength || afterFix else { continue }
            guard speller.supports(current), speller.supports(target) else { continue }
            guard Self.isLexicalWord(other) else { continue }
            guard !typed.contains(where: \.isNumber), !Self.looksLikeCode(typed) else { continue }
            if Self.isLexicalWord(typed), isCorrect(typed, in: current) { continue }
            if isCorrect(other, in: target) {
                return Correction(typed: typedChars.joined(), converted: otherChars.joined(),
                                  word: typed, target: target)
            }
        }
        return nil
    }

    /// Try the whole token first: punctuation keys can be letters in the other layout.
    /// Then inspect the word inside affixes, in either layout. The affixes only
    /// leave the spelling decision; a successful correction remaps every stroke.
    private static func wordRanges(typed: [String], converted: [String]) -> [Range<Int>] {
        var ranges = [0..<typed.count]
        func append(_ range: Range<Int>) {
            // Do not peel away path/identifier markers or function-call suffixes.
            let prefix = typed[..<range.lowerBound].joined()
            let suffix = typed[range.upperBound...].joined()
            guard !prefix.contains(where: { "/\\@_~".contains($0) }),
                  !suffix.contains(where: { "\\@_~([{=".contains($0) }),
                  !ranges.contains(range) else { return }
            ranges.append(range)
        }
        // Retain the original one-key fallback, even when the word itself ends
        // on a punctuation key (e.g. "lzre.,": "дякую" followed by the comma key).
        if let last = typed.last, isAffix(last) { append(0..<(typed.count - 1)) }
        for chars in [converted, typed] {
            var start = 0, end = chars.count
            while start < end, isAffix(chars[start]) { start += 1 }
            while end > start, isAffix(chars[end - 1]) { end -= 1 }
            append(start..<end)
        }
        return ranges
    }

    private static func isAffix(_ char: String) -> Bool {
        !char.isEmpty && char.allSatisfy { $0.isPunctuation || $0.isSymbol }
    }

    private static func isLexicalWord(_ word: String) -> Bool {
        guard word.first?.isLetter == true, word.last?.isLetter == true else { return false }
        return word.allSatisfy { $0.isLetter || "'ʼ’-".contains($0) }
    }

    private func isCorrect(_ word: String, in lang: Lang) -> Bool {
        speller.isCorrect(word, in: lang)
            || (word.first?.isUppercase == true && !word.dropFirst().contains(where: \.isUppercase)
                && speller.isCorrect(word.lowercased(), in: lang))
    }

    /// Check whether a finished word is spelled right in its typed layout.
    func isWord(_ strokes: [Stroke], in lang: Lang) -> Bool {
        guard speller.supports(lang), let table = layouts.tables[lang] else { return false }
        let chars = strokes.compactMap { table.char(for: $0) }
        guard chars.count == strokes.count else { return false }
        return Self.wordRanges(typed: chars, converted: chars).contains { range in
            let word = chars[range].joined()
            return word.count >= 2 && Self.isLexicalWord(word) && isCorrect(word, in: lang)
        }
    }

    /// A conservative context anchor, without treating a lone letter as a dictionary word.
    func isSingleLetterWord(_ strokes: [Stroke], in lang: Lang) -> Bool {
        guard strokes.count == 1, speller.supports(lang),
              let text = layouts.tables[lang]?.char(for: strokes[0]) else { return false }
        return Self.oneLetterWords[lang, default: []].contains(text.lowercased())
    }

    /// Fix only the trailing short words typed in the other layout.
    func fixShortWords(_ run: [(strokes: [Stroke], lang: Lang)], before lang: Lang) -> [Correction] {
        var fixed: [Correction] = []
        for word in run.reversed() {
            guard word.lang == layouts.other(lang), let text = fixShort(word.strokes, typedIn: word.lang) else { break }
            fixed.append(text)
        }
        return fixed.reversed()
    }

    private func fixShort(_ strokes: [Stroke], typedIn lang: Lang) -> Correction? {
        guard let target = layouts.other(lang),
              let cur = layouts.tables[lang], let oth = layouts.tables[target] else { return nil }
        let typedChars = strokes.compactMap { cur.char(for: $0) }
        let otherChars = strokes.compactMap { oth.char(for: $0) }
        guard typedChars.count == strokes.count, otherChars.count == strokes.count else { return nil }
        guard always.contains(typedChars.joined().lowercased()) || !isWord(strokes, in: lang)
        else { return nil }
        for range in Self.wordRanges(typed: typedChars, converted: otherChars) {
            guard (1...2).contains(range.count) else { continue }
            let typed = typedChars[range].joined()
            let other = otherChars[range].joined()
            let correction = Correction(typed: typedChars.joined(), converted: otherChars.joined(),
                                        word: typed, target: target)
            guard typed.allSatisfy(\.isLetter), other.allSatisfy(\.isLetter) else { continue }
            let key = typed.lowercased()
            if ignored.contains(key) { return nil }
            guard other.lowercased() != key else { continue }
            if always.contains(key) { return correction }
            if range.count == 1 {
                guard !Self.oneLetterWords[lang, default: []].contains(key),
                      Self.oneLetterWords[target, default: []].contains(other.lowercased()) else { continue }
            } else {
                guard speller.supports(lang), speller.supports(target),
                      !Self.looksLikeCode(typed), !isCorrect(typed, in: lang),
                      isCorrect(other, in: target) else { continue }
            }
            return correction
        }
        return nil
    }

    /// Remember the latest choice, keeping each list bounded.
    mutating func learn(_ word: String, always: Bool) {
        let w = word.lowercased()
        if always {
            ignored.remove(w)
            if self.always.count < Self.maxLearned { self.always.insert(w) }
        } else {
            self.always.remove(w)
            if ignored.count < Self.maxLearned { ignored.insert(w) }
        }
    }

    /// Find a single word that can be learned from a manual conversion.
    func learnableWord(_ strokes: [Stroke], current: Lang) -> String? {
        guard let target = layouts.other(current),
              let cur = layouts.tables[current], let oth = layouts.tables[target] else { return nil }
        let typedChars = strokes.compactMap { cur.char(for: $0) }
        let otherChars = strokes.compactMap { oth.char(for: $0) }
        guard typedChars.count == strokes.count, otherChars.count == strokes.count else { return nil }

        for drop in 0...1 {
            let n = strokes.count - drop
            guard n >= 2 else { break }
            if drop == 1, typedChars[n].first?.isLetter ?? true { break }

            let typed = typedChars[0..<n].joined()
            let other = otherChars[0..<n].joined()
            guard other.allSatisfy({ $0.isLetter || "'ʼ’".contains($0) }) else { continue }
            guard !typed.contains(where: \.isNumber) else { continue }
            return typed
        }
        return nil
    }

    /// Re-map text char by char as if it was typed in the other layout (for selections).
    func convertText(_ text: String, from preferred: Lang? = nil) -> String {
        guard let pair = layouts.pair,
              let a = layouts.tables[pair.a], let b = layouts.tables[pair.b] else { return text }
        // Count letters each layout can type. Shared alphabets use the current layout on a tie.
        let letters = text.filter(\.isLetter)
        let countA = letters.filter { a.stroke(for: String($0)) != nil }.count
        let countB = letters.filter { b.stroke(for: String($0)) != nil }.count
        let fallback = preferred.flatMap { pair.other($0) == nil ? nil : $0 } ?? pair.a
        let from = countA == countB ? fallback : (countA > countB ? pair.a : pair.b)
        guard let target = layouts.other(from),
              let src = layouts.tables[from], let dst = layouts.tables[target] else { return text }
        // EN/UK selections used only plain and Shift keys before multilingual support.
        let useOption = Set(pair.languages) != Set([Lang.en, .uk])
        return text.map { ch -> String in
            let s = String(ch)
            guard let stroke = src.stroke(for: s), useOption || !stroke.option,
                  let out = dst.char(for: stroke) else { return s }
            return out
        }.joined()
    }

    static func looksLikeCode(_ w: String) -> Bool {
        // No "." here: on EN keys it is the Ukrainian "ю".
        if w.contains(where: { "/\\@_".contains($0) }) { return true }
        let letters = w.filter(\.isLetter)
        if letters.count <= 4, letters.allSatisfy(\.isUppercase) { return true }
        var prevLower = false
        for ch in w {
            if ch.isUppercase, prevLower { return true }
            prevLower = ch.isLowercase
        }
        return false
    }
}
