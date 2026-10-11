import AppKit
import Carbon

protocol InjectionSink {
    func replace(typed: String, with fixed: String, boundary: UInt16, flags: CGEventFlags,
                 selectLayout: () -> Void, proceed: () -> Bool)
    func replay(_ key: HeldKey)
}

struct LiveInjection: InjectionSink {
    func replay(_ key: HeldKey) { Typist.replay(key) }
    func replace(typed: String, with fixed: String, boundary: UInt16, flags: CGEventFlags,
                 selectLayout: () -> Void, proceed: () -> Bool) {
        guard proceed() else { return }
        Typist.backspaces(typed.count + 1)
        selectLayout()
        guard proceed() else { return }
        Typist.type(fixed)
        guard proceed() else { return }
        Typist.tap(boundary, flags: flags)
    }
}

/// Watches keystrokes, fixes words typed in the wrong layout, runs the hotkeys.
/// Keeps the current word, last finished word, and last fix (for Undo / the menu).
final class Engine {
    private typealias Word = WordPipeline.Word

    struct Environment {
        var frontmost: () -> (pid: pid_t, bundleID: String?)? = {
            NSWorkspace.shared.frontmostApplication.map { ($0.processIdentifier, $0.bundleIdentifier) }
        }
        var focus: (pid_t) -> Focus = Engine.focus
        var secureInput: () -> Bool = { IsSecureEventInputEnabled() }
        var currentLang: () -> Lang?
        var selectLayout: (Lang) -> Void

        init(layouts: LayoutSet) {
            currentLang = { layouts.currentLang() }
            selectLayout = { layouts.select($0) }
        }
    }

    private struct Fix {
        let typed: String    // text on screen before the fix, without the boundary
        let fixed: String    // text we typed instead
        let words: [String]  // the user's original words we changed; learned as "never" on Undo
        let boundary: UInt16
        let original: Lang
        let pid: pid_t
        var canUndo: Bool { boundary == 49 }
    }

    private static let hotkeyMods: CGEventFlags = [.maskControl, .maskAlternate]
    private static let convertKey: UInt16 = 49 // Space
    private static let toggleKey: UInt16 = 6   // Z

    let settings: Settings
    let layouts: LayoutSet
    private var corrector: Corrector
    private let injection: InjectionSink
    private let environment: Environment
    private let injectionQueue: DispatchQueue
    private struct Pending {
        let id: Int
        var held: HeldKeys
    }
    private var pending: Pending?
    private var nextPendingID = 0

    var frontmostBundleID: String?
    /// Called on the main queue when the menu bar should refresh.
    var onChange: (() -> Void)?
    /// True for clicks on our own menu bar item / menu: they must not drop the Undo state.
    var isOwnClick: ((CGPoint) -> Bool)?

    private var buffer: [Stroke] = []
    private var bufferFocus: (pid: pid_t, element: CFTypeRef?)?
    private var lastKeystroke: UInt64?
    /// Finished words of the current typing run, oldest first: same field, exactly one Space after each.
    private var run: [Word] = []
    /// Run kept across a layout-switch shortcut (⌃Space and the like), valid only while `contextVersion` matches.
    private var switchRun: (words: [Word], version: Int)?
    private var afterFix = false
    private var lastWord: Word?
    private var lastFix: Fix?
    private(set) var lastFixText: String?
    private var pasting = false
    private var contextVersion = 0
    private var mouseDownCount = 0
    private var ourSwitch: (lang: Lang, until: TimeInterval)?

    var canUndo: Bool { lastFix?.canUndo ?? false }
    var learnedCounts: (always: Int, ignored: Int) { (corrector.always.count, corrector.ignored.count) }

    init(settings: Settings, layouts: LayoutSet, speller: Speller = SystemSpeller(),
         injection: InjectionSink = LiveInjection(), environment: Environment? = nil,
         injectionQueue: DispatchQueue = DispatchQueue(label: "Anakena.injection")) {
        self.settings = settings
        self.layouts = layouts
        self.injection = injection
        self.environment = environment ?? Environment(layouts: layouts)
        self.injectionQueue = injectionQueue
        corrector = Corrector(layouts: layouts, speller: speller)
        reloadLanguages()
    }

    func reloadLanguages() {
        reset()
        let dictionaries = Set(layouts.languages.filter { corrector.speller.supports($0) })
        layouts.choosePair(stored: settings.languagePair, dictionaries: dictionaries)
        corrector.always = layouts.pair.map { settings.alwaysWords(for: $0) } ?? []
        corrector.ignored = layouts.pair.map { settings.ignoredWords(for: $0) } ?? []
        // Load the active dictionaries now: the first lookup must not happen inside the tap.
        for lang in layouts.pair?.languages ?? [] {
            _ = corrector.speller.isCorrect("test", in: lang)
        }
    }

