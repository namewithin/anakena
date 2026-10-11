import AppKit
import XCTest
@testable import Anakena

final class HeldKeysTests: XCTestCase {
    func testStreamRoundTripsDownUpAndAutorepeatInOrder() throws {
        let stream = [HeldKey(code: 35, flags: [.maskShift], down: true, timestamp: 1),
                      HeldKey(code: 35, flags: [.maskShift], down: true, autorepeat: 1, timestamp: 2),
                      HeldKey(code: 35, flags: [], down: false, timestamp: 3),
                      HeldKey(code: 0, flags: [.maskAlternate], down: true, timestamp: 4),
                      HeldKey(code: 0, flags: [.maskAlternate], down: false, timestamp: 5)]
        var held = HeldKeys(started: 10)
        for key in stream {
            let event = try XCTUnwrap(key.event())
            XCTAssertTrue(held.append(HeldKey(event, down: event.type == .keyDown), at: 10.1))
        }
        XCTAssertEqual(held.take(at: 10.2, sameFocus: true), stream)
        XCTAssertEqual(held.take(at: 10.3, sameFocus: true), [])
    }

    func testCountAndAgeLimitsDropTheWholeStream() {
        let key = HeldKey(code: 0, flags: [], down: true)
        var held = HeldKeys(started: 10)
        for _ in 0..<HeldKeys.limit { XCTAssertTrue(held.append(key, at: 10.1)) }
        XCTAssertFalse(held.append(key, at: 10.2))
        XCTAssertTrue(held.keys.isEmpty)
        XCTAssertNil(held.take(at: 10.3, sameFocus: true))

        var old = HeldKeys(started: 10)
        XCTAssertTrue(old.append(key, at: 10.1))
        XCTAssertNil(old.take(at: 11, sameFocus: true))
        XCTAssertFalse(old.append(key, at: 11.1))
        XCTAssertTrue(old.keys.isEmpty)
    }

    func testDrainingDoesNotRestartTheCap() {
        let key = HeldKey(code: 0, flags: [], down: true)
        var held = HeldKeys(started: 10)
        for _ in 0..<HeldKeys.limit { XCTAssertTrue(held.append(key, at: 10.1)) }
        XCTAssertEqual(held.take(at: 10.2, sameFocus: true)?.count, HeldKeys.limit)
        XCTAssertFalse(held.append(key, at: 10.3))
        XCTAssertNil(held.take(at: 10.4, sameFocus: true))
    }

    func testReleaseRejectsChangedPIDOrFocusAndFailedQueries() {
        let field = "field" as CFString
        for (pid, recorded, current, allowed) in [
            (100, field, Engine.Focus.element("field" as CFString), true),
            (101, field, .element(field), false),
            (100, field, .element("other" as CFString), false),
            (100, field, .unknown, false),
            (100, field, .failed, false),
        ] {
            let same = Engine.sameFocus(pid: 100, recorded: recorded, currentPID: pid_t(pid), current: current)
            XCTAssertEqual(same, allowed)
            var held = HeldKeys(started: 10)
            XCTAssertTrue(held.append(HeldKey(code: 0, flags: [], down: true), at: 10))
            XCTAssertEqual(held.take(at: 10.1, sameFocus: same) != nil, allowed)
            XCTAssertTrue(held.keys.isEmpty)
        }
        XCTAssertTrue(Engine.sameFocus(pid: 100, recorded: nil, currentPID: 100, current: .unknown))
        XCTAssertFalse(Engine.sameFocus(pid: 100, recorded: nil, currentPID: 100, current: .failed))
        XCTAssertFalse(Engine.sameFocus(pid: 100, recorded: nil, currentPID: 100, current: .element(field)))
    }

    private final class WordSpeller: Speller {
        var lookups = 0
        func isCorrect(_ word: String, in lang: Lang) -> Bool {
            XCTAssertTrue(Thread.isMainThread, "Spell decisions must stay on main")
            if word != "test" { lookups += 1 }
            return word == (lang == .en ? "hello" : "привіт")
        }
    }

