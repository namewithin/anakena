import Foundation

final class Settings {
    enum Mode: String { case auto, manual }

    private let d: UserDefaults

    init(defaults: UserDefaults = .standard) { d = defaults }

    static let defaultIgnored = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.apple.dt.Xcode",
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm",
        "co.zeit.hyper", "org.tabby", "dev.zed.Zed", "com.sublimetext.4",
        "com.microsoft.rdc.macos", "com.parallels.desktop.console",
        "com.vmware.fusion", "com.utmapp.UTM", "com.jetbrains.",
    ]

    var enabled: Bool {
        get { d.object(forKey: "enabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "enabled") }
    }

    var mode: Mode {
        get { Mode(rawValue: d.string(forKey: "mode") ?? "") ?? .auto }
        set { d.set(newValue.rawValue, forKey: "mode") }
    }

    var languagePair: LangPair? {
        get {
            guard let a = d.string(forKey: "langA"), let b = d.string(forKey: "langB") else { return nil }
            return LangPair(a: Lang(rawValue: a), b: Lang(rawValue: b))
        }
        set {
            d.set(newValue?.a.rawValue, forKey: "langA")
            d.set(newValue?.b.rawValue, forKey: "langB")
        }
    }

    var ignoredApps: [String] {
        get {
            migrateIgnoredApps()
            let removed = Set(d.stringArray(forKey: "ignoredAppsRemoved") ?? [])
            let added = d.stringArray(forKey: "ignoredAppsAdded") ?? []
            return Self.defaultIgnored.filter { !removed.contains($0) } + added.filter { !Self.defaultIgnored.contains($0) }
        }
        set {
            migrateIgnoredApps()
            let selected = Set(newValue)
            d.set(Self.defaultIgnored.filter { !selected.contains($0) }, forKey: "ignoredAppsRemoved")
            d.set(newValue.filter { !Self.defaultIgnored.contains($0) }, forKey: "ignoredAppsAdded")
        }
    }

    func ignores(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        if (d.stringArray(forKey: "ignoredAppsExcluded") ?? []).contains(bundleID) { return false }
        return ignoredApps.contains { entry in
            entry.hasSuffix(".") ? bundleID.hasPrefix(entry) :
                entry.hasSuffix("*") ? bundleID.hasPrefix(String(entry.dropLast())) : bundleID == entry
        }
    }

    func toggleIgnored(_ bundleID: String) {
        var excluded = d.stringArray(forKey: "ignoredAppsExcluded") ?? []
        if let i = excluded.firstIndex(of: bundleID) {
            excluded.remove(at: i)
        } else if ignores(bundleID) {
            excluded.append(bundleID)
        } else {
            ignoredApps.append(bundleID)
            return
        }
        d.set(excluded, forKey: "ignoredAppsExcluded")
    }

    private func migrateIgnoredApps() {
        guard let old = d.stringArray(forKey: "ignoredApps") else { return }
        // These were the defaults in releases that stored the entire effective list.
        let previous = Array(Self.defaultIgnored.prefix(7))
        d.set(previous.filter { !old.contains($0) }, forKey: "ignoredAppsRemoved")
        d.set(old.filter { !previous.contains($0) }, forKey: "ignoredAppsAdded")
        d.removeObject(forKey: "ignoredApps")
    }

    private func learnedKey(_ name: String, for pair: LangPair) -> String {
        "\(name).\(pair.languages.map(\.rawValue).sorted().joined(separator: "-"))"
    }

    private func learnedWords(_ name: String, for pair: LangPair) -> Set<String> {
        if let words = d.stringArray(forKey: learnedKey(name, for: pair)) { return Set(words) }
        // Old releases only supported EN/UK; keep their learning for that pair.
        if Set(pair.languages) == Set([Lang.en, .uk]) {
            return Set(d.stringArray(forKey: name) ?? [])
        }
        return []
    }

    func alwaysWords(for pair: LangPair) -> Set<String> { learnedWords("alwaysWords", for: pair) }
    func ignoredWords(for pair: LangPair) -> Set<String> { learnedWords("ignoredWords", for: pair) }

    func setAlwaysWords(_ words: Set<String>, for pair: LangPair) {
        d.set(Array(words).sorted(), forKey: learnedKey("alwaysWords", for: pair))
    }

    func setIgnoredWords(_ words: Set<String>, for pair: LangPair) {
        d.set(Array(words).sorted(), forKey: learnedKey("ignoredWords", for: pair))
    }

    func resetLearning() {
        for key in d.dictionaryRepresentation().keys where
            key == "alwaysWords" || key == "ignoredWords" ||
            key.hasPrefix("alwaysWords.") || key.hasPrefix("ignoredWords.") {
            d.removeObject(forKey: key)
        }
    }

    var askedAccessibility: Bool {
        get { d.bool(forKey: "askedAccessibility") }
        set { d.set(newValue, forKey: "askedAccessibility") }
    }
}