    func reset() {
        pending?.held.discard()
        pending = nil
        clearState()
    }

    private func clearState() {
        buffer = []
        bufferFocus = nil
        run = []
        switchRun = nil
        afterFix = false
        lastWord = nil
        lastFix = nil
        lastFixText = nil
        contextVersion += 1
    }

    func inputSourceChanged() {
        let own = ourSwitch.map { $0.lang == environment.currentLang() && ProcessInfo.processInfo.systemUptime < $0.until } ?? false
        ourSwitch = nil
        guard !own else { return }
        // A switch right after a Space keeps the run, so short words typed before it can still be fixed.
        let kept = switchRun.flatMap { $0.version == contextVersion ? $0.words : nil } ?? (buffer.isEmpty ? run : [])
        reset()
        run = kept
    }

    private func selectLayout(_ lang: Lang) {
        if environment.currentLang() != lang {
            ourSwitch = (lang, ProcessInfo.processInfo.systemUptime + 0.5)
        }
        environment.selectLayout(lang)
    }

    /// Returns true when the event must be swallowed.
    func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reset()
            return false
        }
        if event.getIntegerValueField(.eventSourceUserData) == Typist.magic { return false }
        if type == .keyDown { contextVersion += 1 }
        if (type == .keyDown || type == .keyUp), pending != nil {
            let held = HeldKey(event, down: type == .keyDown)
            if pending?.held.append(held, at: ProcessInfo.processInfo.systemUptime) == false { reset() }
            return true
        }
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            mouseDownCount += 1
            contextVersion += 1
            if !(isOwnClick?(event.location) ?? false) { reset() }
            return false
        case .keyDown:
            return keyDown(event)
        default:
            return false
        }
    }

    private func keyDown(_ event: CGEvent) -> Bool {
        if Self.bufferExpired(since: lastKeystroke, at: event.timestamp) { reset() }
        lastKeystroke = event.timestamp
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let mods = flags.intersection([.maskCommand, .maskControl, .maskAlternate])

        if flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]) == Self.hotkeyMods {
            let repeating = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            // Toggle is global so it can turn us back on; convert passes through in ignored apps.
            if code == Self.toggleKey {
                if !repeating { DispatchQueue.main.async { self.toggleEnabled() } }
                return true
            }
            if code == Self.convertKey, settings.enabled,
               !environment.secureInput(), !settings.ignores(frontmostBundleID) {
                if !repeating { DispatchQueue.main.async { self.manualConvert() } }
                return true
            }
        }

        let stroke = Stroke(keyCode: code, shift: flags.contains(.maskShift),
                            caps: flags.contains(.maskAlphaShift), option: flags.contains(.maskAlternate))
        guard settings.enabled, mods.intersection([.maskCommand, .maskControl]).isEmpty, !environment.secureInput(),
              !settings.ignores(frontmostBundleID),
              let lang = environment.currentLang(), layouts.other(lang) != nil,
              !flags.contains(.maskAlternate) || layouts.tables[lang]?.char(for: stroke) != nil
        else {
            // ⌃Space and the like may switch the layout right after a Space: keep the run for inputSourceChanged().
            let kept = code == 49 && !mods.isEmpty && buffer.isEmpty ? run : []
            reset()
            switchRun = (kept, contextVersion)
            return false
        }

        lastFix = nil
        lastFixText = nil
        lastWord = nil

        if code == Typist.backspace {
            if !buffer.isEmpty { buffer.removeLast() }
            if buffer.isEmpty { reset() }
            return false
        }

        if LayoutTable.boundaryKeys.contains(code) {
            return wordEnded(boundary: code, lang: lang, flags: flags)
        }

        guard layouts.tables[lang]?.char(for: stroke) != nil else {
            reset()
            return false
        }
        if buffer.isEmpty {
            guard let app = environment.frontmost() else { reset(); return false }
            let focus = environment.focus(app.pid)
            guard case let .element(element) = focus else {
                if case .failed = focus { reset(); return false }
                bufferFocus = (app.pid, nil)
                buffer.append(stroke)
                if buffer.count > WordPipeline.maxBuffer { reset() }
                return false
            }
            guard !Self.isSecure(element) else { reset(); return false }
            bufferFocus = (app.pid, element)
        }
        buffer.append(stroke)
        if buffer.count > WordPipeline.maxBuffer { reset() }
        return false
    }

    private func wordEnded(boundary: UInt16, lang: Lang, flags: CGEventFlags) -> Bool {
        let strokes = buffer
        let focus = bufferFocus
        let version = contextVersion
        let shift = flags.intersection(.maskShift)
        var pipeline = WordPipeline(run: run, afterFix: afterFix)
        buffer = []
        run = []
        if boundary != 49 || !strokes.isEmpty { afterFix = false }
        guard !strokes.isEmpty, let focus else { return false }
        // NSSpellChecker stays on main; async lets the tap return the native boundary first.
        DispatchQueue.main.async { [self] in
            guard self.contextVersion == version, self.canInject(focus: focus) else { return }
            let action = pipeline.end(strokes, boundary: boundary, lang: lang,
                                      automatic: self.settings.mode == .auto, corrector: self.corrector)
            guard self.contextVersion == version, self.canInject(focus: focus) else { return }
            guard let replacement = self.replacement(for: action, strokes: strokes, lang: lang) else {
                self.afterFix = pipeline.afterFix
                self.run = pipeline.run
                if boundary == 49 { self.lastWord = self.run.last }
                return
            }
            self.nextPendingID += 1
            let id = self.nextPendingID
            self.injectionQueue.async {
                let mouseDownCount = DispatchQueue.main.sync { () -> Int? in
                    guard self.contextVersion == version, self.pending == nil,
                          self.canInject(focus: focus) else { return nil }
                    self.afterFix = pipeline.afterFix
                    self.run = pipeline.run
                    self.pending = Pending(id: id, held: HeldKeys(started: ProcessInfo.processInfo.systemUptime))
                    DispatchQueue.main.asyncAfter(deadline: .now() + HeldKeys.maxAge) { [weak self] in
                        if self?.pending?.id == id { self?.reset() }
                    }
                    return self.mouseDownCount
                }
                guard let mouseDownCount else { return }
                let proceed = { () -> Bool in
                    DispatchQueue.main.sync { () -> Bool in
                        guard self.pending?.id == id, self.mouseDownCount == mouseDownCount,
                              self.canInject(focus: focus) else {
                            if self.pending?.id == id { self.reset() }
                            return false
                        }
                        return true
                    }
                }
                self.injection.replace(typed: replacement.typed, with: replacement.fixed,
                                       boundary: boundary, flags: shift, selectLayout: {
                    if let target = action.corrections?.last?.target {
                        DispatchQueue.main.sync { self.selectLayout(target) }
                    }
                }, proceed: proceed)
                let fix = Fix(typed: replacement.typed, fixed: replacement.fixed,
                              words: replacement.words, boundary: boundary, original: lang, pid: focus.pid)
                self.releasePending(id: id, focus: focus, fix: fix, display: replacement.display)
            }
        }
        return false
    }

    private func canInject(focus: (pid: pid_t, element: CFTypeRef?)) -> Bool {
        settings.enabled && !environment.secureInput() &&
            !settings.ignores(frontmostBundleID) && !settings.ignores(environment.frontmost()?.bundleID) &&
            safeFocus(pid: focus.pid, recorded: focus.element, compareFocus: true)
    }

    private func replacement(for action: WordPipeline.Action, strokes: [Stroke], lang: Lang)
        -> (typed: String, fixed: String, words: [String], display: String)? {
        if let group = action.corrections {
            let typed = group.map(\.typed).joined(separator: " ")
            let fixed = group.map(\.converted).joined(separator: " ")
            return (typed, fixed, group.map(\.word), "\(typed) → \(fixed)")
        }
        if case let .shortWords(short) = action {
            let originals = short.map(\.typed)
            let converted = short.map(\.converted)
            let word = text(strokes, in: lang)
            return ((originals + [word]).joined(separator: " "),
                    (converted + [word]).joined(separator: " "), short.map(\.word),
                    "\(originals.joined(separator: " ")) → \(converted.joined(separator: " "))")
        }
        return nil
    }

    /// Runs on the serial injection queue; state and normal key handling remain on main.
    private func releasePending(id: Int, focus: (pid: pid_t, element: CFTypeRef?), fix: Fix, display: String) {
        var first = true
        while true {
            let keys = DispatchQueue.main.sync { () -> [HeldKey]? in
                guard var current = self.pending, current.id == id else { return nil }
                guard let keys = current.held.take(at: ProcessInfo.processInfo.systemUptime,
                                                   sameFocus: self.canInject(focus: focus)) else {
                    // Losing a few keys is safer than replaying them into another (possibly secure) field.
                    self.reset()
                    self.pending = nil
                    return nil
                }
                if first {
                    first = false
                    if fix.canUndo {
                        self.lastFix = fix
                        self.lastFixText = display
                    }
                }
                self.pending = nil
                if keys.isEmpty {
                    self.notifyChange()
                    return nil
                }
                var swallowedKeyUps: [UInt16] = []
                for key in keys where key.down {
                    if let event = key.event(), self.handle(type: .keyDown, event: event) {
                        swallowedKeyUps.append(key.code)
                    }
                }
                // Keep holding during replay so newer physical events cannot overtake this batch.
                self.pending = current
                return keys.filter { key in
                    guard swallowedKeyUps.contains(key.code) else { return true }
                    if key.down { return false }
                    swallowedKeyUps.removeFirst()
                    return false
                }
            }
            guard let keys else { return }
            for key in keys { injection.replay(key) }
        }
    }

    private func toggleEnabled() {
        settings.enabled.toggle()
        reset()
        notifyChange()
    }

    private func notifyChange() {
        DispatchQueue.main.async { self.onChange?() }
    }

    /// Remember the user's choice for a word. Never under Secure Input or in ignored apps.
    private func learn(_ word: String, always: Bool) {
        guard !IsSecureEventInputEnabled(), !settings.ignores(frontmostBundleID) else { return }
        corrector.learn(word, always: always)
        save()
    }

    private func save() {
        guard let pair = layouts.pair else { return }
        settings.setAlwaysWords(corrector.always, for: pair)
        settings.setIgnoredWords(corrector.ignored, for: pair)
    }

    func resetLearning() {
        settings.resetLearning()
        corrector.always = []
        corrector.ignored = []
        notifyChange()
    }

    func undoLastFix() {
        guard let fix = lastFix, fix.canUndo, settings.enabled, !IsSecureEventInputEnabled(),
              !settings.ignores(frontmostBundleID),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == fix.pid,
              safeFocusForInjection() else { reset(); return }
        Typist.backspaces(fix.fixed.count + 1)
        selectLayout(fix.original)
        Typist.type(fix.typed)
        Typist.tap(fix.boundary)
        for w in fix.words { learn(w, always: false) }
        reset()
        notifyChange()
    }

    func manualConvert() {
        guard settings.enabled, !IsSecureEventInputEnabled(),
              !settings.ignores(frontmostBundleID), safeFocusForInjection() else { reset(); return }
        if canUndo {
            undoLastFix()
        } else if !buffer.isEmpty {
            convertBuffer()
        } else if let word = lastWord {
            convertLastWord(word)
        } else {
            convertSelection()
        }
    }

    private func text(_ strokes: [Stroke], in lang: Lang) -> String {
        guard let table = layouts.tables[lang] else { return "" }
        return strokes.compactMap { table.char(for: $0) }.joined()
    }

    private func otherText(_ strokes: [Stroke], from lang: Lang) -> String {
        guard let target = layouts.other(lang) else { return "" }
        return text(strokes, in: target)
    }

    private func convertBuffer() {
        guard let lang = layouts.currentLang(), let target = layouts.other(lang) else { return }
        let strokes = buffer
        if corrector.decide(strokes, current: lang, afterFix: afterFix) == nil,
           let w = corrector.learnableWord(strokes, current: lang) {
            learn(w, always: true)
        }
        Typist.backspaces(strokes.count)
        selectLayout(target)
        Typist.type(otherText(strokes, from: lang))
        reset()
    }

    private func convertLastWord(_ word: Word) {
        guard let target = layouts.other(word.lang) else { return }
        run = []
        var learned: String?
        if !word.manual {
            if corrector.decide(word.strokes, current: word.lang) == nil,
               let w = corrector.learnableWord(word.strokes, current: word.lang) {
                learn(w, always: true)
                learned = w
            }
        } else if let w = word.learned {
            corrector.always.remove(w.lowercased())
            save()
        }
        Typist.backspaces(word.strokes.count + 1)
        selectLayout(target)
        Typist.type(otherText(word.strokes, from: word.lang))
        Typist.tap(word.boundary)
        lastWord = Word(strokes: word.strokes, lang: target, boundary: word.boundary,
                        manual: true, learned: learned)
    }

    /// Copy the selection, convert it, paste it back, then restore the user's clipboard.
    private func convertSelection() {
        guard layouts.isComplete, !pasting, let app = NSWorkspace.shared.frontmostApplication,
              let focus = Self.focusedElement(in: app.processIdentifier), !Self.isSecure(focus) else { return }
        let version = contextVersion
        let sameFocus = {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier &&
            Self.focusedElement(in: app.processIdentifier).map { CFEqual($0, focus) } == true &&
            self.contextVersion == version && self.settings.enabled && !IsSecureEventInputEnabled() &&
            !self.settings.ignores(self.frontmostBundleID) && !Self.isSecure(focus)
        }
        let pb = NSPasteboard.general
        let before = pb.changeCount
        let saved: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { d[t] = item.data(forType: t) }
            return d
        }
        pasting = true
        Typist.tap(Self.asciiKeyCode("c", fallback: 8), flags: .maskCommand)

        func copiedOrWait(_ attempts: Int) {
            if pb.changeCount == before && attempts < 34 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { copiedOrWait(attempts + 1) }
                return
            }
            guard sameFocus(), pb.changeCount != before else {
                if pb.changeCount != before { Self.restore(saved, to: pb) }
                self.pasting = false
                return
            }
            let copied = pb.changeCount
            guard let text = pb.string(forType: .string), !text.isEmpty else {
                if pb.changeCount == copied { Self.restore(saved, to: pb) }
                self.pasting = false
                return
            }
            let converted = self.corrector.convertText(text, from: self.layouts.currentLang())
            guard sameFocus(), pb.changeCount == copied else {
                if pb.changeCount == copied { Self.restore(saved, to: pb) }
                self.pasting = false
                return
            }
            pb.clearContents()
            pb.setString(converted, forType: .string)
            // Ask clipboard managers not to record this temporary text.
            pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
            let ours = pb.changeCount
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                let focusUnchanged = sameFocus()
                guard pb.changeCount == ours else {
                    self.pasting = false
                    return
                }
                guard focusUnchanged else {
                    Self.restore(saved, to: pb)
                    self.pasting = false
                    return
                }
                Typist.tap(Self.asciiKeyCode("v", fallback: 9), flags: .maskCommand)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    if pb.changeCount == ours { Self.restore(saved, to: pb) }
                    self.pasting = false
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { copiedOrWait(1) }
    }

    private func safeFocusForInjection() -> Bool {
        guard let app = environment.frontmost() else { return false }
        return safeFocus(pid: bufferFocus?.pid ?? app.pid,
                         recorded: bufferFocus?.element, compareFocus: bufferFocus != nil)
    }

    private func safeFocus(pid: pid_t, recorded: CFTypeRef?, compareFocus: Bool) -> Bool {
        guard let app = environment.frontmost(), app.pid == pid else { return false }
        let result = environment.focus(pid)
        if case .failed = result { return false }
        if case let .element(element) = result, Self.isSecure(element) { return false }
        return !compareFocus || Self.sameFocus(pid: pid, recorded: recorded, currentPID: app.pid, current: result)
    }

    static func sameFocus(pid: pid_t, recorded: CFTypeRef?, currentPID: pid_t, current: Focus) -> Bool {
        guard pid == currentPID else { return false }
        switch current {
        case .failed: return false
        case .unknown: return recorded == nil
        case let .element(element): return recorded.map { CFEqual($0, element) } ?? false
        }
    }

    static func bufferExpired(since previous: UInt64?, at current: UInt64) -> Bool {
        guard let previous, current >= previous else { return false }
        return current - previous > 10_000_000_000
    }

    private static func isSecure(_ element: CFTypeRef) -> Bool {
        guard CFGetTypeID(element) == AXUIElementGetTypeID() else { return false }
        let axElement = unsafeBitCast(element, to: AXUIElement.self)
        for attribute in [kAXSubroleAttribute, kAXRoleAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(axElement, attribute as CFString, &value) == .success,
               let role = value as? String, role == "AXSecureTextField" { return true }
        }
        return false
    }

    private static func asciiKeyCode(_ character: String, fallback: UInt16) -> UInt16 {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let table = LayoutTable(source: source), let stroke = table.stroke(for: character),
              !stroke.shift && !stroke.option && !stroke.caps else { return fallback }
        return stroke.keyCode
    }

    enum Focus {
        case element(CFTypeRef)
        case unknown
        case failed
    }

    private static func focus(in pid: pid_t) -> Focus {
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid),
                                             kAXFocusedUIElementAttribute as CFString, &value) {
        case .success:
            if let value { return .element(value) }
            return .unknown
        case .noValue, .attributeUnsupported, .notImplemented:
            return .unknown
        default:
            return .failed
        }
    }

    private static func focusedElement(in pid: pid_t) -> CFTypeRef? {
        guard case let .element(element) = focus(in: pid) else { return nil }
        return element
    }

    private static func restore(_ saved: [[NSPasteboard.PasteboardType: Data]], to pb: NSPasteboard) {
        pb.clearContents()
        let items = saved.map { d -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (t, data) in d { item.setData(data, forType: t) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
    }
}