    private final class Sink: InjectionSink {
        enum Call: Equatable {
            case replace(String, String, UInt16, CGEventFlags)
            case replay(HeldKey)
        }
        private let lock = NSLock()
        private var recorded: [Call] = []
        var onReplace: (() -> Void)?
        var beforeTyping: (() -> Void)?
        var calls: [Call] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }
        private func record(_ call: Call) {
            XCTAssertFalse(Thread.isMainThread, "Synthetic events must stay off main")
            lock.lock()
            recorded.append(call)
            lock.unlock()
        }
        func replace(typed: String, with fixed: String, boundary: UInt16, flags: CGEventFlags,
                     selectLayout: () -> Void, proceed: () -> Bool) {
            guard proceed() else { return }
            selectLayout()
            beforeTyping?()
            guard proceed() else { return }
            guard proceed() else { return }
            record(.replace(typed, fixed, boundary, flags))
            onReplace?()
        }
        func replay(_ key: HeldKey) { record(.replay(key)) }
    }

    private final class Fixture {
        let layouts = LayoutSet(ids: [.en: "com.apple.keylayout.ABC", .uk: "com.apple.keylayout.Ukrainian-PC"])
        let queue = DispatchQueue(label: "AnakenaTests.injection")
        let speller = WordSpeller()
        let sink = Sink()
        let suite = UUID().uuidString
        let defaults: UserDefaults
        let settings: Settings
        var pid: pid_t = 100
        var focus: Engine.Focus = .element("field" as CFString)
        var lang: Lang = .en
        var secure = false
        var bundle = "com.apple.TextEdit"
        var engine: Engine!

        init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            settings = Settings(defaults: defaults)
            guard layouts.tables[.en] != nil, layouts.tables[.uk] != nil else {
                throw XCTSkip("EN/UK keyboard layouts unavailable")
            }
            var environment = Engine.Environment(layouts: layouts)
            environment.frontmost = { [unowned self] in (self.pid, self.bundle) }
            environment.focus = { [unowned self] _ in self.focus }
            environment.secureInput = { [unowned self] in self.secure }
            environment.currentLang = { [unowned self] in self.lang }
            environment.selectLayout = { [unowned self] in self.lang = $0 }
            engine = Engine(settings: settings, layouts: layouts, speller: speller, injection: sink,
                            environment: environment, injectionQueue: queue)
            engine.frontmostBundleID = bundle
        }

        deinit { defaults.removePersistentDomain(forName: suite) }

        @discardableResult
        func key(_ code: UInt16, down: Bool = true, flags: CGEventFlags = []) throws -> Bool {
            let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down))
            event.flags = flags
            return engine.handle(type: down ? .keyDown : .keyUp, event: event)
        }

        func word(_ text: String) throws {
            for char in text {
                let stroke = try XCTUnwrap(layouts.tables[lang]?.stroke(for: String(char)))
                XCTAssertFalse(try key(stroke.keyCode, flags: stroke.shift ? .maskShift : []))
                XCTAssertFalse(try key(stroke.keyCode, down: false))
            }
        }

        func mouseDown() throws {
            let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                             mouseCursorPosition: .zero, mouseButton: .left))
            XCTAssertFalse(engine.handle(type: .leftMouseDown, event: event))
        }
    }

    private func drain(_ fixture: Fixture) {
        let drained = expectation(description: "decision and injection finished")
        DispatchQueue.main.async {
            fixture.queue.async { DispatchQueue.main.async { drained.fulfill() } }
        }
        wait(for: [drained], timeout: 3)
    }

    private func startBlockedFix(_ fixture: Fixture) throws -> DispatchSemaphore {
        let started = expectation(description: "injection started off main")
        let proceed = DispatchSemaphore(value: 0)
        fixture.sink.onReplace = {
            started.fulfill()
            XCTAssertEqual(proceed.wait(timeout: .now() + 5), .success)
        }
        try fixture.word("ghbdsn")
        XCTAssertEqual(fixture.speller.lookups, 0)
        XCTAssertFalse(try fixture.key(49, flags: .maskShift))
        XCTAssertEqual(fixture.speller.lookups, 0, "The callback must return before spelling")
        XCTAssertTrue(fixture.sink.calls.isEmpty)
        wait(for: [started], timeout: 3)
        return proceed
    }

    func testCorrectWordHasNoSyntheticEvents() throws {
        let fixture = try Fixture()
        try fixture.word("hello")
        XCTAssertFalse(try fixture.key(49))
        XCTAssertFalse(try fixture.key(49, down: false))
        XCTAssertEqual(fixture.speller.lookups, 0)
        drain(fixture)
        XCTAssertGreaterThan(fixture.speller.lookups, 0)
        XCTAssertTrue(fixture.sink.calls.isEmpty)
    }

    func testKeyDownBetweenBoundaryAndDecisionAbortsWithoutEvents() throws {
        let fixture = try Fixture()
        try fixture.word("ghbdsn")
        XCTAssertFalse(try fixture.key(49))
        XCTAssertFalse(try fixture.key(0))
        drain(fixture)
        XCTAssertTrue(fixture.sink.calls.isEmpty)
        XCTAssertFalse(fixture.engine.canUndo)
    }

    func testKeyDownAfterDecisionBeforeInjectionAbortsWithoutEvents() throws {
        let fixture = try Fixture()
        let proceed = DispatchSemaphore(value: 0)
        fixture.queue.async { _ = proceed.wait(timeout: .now() + 3) }
        defer { proceed.signal() }
        try fixture.word("ghbdsn")
        XCTAssertFalse(try fixture.key(49))
        let decided = expectation(description: "decision finished before worker starts")
        DispatchQueue.main.async { decided.fulfill() }
        wait(for: [decided], timeout: 2)
        XCTAssertGreaterThan(fixture.speller.lookups, 0)
        XCTAssertFalse(try fixture.key(0), "No holding while injection is only queued")
        proceed.signal()
        drain(fixture)
        XCTAssertTrue(fixture.sink.calls.isEmpty)
    }

    func testOwnMouseDownAlsoInvalidatesDecision() throws {
        let fixture = try Fixture()
        fixture.engine.isOwnClick = { _ in true }
        try fixture.word("ghbdsn")
        XCTAssertFalse(try fixture.key(49))
        let click = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                         mouseCursorPosition: .zero, mouseButton: .left))
        XCTAssertFalse(fixture.engine.handle(type: .leftMouseDown, event: click))
        drain(fixture)
        XCTAssertTrue(fixture.sink.calls.isEmpty)
    }

    func testKeyUpDoesNotInvalidateDecisionAndFixKeepsUndo() throws {
        let fixture = try Fixture()
        try fixture.word("ghbdsn")
        XCTAssertFalse(try fixture.key(49, flags: .maskShift))
        XCTAssertFalse(try fixture.key(49, down: false))
        drain(fixture)
        XCTAssertEqual(fixture.sink.calls, [.replace("ghbdsn", "привіт", 49, .maskShift)])
        XCTAssertTrue(fixture.engine.canUndo)
        XCTAssertEqual(fixture.engine.lastFixText, "ghbdsn → привіт")
        XCTAssertFalse(try fixture.key(49, down: false))
        XCTAssertTrue(fixture.engine.canUndo, "A keyUp must never enter typing logic")
    }

    func testHeldStreamReplaysExactlyAndBuffersTheNextWord() throws {
        let fixture = try Fixture()
        let proceed = try startBlockedFix(fixture)
        defer { proceed.signal() }
        let timestamp = try XCTUnwrap(CGEvent(source: nil)).timestamp
        let codes: [UInt16] = [4, 14, 37, 31] // hello, with one repeated L
        var stream: [HeldKey] = []
        for code in codes {
            stream.append(HeldKey(code: code, flags: [], down: true, timestamp: timestamp))
            if code == 37 { stream.append(HeldKey(code: code, flags: [], down: true, autorepeat: 1, timestamp: timestamp)) }
            stream.append(HeldKey(code: code, flags: [], down: false, timestamp: timestamp))
        }
        for key in stream {
            let event = try XCTUnwrap(key.event())
            XCTAssertTrue(fixture.engine.handle(type: key.down ? .keyDown : .keyUp, event: event))
        }
        proceed.signal()
        drain(fixture)
        XCTAssertEqual(fixture.sink.calls, [.replace("ghbdsn", "привіт", 49, .maskShift)] + stream.map(Sink.Call.replay))
        fixture.sink.onReplace = nil
        XCTAssertFalse(try fixture.key(49))
        drain(fixture)
        XCTAssertEqual(fixture.sink.calls.last, .replace("руддщ", "hello", 49, []))
    }

    func testHeldConvertHotkeyIsNotReplayedButLetterIs() throws {
        let fixture = try Fixture()
        let proceed = try startBlockedFix(fixture)
        defer { proceed.signal() }
        let timestamp = try XCTUnwrap(CGEvent(source: nil)).timestamp
        let stream = [HeldKey(code: 49, flags: [.maskControl, .maskAlternate], down: true, timestamp: timestamp),
                      HeldKey(code: 0, flags: [], down: true, timestamp: timestamp),
                      HeldKey(code: 49, flags: [.maskControl, .maskAlternate], down: false, timestamp: timestamp),
                      HeldKey(code: 0, flags: [], down: false, timestamp: timestamp)]
        for key in stream {
            let event = try XCTUnwrap(key.event())
            XCTAssertTrue(fixture.engine.handle(type: key.down ? .keyDown : .keyUp, event: event))
        }
        proceed.signal()
        drain(fixture)
        XCTAssertEqual(fixture.sink.calls, [.replace("ghbdsn", "привіт", 49, .maskShift),
                                            .replay(stream[1]), .replay(stream[3])])
    }

    func testCapDropsHeldEventsAndResetsWithoutReplay() throws {
        let fixture = try Fixture()
        let proceed = try startBlockedFix(fixture)
        defer { proceed.signal() }
        for _ in 0...HeldKeys.limit { XCTAssertTrue(try fixture.key(0)) }
        proceed.signal()
        drain(fixture)
        XCTAssertEqual(fixture.sink.calls.count, 1)
        XCTAssertFalse(fixture.engine.canUndo)
        XCTAssertNil(fixture.engine.lastFixText)
        XCTAssertFalse(try fixture.key(49))
        drain(fixture)
        XCTAssertEqual(fixture.sink.calls.count, 1)
    }

    func testFocusChangeDuringInjectionDropsHeldEvents() throws {
        let fixture = try Fixture()
        let proceed = try startBlockedFix(fixture)
        defer { proceed.signal() }
        XCTAssertTrue(try fixture.key(0))
        XCTAssertTrue(try fixture.key(0, down: false))
        fixture.focus = .element("different field" as CFString)
        proceed.signal()
        drain(fixture)
        XCTAssertEqual(fixture.sink.calls.count, 1)
        XCTAssertFalse(fixture.engine.canUndo)
        XCTAssertNil(fixture.engine.lastFixText)
    }

    func testResetAndTapTimeoutDuringInjectionNeverReplayHeldEvents() throws {
        for timeout in [false, true] {
            let fixture = try Fixture()
            let proceed = try startBlockedFix(fixture)
            defer { proceed.signal() }
            XCTAssertTrue(try fixture.key(0))
            if timeout {
                let event = try XCTUnwrap(CGEvent(source: nil))
                XCTAssertFalse(fixture.engine.handle(type: .tapDisabledByTimeout, event: event))
            } else {
                fixture.engine.reset()
            }
            XCTAssertFalse(try fixture.key(0, down: false))
            proceed.signal()
            drain(fixture)
            XCTAssertEqual(fixture.sink.calls.count, 1)
            XCTAssertFalse(fixture.engine.canUndo)
            XCTAssertNil(fixture.engine.lastFixText)
        }
    }

    func testOneSecondTimerDropsHeldEventsAndResets() throws {
        let fixture = try Fixture()
        let proceed = try startBlockedFix(fixture)
        defer { proceed.signal() }
        XCTAssertTrue(try fixture.key(0))
        let expired = expectation(description: "one second hold expired")
        DispatchQueue.main.asyncAfter(deadline: .now() + HeldKeys.maxAge + 0.05) { expired.fulfill() }
        wait(for: [expired], timeout: 2)
        XCTAssertFalse(try fixture.key(0), "Timed-out pending keys must pass through")
        proceed.signal()
        drain(fixture)
        XCTAssertEqual(fixture.sink.calls.count, 1)
        XCTAssertFalse(fixture.engine.canUndo)
        XCTAssertNil(fixture.engine.lastFixText)
    }

    func testMouseDownOrFocusChangeBetweenInjectionPhasesStopsWithoutReplay() throws {
        let changes: [(Fixture) throws -> Void] = [
            { (fixture: Fixture) in try fixture.mouseDown() },
            { (fixture: Fixture) in fixture.focus = .element("different field" as CFString) },
        ]
        for change in changes {
            let fixture = try Fixture()
            fixture.sink.beforeTyping = {
                DispatchQueue.main.sync {
                    do {
                        XCTAssertTrue(try fixture.key(0))
                        try change(fixture)
                    } catch {
                        XCTFail("Could not change injection context: \(error)")
                    }
                }
            }
            try fixture.word("ghbdsn")
            XCTAssertFalse(try fixture.key(49))
            drain(fixture)
            XCTAssertTrue(fixture.sink.calls.isEmpty)
            XCTAssertFalse(fixture.engine.canUndo)
        }
    }

    func testUnsafeContextBeforeDecisionHasNoSyntheticEvents() throws {
        for change in [
            { (f: Fixture) in f.pid += 1 },
            { (f: Fixture) in f.focus = .failed },
            { (f: Fixture) in f.focus = .unknown },
            { (f: Fixture) in f.focus = .element("different field" as CFString) },
            { (f: Fixture) in f.secure = true },
            { (f: Fixture) in f.settings.enabled = false },
            { (f: Fixture) in f.bundle = "com.apple.Terminal" },
        ] {
            let fixture = try Fixture()
            try fixture.word("ghbdsn")
            XCTAssertFalse(try fixture.key(49))
            change(fixture)
            drain(fixture)
            XCTAssertTrue(fixture.sink.calls.isEmpty)
        }
    }
}
