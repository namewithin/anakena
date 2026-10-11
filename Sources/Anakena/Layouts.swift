import Carbon
import Foundation

struct Lang: RawRepresentable, Hashable, Codable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first.map { String($0).lowercased() } ?? ""
    }

    static let en = Lang(rawValue: "en")
    static let uk = Lang(rawValue: "uk")

    var title: String { self == .uk ? "УК" : rawValue.uppercased() }
}

struct LangPair: Equatable, Codable {
    let a: Lang
    let b: Lang

    var languages: [Lang] { [a, b] }
    var title: String { "\(a.title) ↔ \(b.title)" }

    func other(_ lang: Lang) -> Lang? {
        if lang == a { return b }
        if lang == b { return a }
        return nil
    }

    /// Preserve a valid choice; otherwise prefer languages with dictionaries, then EN/UK.
    static func pick(enabled: [Lang], stored: LangPair? = nil, dictionaries: Set<Lang>? = nil) -> LangPair? {
        var languages: [Lang] = []
        for lang in enabled where !languages.contains(lang) { languages.append(lang) }
        guard languages.count >= 2 else { return nil }
        if let stored, stored.a != stored.b, stored.languages.allSatisfy(languages.contains) {
            return stored
        }
        if let dictionaries {
            let supported = languages.filter(dictionaries.contains)
            if supported.count >= 2 { languages = supported }
        }
        if languages.contains(.en), languages.contains(.uk) { return LangPair(a: .en, b: .uk) }
        let a = languages.contains(.en) ? .en : languages[0]
        return LangPair(a: a, b: languages.first { $0 != a }!)
    }
}

/// One physical key press: which key, and the modifiers that change its character.
struct Stroke: Equatable {
    var keyCode: UInt16
    var shift: Bool
    var caps: Bool
    var option: Bool = false
}

/// Key → character table for one keyboard layout, built from the system layout data.
struct LayoutTable {
    private var chars: [Int: String] = [:]
    private var reverse: [String: Stroke] = [:]

    /// Keys that end a word. They never go into a table.
    static let boundaryKeys: Set<UInt16> = [36, 48, 49, 76]

    private static func key(_ s: Stroke) -> Int {
        Int(s.keyCode) | (s.shift ? 1 << 16 : 0) | (s.caps ? 1 << 17 : 0) | (s.option ? 1 << 18 : 0)
    }

    func char(for s: Stroke) -> String? { chars[Self.key(s)] }
    func stroke(for ch: String) -> Stroke? { reverse[ch] }

    init?(source: TISInputSource) {
        guard let data: Data = TIS.property(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let kbType = UInt32(LMGetKbdType())
        var built = false
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            for option in [false, true] {
                for caps in [false, true] {
                    for shift in [false, true] {
                        let mods = UInt32((shift ? shiftKey : 0) | (caps ? alphaLock : 0) | (option ? optionKey : 0)) >> 8
                        for code in UInt16(0)...50 where !Self.boundaryKeys.contains(code) {
                            var dead: UInt32 = 0
                            var length = 0
                            var buf = [UniChar](repeating: 0, count: 4)
                            let status = UCKeyTranslate(
                                layout, code, UInt16(kUCKeyActionDown), mods, kbType,
                                0, &dead, buf.count, &length, &buf)
                            guard status == noErr, dead == 0, length > 0 else { continue }
                            let s = String(utf16CodeUnits: buf, count: length)
                            if s.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { continue }
                            let stroke = Stroke(keyCode: code, shift: shift, caps: caps, option: option)
                            chars[Self.key(stroke)] = s
                            if !caps, !option || s.allSatisfy(\.isLetter), reverse[s] == nil {
                                reverse[s] = stroke
                            }
                        }
                    }
                }
            }
            built = !chars.isEmpty
        }
        if !built { return nil }
    }
}

enum TIS {
    static func property<T>(_ source: TISInputSource, _ key: CFString) -> T? {
        guard let ptr = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(ptr).takeUnretainedValue() as? T
    }

    static func id(_ source: TISInputSource) -> String {
        property(source, kTISPropertyInputSourceID) ?? ""
    }

    static func lang(_ source: TISInputSource) -> Lang? {
        let langs: [String] = property(source, kTISPropertyInputSourceLanguages) ?? []
        guard let code = langs.first else { return nil }
        let lang = Lang(rawValue: code)
        return lang.rawValue.isEmpty ? nil : lang
    }

    static func keyboardLayouts(includeAllInstalled: Bool) -> [TISInputSource] {
        let filter = [kTISPropertyInputSourceType: kTISTypeKeyboardLayout] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, includeAllInstalled)?.takeRetainedValue() else { return [] }
        return (list as? [TISInputSource]) ?? []
    }
}

/// Enabled layouts and their key tables, with one active language pair.
final class LayoutSet {
    private(set) var tables: [Lang: LayoutTable] = [:]
    private(set) var sources: [Lang: TISInputSource] = [:]
    private(set) var languages: [Lang] = []
    private(set) var pair: LangPair?
    private var langByID: [String: Lang] = [:]

    /// Enabled keyboard layouts on this Mac: the first layout for each language wins.
    init() { reload() }

    /// Exact layouts by input source id (used by tests; looks at all installed layouts).
    init(ids: [Lang: String]) {
        let all = TIS.keyboardLayouts(includeAllInstalled: true)
        for (lang, id) in ids {
            if let src = all.first(where: { TIS.id($0) == id }) { add(src, as: lang) }
        }
        choosePair()
    }

    func reload() {
        tables = [:]; sources = [:]; langByID = [:]; languages = []
        for src in TIS.keyboardLayouts(includeAllInstalled: false) {
            guard let lang = TIS.lang(src), sources[lang] == nil else { continue }
            add(src, as: lang)
        }
        choosePair(stored: pair)
    }

    private func add(_ src: TISInputSource, as lang: Lang) {
        guard let table = LayoutTable(source: src) else { return }
        languages.append(lang)
        tables[lang] = table
        sources[lang] = src
        langByID[TIS.id(src)] = lang
    }

    func choosePair(stored: LangPair? = nil, dictionaries: Set<Lang>? = nil) {
        pair = LangPair.pick(enabled: languages, stored: stored, dictionaries: dictionaries)
    }

    func other(_ lang: Lang) -> Lang? { pair?.other(lang) }

    var isComplete: Bool { pair != nil }

    /// Language of the layout that is active now, if it is one of ours.
    func currentLang() -> Lang? {
        guard let cur = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        if let l = langByID[TIS.id(cur)] { return l }
        guard let l = TIS.lang(cur), tables[l] != nil else { return nil }
        return l
    }

    func select(_ lang: Lang) {
        if let src = sources[lang] { TISSelectInputSource(src) }
    }
}
