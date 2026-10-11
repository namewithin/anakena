import Foundation

enum MenuText {
    static func enabled(_ bundle: Bundle = .main) -> String {
        NSLocalizedString("Enabled", bundle: bundle, comment: "Status-bar menu")
    }

    static func automatic(_ bundle: Bundle = .main) -> String {
        NSLocalizedString("Automatic", bundle: bundle, comment: "Status-bar menu")
    }

    static func manualOnly(_ bundle: Bundle = .main) -> String {
        NSLocalizedString("Manual only", bundle: bundle, comment: "Status-bar menu")
    }

    static func languages(_ bundle: Bundle = .main) -> String {
        NSLocalizedString("Languages", bundle: bundle, comment: "Status-bar menu")
    }

    static func last(_ text: String, _ bundle: Bundle = .main) -> String {
        String(format: NSLocalizedString("Last: %@", bundle: bundle, comment: "Status-bar menu"), text)
    }

    static func undoLast(_ bundle: Bundle = .main) -> String {
        NSLocalizedString("Undo last fix (⌃⌥Space)", bundle: bundle, comment: "Status-bar menu")
    }

    static func learned(always: Int, ignored: Int, _ bundle: Bundle = .main) -> String {
        String(format: NSLocalizedString("Learned: %ld always, %ld ignored", bundle: bundle, comment: "Status-bar menu"), always, ignored)
    }

    static func resetLearning(_ bundle: Bundle = .main) -> String {
        NSLocalizedString("Reset learning", bundle: bundle, comment: "Status-bar menu")
    }

    static func ignoreIn(_ app: String, _ bundle: Bundle = .main) -> String {
        String(format: NSLocalizedString("Ignore in %@", bundle: bundle, comment: "Status-bar menu"), app)
    }

    static func launchAtLogin(_ bundle: Bundle = .main) -> String {
        NSLocalizedString("Launch at login", bundle: bundle, comment: "Status-bar menu")
    }

    static func missingLayouts(_ bundle: Bundle = .main) -> String {
        NSLocalizedString("⚠︎ Add keyboard layouts for two languages in System Settings → Keyboard", bundle: bundle, comment: "Status-bar menu")
    }

    static func missingDictionary(_ languages: String, _ bundle: Bundle = .main) -> String {
        String(format: NSLocalizedString("⚠︎ No %@ spell-check dictionary", bundle: bundle, comment: "Status-bar menu"), languages)
    }

    static func grantAccess(_ bundle: Bundle = .main) -> String {
        NSLocalizedString("⚠︎ Grant access…", bundle: bundle, comment: "Status-bar menu")
    }

    static func needInputMonitoring(_ bundle: Bundle = .main) -> String {
        NSLocalizedString("⚠︎ Input Monitoring needed…", bundle: bundle, comment: "Status-bar menu")
    }

    static func secureInput(_ bundle: Bundle = .main) -> String {
        NSLocalizedString("⚠︎ Secure Input is on — keys are hidden (log out and back in)", bundle: bundle, comment: "Status-bar menu")
    }

    static func accessGranted(_ bundle: Bundle = .main) -> String {
        NSLocalizedString("✓ Access granted", bundle: bundle, comment: "Status-bar menu")
    }

    static func quit(_ bundle: Bundle = .main) -> String {
        NSLocalizedString("Quit", bundle: bundle, comment: "Status-bar menu")
    }
}
