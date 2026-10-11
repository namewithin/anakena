import AppKit
import ApplicationServices
import Carbon
import ServiceManagement

enum PermissionStatus: Equatable {
    case needsAccessibility
    case needsInputMonitoring
    case secureInput
    case ok
}

/// The one permission problem to show in the menu, most fundamental first.
func permissionStatus(axTrusted: Bool, tapInstalled: Bool, secureInput: Bool) -> PermissionStatus {
    if !axTrusted { return .needsAccessibility }
    if !tapInstalled { return .needsInputMonitoring }
    if secureInput { return .secureInput }
    return .ok
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings()
    private let layouts = LayoutSet()
    private lazy var engine = Engine(settings: settings, layouts: layouts)
    private lazy var tap = EventTap { [unowned self] type, event in
        self.engine.handle(type: type, event: event)
    }
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var retryTimer: Timer?
    private var askedInputMonitoring = false
    private var menuOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        if let button = statusItem.button, let icon = Self.statusIcon() {
            button.image = icon
            button.imagePosition = .imageLeading
        }

        engine.frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        engine.onChange = { [weak self] in self?.updateTitle() }
        engine.isOwnClick = { [weak self] p in self?.isOwnClick(p) ?? false }

        // Selector API: block observers get no distributed notifications while an accessory app is inactive.
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(inputSourceChanged),
                        name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
                        object: nil, suspensionBehavior: .deliverImmediately)
        dnc.addObserver(self, selector: #selector(enabledSourcesChanged),
                        name: NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
                        object: nil, suspensionBehavior: .deliverImmediately)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)

        updateTitle()

        let prompt = !settings.askedAccessibility
        settings.askedAccessibility = true
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
        tryInstallTap()
    }

    // MARK: - Event tap

    /// Retries until the user grants access, so it starts working without a relaunch.
    private func tryInstallTap() {
        if tap.install() {
            retryTimer?.invalidate()
            retryTimer = nil
            return
        }
        if AXIsProcessTrusted(), !askedInputMonitoring {
            askedInputMonitoring = true
            _ = CGRequestListenEventAccess()
        }
        if retryTimer == nil {
            retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                self?.tryInstallTap()
            }
        }
    }

    private func isOwnClick(_ cgPoint: CGPoint) -> Bool {
        guard let frame = statusItem.button?.window?.frame,
              let primary = NSScreen.screens.first else { return false }
        // Event locations are top-left based; window frames are bottom-left based.
        let p = NSPoint(x: cgPoint.x, y: primary.frame.maxY - cgPoint.y)
        return frame.contains(p) || (menuOpen && NSApp.windows.contains {
            $0.isVisible && $0.level == .popUpMenu && $0.frame.contains(p)
        })
    }

    // MARK: - Notifications

    @objc private func inputSourceChanged() {
        engine.inputSourceChanged()
        updateTitle()
    }

    @objc private func enabledSourcesChanged() {
        layouts.reload()
        engine.reloadLanguages()
        updateTitle()
    }

    @objc private func appActivated(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        engine.frontmostBundleID = app?.bundleIdentifier
        engine.reset()
    }

    /// Menu bar icon from the app bundle; nil under `swift run`, then the title is shown alone.
    private static func statusIcon() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "StatusIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        if let url2x = Bundle.main.url(forResource: "StatusIcon@2x", withExtension: "png"),
           let rep = NSImageRep(contentsOf: url2x) {
            rep.size = NSSize(width: 18, height: 18)
            image.addRepresentation(rep)
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        button.title = layouts.currentLang()?.title ?? "··"
        button.appearsDisabled = !settings.enabled
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) { menuOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateTitle()
        menu.removeAllItems()

        let enabled = item(MenuText.enabled(), #selector(toggleEnabled), key: "z")
        enabled.keyEquivalentModifierMask = [.control, .option]
        enabled.state = settings.enabled ? .on : .off
        menu.addItem(enabled)
        menu.addItem(.separator())

        let auto = item(MenuText.automatic(), #selector(setAuto))
        auto.state = settings.mode == .auto ? .on : .off
        menu.addItem(auto)
        let manual = item(MenuText.manualOnly(), #selector(setManual))
        manual.state = settings.mode == .manual ? .on : .off
        menu.addItem(manual)

        let languages = NSMenu(title: MenuText.languages())
        languages.autoenablesItems = false
        let available = NSSpellChecker.shared.availableLanguages
        let supported = layouts.languages.filter { SystemSpeller.dictionary(for: $0, available: available) != nil }
        for (index, a) in supported.enumerated() {
            for b in supported.dropFirst(index + 1) {
                let pair = LangPair(a: a, b: b)
                let choice = item(pair.title, #selector(setLanguages(_:)))
                choice.representedObject = pair
                choice.state = Set(pair.languages) == Set(layouts.pair?.languages ?? []) ? .on : .off
                languages.addItem(choice)
            }
        }
        let languageItem = NSMenuItem(title: MenuText.languages(), action: nil, keyEquivalent: "")
        languageItem.submenu = languages
        languageItem.isEnabled = !languages.items.isEmpty
        menu.addItem(languageItem)

        if let text = engine.lastFixText {
            menu.addItem(.separator())
            let last = NSMenuItem(title: MenuText.last(text), action: nil, keyEquivalent: "")
            last.isEnabled = false
            menu.addItem(last)
            let undo = item(MenuText.undoLast(), #selector(undoLast))
            undo.isEnabled = engine.canUndo
            menu.addItem(undo)
        }

        menu.addItem(.separator())
        let counts = engine.learnedCounts
        let learned = NSMenuItem(title: MenuText.learned(always: counts.always, ignored: counts.ignored), action: nil, keyEquivalent: "")
        learned.isEnabled = false
        menu.addItem(learned)
        let forget = item(MenuText.resetLearning(), #selector(resetLearning))
        forget.isEnabled = counts.always + counts.ignored > 0
        menu.addItem(forget)

        menu.addItem(.separator())
        if let app = NSWorkspace.shared.frontmostApplication,
           let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier {
            let ignore = item(MenuText.ignoreIn(app.localizedName ?? id), #selector(toggleIgnored(_:)))
            ignore.representedObject = id
            ignore.state = settings.ignores(id) ? .on : .off
            menu.addItem(ignore)
        }
        let login = item(MenuText.launchAtLogin(), #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        if !layouts.isComplete {
            let missing = NSMenuItem(title: MenuText.missingLayouts(),
                                     action: nil, keyEquivalent: "")
            missing.isEnabled = false
            menu.addItem(missing)
        }
        let missingLanguages = (layouts.pair?.languages ?? []).filter {
            SystemSpeller.dictionary(for: $0, available: available) == nil
        }.map(\.title)
        if !missingLanguages.isEmpty {
            let missing = NSMenuItem(title: MenuText.missingDictionary(missingLanguages.joined(separator: "/")),
                                     action: nil, keyEquivalent: "")
            missing.isEnabled = false
            menu.addItem(missing)
        }
        switch permissionStatus(axTrusted: AXIsProcessTrusted(), tapInstalled: tap.isInstalled,
                                secureInput: IsSecureEventInputEnabled()) {
        case .needsAccessibility:
            menu.addItem(item(MenuText.grantAccess(), #selector(openAccessibility)))
        case .needsInputMonitoring:
            menu.addItem(item(MenuText.needInputMonitoring(), #selector(openInputMonitoring)))
        case .secureInput:
            let secure = NSMenuItem(title: MenuText.secureInput(),
                                    action: nil, keyEquivalent: "")
            secure.isEnabled = false
            menu.addItem(secure)
        case .ok:
            let ok = NSMenuItem(title: MenuText.accessGranted(), action: nil, keyEquivalent: "")
            ok.isEnabled = false
            menu.addItem(ok)
        }
        menu.addItem(item(MenuText.quit(), #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func toggleEnabled() {
        settings.enabled.toggle()
        engine.reset()
        updateTitle()
    }

    @objc private func setLanguages(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? LangPair else { return }
        settings.languagePair = pair
        engine.reloadLanguages()
        updateTitle()
    }

    @objc private func setAuto() { settings.mode = .auto }
    @objc private func setManual() { settings.mode = .manual }

    @objc private func undoLast() { engine.undoLastFix() }
    @objc private func resetLearning() { engine.resetLearning() }

    @objc private func toggleIgnored(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        settings.toggleIgnored(id)
        engine.reset()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSSound.beep()
        }
    }

    @objc private func openAccessibility() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func openInputMonitoring() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
