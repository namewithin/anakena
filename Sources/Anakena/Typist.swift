import CoreGraphics
import Foundation

/// Posts synthetic key events. Every event carries `magic`, so our own tap ignores it.
enum Typist {
    static let magic: Int64 = 0x524F4E47 // "RONG"
    private static let source: CGEventSource? = {
        let s = CGEventSource(stateID: .privateState)
        s?.userData = magic
        return s
    }()

    static let backspace: CGKeyCode = 51

    private static func post(_ code: CGKeyCode, down: Bool, flags: CGEventFlags,
                             autorepeat: Int64 = 0, unicode: [UniChar]? = nil) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        e.flags = flags
        e.setIntegerValueField(.eventSourceUserData, value: magic)
        e.setIntegerValueField(.keyboardEventAutorepeat, value: autorepeat)
        if let unicode { e.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: unicode) }
        e.post(tap: .cgSessionEventTap)
    }

    static func tap(_ code: CGKeyCode, flags: CGEventFlags = []) {
        post(code, down: true, flags: flags)
        post(code, down: false, flags: flags)
    }

    static func replay(_ key: HeldKey) {
        post(key.code, down: key.down, flags: key.flags, autorepeat: key.autorepeat)
    }

    static func backspaces(_ n: Int) {
        for _ in 0..<n { tap(backspace) }
    }

    static func type(_ text: String) {
        for ch in text {
            let u = Array(String(ch).utf16)
            post(0, down: true, flags: [], unicode: u)
            post(0, down: false, flags: [], unicode: u)
            usleep(800)
        }
    }
}
