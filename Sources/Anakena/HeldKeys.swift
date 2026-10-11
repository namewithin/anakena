import CoreGraphics
import Foundation

/// Physical events retained in memory only while synthetic typing is in progress.
struct HeldKey: Equatable {
    let code: UInt16
    let flags: CGEventFlags
    let down: Bool
    let autorepeat: Int64
    let timestamp: UInt64

    init(code: UInt16, flags: CGEventFlags, down: Bool, autorepeat: Int64 = 0, timestamp: UInt64 = 0) {
        self.code = code
        self.flags = flags
        self.down = down
        self.autorepeat = autorepeat
        self.timestamp = timestamp
    }

    init(_ event: CGEvent, down: Bool) {
        self.init(code: UInt16(event.getIntegerValueField(.keyboardEventKeycode)), flags: event.flags,
                  down: down, autorepeat: event.getIntegerValueField(.keyboardEventAutorepeat),
                  timestamp: event.timestamp)
    }

    func event() -> CGEvent? {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { return nil }
        event.flags = flags
        event.timestamp = timestamp
        event.setIntegerValueField(.keyboardEventAutorepeat, value: autorepeat)
        return event
    }
}

struct HeldKeys {
    static let limit = 64
    static let maxAge: TimeInterval = 1

    let started: TimeInterval
    private(set) var keys: [HeldKey] = []
    private var count = 0
    private var discarded = false

    /// Overflow drops the whole stream, including this event; never retain more than the cap.
    mutating func append(_ key: HeldKey, at now: TimeInterval) -> Bool {
        guard !discarded, count < Self.limit, now - started < Self.maxAge else {
            discard()
            return false
        }
        count += 1
        keys.append(key)
        return true
    }

    mutating func discard() {
        keys = []
        discarded = true
    }

    mutating func take(at now: TimeInterval, sameFocus: Bool) -> [HeldKey]? {
        guard !discarded, sameFocus, now - started < Self.maxAge else {
            discard()
            return nil
        }
        let result = keys
        keys = []
        return result
    }
}
