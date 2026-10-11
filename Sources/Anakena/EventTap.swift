import CoreGraphics

/// Session-wide keyboard + mouse-down tap. Needs the Accessibility permission.
final class EventTap {
    private let handler: (CGEventType, CGEvent) -> Bool
    fileprivate var port: CFMachPort?

    var isInstalled: Bool { port != nil }

    /// `handler` returns true to swallow the event.
    init(handler: @escaping (CGEventType, CGEvent) -> Bool) {
        self.handler = handler
    }

    func install() -> Bool {
        if port != nil { return true }
        let types: [CGEventType] = [.keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        guard let source = CFMachPortCreateRunLoopSource(nil, port, 0) else {
            CFMachPortInvalidate(port)
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        return true
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        handler(type, event)
    }
}

private func tapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        _ = tap.handle(type, event)
        if let port = tap.port { CGEvent.tapEnable(tap: port, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    return tap.handle(type, event) ? nil : Unmanaged.passUnretained(event)
}
