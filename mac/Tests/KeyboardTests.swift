import AppKit
import Carbon
import IOKit.hidsystem

@main struct KeyboardTests {
    static func key(_ sink: InputSink, _ usage: UInt8, _ action: UInt8) {
        precondition(sink.apply([4, usage, action, 0, 0, 0, 0, 0][...]))
    }

    static func modifiers() {
        let output = QuartzOutput(display: CGMainDisplayID())
        var events = [CGEvent]()
        let sink = InputSink(bounds: { CGRect(x: 0, y: 0, width: 16, height: 16) }, caps: false) {
            events.append(output.event(for: $0, flags: $1)!)
        }
        for (left, right, rightVK, generic, leftMask, rightMask): (UInt8, UInt8, Int64, CGEventFlags, Int32, Int32) in [
            (224, 227, 54, .maskCommand, NX_DEVICELCMDKEYMASK, NX_DEVICERCMDKEYMASK),
            (231, 228, 62, .maskControl, NX_DEVICELCTLKEYMASK, NX_DEVICERCTLKEYMASK),
            (225, 229, 60, .maskShift, NX_DEVICELSHIFTKEYMASK, NX_DEVICERSHIFTKEYMASK),
            (226, 230, 61, .maskAlternate, NX_DEVICELALTKEYMASK, NX_DEVICERALTKEYMASK)
        ] {
            key(sink, left, 1)
            key(sink, right, 1)
            precondition(events.last!.type == .flagsChanged)
            precondition(events.last!.getIntegerValueField(.keyboardEventKeycode) == rightVK)
            precondition(events.last!.flags.rawValue == generic.rawValue | UInt64(leftMask | rightMask))
            key(sink, left, 0)
            key(sink, 4, 1)
            precondition(events.last!.type == .keyDown)
            precondition(events.last!.flags.rawValue == generic.rawValue | UInt64(rightMask))
            let count = events.count
            key(sink, right, 2)
            precondition(events.count == count)
            precondition(sink.apply([1,0,0,0,0,0,0,0][...]))
            precondition(events.last!.flags.rawValue == generic.rawValue | UInt64(rightMask))
            sink.release()
            precondition(events.last!.type == .flagsChanged && events.last!.flags.isEmpty)
        }
        print("PASS Quartz flagsChanged, side masks, chords, pointer flags and disconnect release")
    }

    static func gestures() {
        var now: TimeInterval = 10
        var behavior = CapsBehavior.language(holdToUnlock: false)
        var locked = false
        var toggles = 0
        var switches = [SourceSwitch]()
        var events = [(MacEvent, InputFlags)]()
        let sink = InputSink(bounds: { .zero }, caps: false, capsBehavior: { behavior },
            switchSource: { switches.append($0) }, toggleSystemCaps: {
                locked.toggle()
                toggles += 1
                return locked
            }, uptime: { now }) { events.append(($0, $1)) }
        key(sink, 228, 1)
        for action: UInt8 in [1, 2, 0, 1, 1, 2] { key(sink, 144, action) }
        precondition(switches == [.hangul, .hangul, .hangul] && events.count == 1)
        key(sink, 228, 0)
        key(sink, 57, 1)
        key(sink, 57, 1)
        key(sink, 57, 2)
        now += 0.1
        key(sink, 57, 0)
        key(sink, 57, 0)
        precondition(switches.last == .caps && switches.count == 4 && toggles == 0)
        key(sink, 57, 1)
        now += InputSink.capsHoldTime + 0.01
        key(sink, 4, 1)
        precondition(events.last!.1.contains(.caps) && locked)
        key(sink, 57, 0)
        precondition(toggles == 1 && switches.count == 4)
        key(sink, 57, 1)
        key(sink, 57, 0)
        precondition(!locked && toggles == 2 && switches.count == 4)
        key(sink, 57, 1)
        sink.release()
        key(sink, 57, 0)
        precondition(toggles == 2 && switches.count == 4)
        behavior = .lock
        key(sink, 57, 1)
        key(sink, 57, 2)
        key(sink, 57, 0)
        precondition(locked && toggles == 3 && switches.count == 4)

        // Exercise the real main-queue timer with a fake HID lock, including release cancellation.
        behavior = .language(holdToUnlock: true)
        key(sink, 57, 1)
        RunLoop.main.run(until: Date().addingTimeInterval(InputSink.capsHoldTime + 0.1))
        precondition(!locked && toggles == 4)
        key(sink, 57, 0)
        key(sink, 57, 1)
        sink.release()
        RunLoop.main.run(until: Date().addingTimeInterval(InputSink.capsHoldTime + 0.1))
        precondition(toggles == 4 && switches.count == 4)
        print("PASS Hangul/F9 pulses and repeats, Caps tap/hold/unlock/normal and cancellation")
    }

    static func functionRow() {
        let map = Dictionary(uniqueKeysWithValues: FunctionRow.macBook.enumerated().map { ($0.offset, $0.element) })
        let row = FunctionRow(hardware: map)
        let expected: [FunctionKeyTarget] = [
            .auxiliary(NX_KEYTYPE_BRIGHTNESS_DOWN), .auxiliary(NX_KEYTYPE_BRIGHTNESS_UP),
            .desktop(.missionControl), .preferred(.spotlight), .preferred(.dictation),
            .preferred(.doNotDisturb), .auxiliary(NX_KEYTYPE_REWIND),
            .auxiliary(NX_KEYTYPE_PLAY), .auxiliary(NX_KEYTYPE_FAST), .auxiliary(NX_KEYTYPE_MUTE),
            .auxiliary(NX_KEYTYPE_SOUND_DOWN), .auxiliary(NX_KEYTYPE_SOUND_UP)
        ]
        let standard: [UInt16] = [122,120,99,118,96,97,98,100,101,109,103,111]
        for i in standard.indices {
            precondition(row.target(index: i, forced: false, mode: .system, systemStandard: false) == expected[i])
            precondition(row.target(index: i, forced: false, mode: .system, systemStandard: true) == .standard(standard[i]))
            precondition(row.target(index: i, forced: true, mode: .standard, systemStandard: true) == expected[i])
        }
        precondition(Bundle(url: DesktopAction.missionControl.applicationURL!)?.bundleIdentifier == "com.apple.exposelauncher")
        let quartz = QuartzOutput(display: CGMainDisplayID())
        var events = [MacEvent]()
        var lastAux: NSEvent?
        var standardMode = false
        let sink = InputSink(bounds: { .zero }, caps: false, functionTarget: { index, forced in
            row.target(index: index, forced: forced, mode: .system, systemStandard: standardMode)
        }) { event, flags in
            events.append(event)
            if case .auxiliary = event { lastAux = quartz.event(for: event, flags: flags).flatMap(NSEvent.init(cgEvent:)) }
        }
        for index in standard.indices {
            let usage = UInt8(58 + index)
            events.removeAll()
            key(sink, usage, 1)
            switch expected[index] {
            case .auxiliary(let code):
                precondition(events == [.auxiliary(code, down: true, repeated: false)])
                precondition(lastAux?.type == .systemDefined && lastAux?.subtype.rawValue == Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS))
                precondition(lastAux?.data1 == Int(code) << 16 | Int(NX_KEYDOWN) << 8)
                key(sink, usage, 2)
                let repeats = code != NX_KEYTYPE_PLAY && code != NX_KEYTYPE_MUTE
                precondition(events.count == (repeats ? 2 : 1))
                if repeats { precondition(lastAux!.data1 & 1 == 1) }
                key(sink, usage, 0)
                precondition(lastAux?.data1 == Int(code) << 16 | Int(NX_KEYUP) << 8)
            case .desktop(let action):
                key(sink, usage, 2)
                key(sink, usage, 0)
                precondition(events == [.desktop(action)])
            case .preferred(let command):
                key(sink, usage, 2)
                key(sink, usage, 0)
                precondition(events == [.keyboard(command.fallback, down: true, modifier: false, repeated: false),
                                        .keyboard(command.fallback, down: true, modifier: false, repeated: true),
                                        .keyboard(command.fallback, down: false, modifier: false, repeated: false)])
            case .standard: preconditionFailure()
            }
            standardMode = true
            events.removeAll()
            key(sink, usage, 1)
            key(sink, usage, 0)
            precondition(events == [.keyboard(standard[index], down: true, modifier: false, repeated: false),
                                    .keyboard(standard[index], down: false, modifier: false, repeated: false)])
            events.removeAll()
            key(sink, UInt8(240 + index), 1)
            sink.release()
            if case .auxiliary(let code) = expected[index] {
                precondition(events == [.auxiliary(code, down: true, repeated: false), .auxiliary(code, down: false, repeated: false)])
            }
            standardMode = false
        }
        // One physical action through both wire forms. Release the original
        // target even if the user changes the preference before releasing.
        events.removeAll()
        key(sink, 65, 1)
        standardMode = true
        key(sink, 247, 1)
        key(sink, 65, 0)
        sink.release()
        precondition(events == [.auxiliary(NX_KEYTYPE_PLAY, down: true, repeated: false),
                                .auxiliary(NX_KEYTYPE_PLAY, down: false, repeated: false)])
        print("PASS F1–F12 standard/system/forced routing, auxiliary payloads, system app targets and release")
    }

    static func specialCommands() {
        let flags: CGEventFlags = [.maskCommand, .maskAlternate]
        func binding(_ enabled: Bool, _ key: Int, _ modifiers: Int, type: String = "standard") -> [String: Any] {
            ["enabled": enabled, "value": ["type": type, "parameters": [65535, key, modifiers]]]
        }
        let custom = SystemShortcut(.spotlight, entry: binding(true, 101, Int(flags.rawValue)))!
        let factory = SystemShortcut(.spotlight, entry: nil)!
        precondition(factory.key == 49 && factory.flags == .maskCommand)
        precondition(SystemShortcut(.doNotDisturb, entry: nil) == nil)
        precondition(SystemShortcut(.spotlight, entry: binding(false, 49, Int(CGEventFlags.maskCommand.rawValue))) == nil)
        let pair = custom.events(source: nil)!
        precondition(pair.down.type == .keyDown && pair.up.type == .keyUp)
        for e in [pair.down, pair.up] {
            precondition(e.getIntegerValueField(.keyboardEventKeycode) == 101 && e.flags == flags)
        }
        for invalid: Any? in [nil, binding(false, 101, 0), binding(true, 65535, 0),
                              binding(true, 56, 0), binding(true, 1, -1), binding(true, 1, 1),
                              binding(true, 3, 0, type: "other")] {
            precondition(SystemShortcut(.doNotDisturb, entry: invalid) == nil)
        }
        precondition(DictationMenu.matches(title: "받아쓰기 시작…", identifier: "startDictation:", enabled: true, hidden: false))
        precondition(DictationMenu.matches(title: "Start Dictation", identifier: nil, enabled: true, hidden: false))
        precondition(!DictationMenu.matches(title: "Stop Dictation", identifier: "startDictation:", enabled: true, hidden: false))
        precondition(!DictationMenu.matches(title: "Start Dictation", identifier: "other", enabled: true, hidden: false))
        precondition(!DictationMenu.matches(title: "Start Dictation", identifier: nil, enabled: false, hidden: false))
        precondition(!DictationMenu.matches(title: "Start Dictation", identifier: nil, enabled: true, hidden: true))

        // Simulate success and failure; the test never invokes AXPress or posts a system shortcut.
        var calls = [TopRowCommand]()
        var events = [(MacEvent, InputFlags)]()
        var available = true
        var standard = false
        let row = FunctionRow(hardware: [:])
        let sink = InputSink(bounds: { .zero }, caps: false, functionTarget: { index, forced in
            row.target(index: index, forced: forced, mode: standard ? .standard : .macBook, systemStandard: false)
        }, performCommand: { command in calls.append(command); return available }) { events.append(($0, $1)) }
        for (ordinary, forced, command): (UInt8, UInt8, TopRowCommand) in [(61, 243, .spotlight), (62, 244, .dictation), (63, 245, .doNotDisturb)] {
            calls.removeAll()
            events.removeAll()
            standard = false
            available = true
            key(sink, ordinary, 1)
            key(sink, forced, 1)
            key(sink, ordinary, 2)
            key(sink, ordinary, 0)
            sink.release()
            precondition(calls == [command] && events.isEmpty)

            // The two wire forms can converge on the same fallback key. Keep
            // it held until the last release, even if the mode changes.
            available = false
            key(sink, forced, 1)
            standard = true
            key(sink, ordinary, 1)
            key(sink, forced, 0)
            precondition(events.map { $0.0 } == [.keyboard(command.fallback, down: true, modifier: false, repeated: false)])
            sink.release()
            precondition(events.last!.0 == .keyboard(command.fallback, down: false, modifier: false, repeated: false))
            precondition(calls == [command, command])

            available = true
            standard = false
            key(sink, 227, 1)
            key(sink, ordinary, 1)
            precondition(events.last!.0 == .keyboard(command.fallback, down: true, modifier: false, repeated: false))
            precondition(events.last!.1 == .sided(.maskCommand, NX_DEVICERCMDKEYMASK) && calls.count == 2)
            sink.release()
        }
        print("PASS F4 Spotlight shortcuts, F5 menu matching, F6 hotkeys, single dispatch and held standard fallback")
    }

    enum LiveError: Error { case noCurrentSource, missingPair, selection(String), unchanged, restoreFailed }

    static func observe(_ matches: (KeyboardSources.Source) -> Bool) -> Bool {
        let limit = Date().addingTimeInterval(1)
        repeat {
            if let current = KeyboardSources.current(), matches(current) { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        } while Date() < limit
        return false
    }

    // Explicit live test. No application activation and no Quartz/HID events.
    static func roundTrip() throws {
        _ = NSApplication.shared
        guard let original = KeyboardSources.current() else { throw LiveError.noCurrentSource }
        let available = KeyboardSources.enabled()
        guard available.contains(where: { $0.korean && !$0.ascii }),
              available.contains(where: { $0.ascii && !$0.korean }) else { throw LiveError.missingPair }
        let sources = KeyboardSources()
        print("Eligible sources: " + available.map(\.id).joined(separator: ", "))
        let behavior = sources.capsBehavior()
        print("Caps behavior: \(behavior)")
        var selected = 0
        var selectionError: String?
        let sink = InputSink(bounds: { .zero }, caps: false, capsBehavior: { behavior },
                             switchSource: { intent in
            selected += 1
            selectionError = sources.select(intent)
        }, emit: { _, _ in })
        var problem: Error?
        do {
            for (index, wantKorean) in [!original.korean, original.korean].enumerated() {
                // Return via a Caps tap on a Mac with the language switch enabled.
                let usage: UInt8 = index == 1 && behavior != .lock ? 57 : 144
                for action: UInt8 in [1, 2, 0] { key(sink, usage, action) }
                if let error = selectionError { throw LiveError.selection(error) }
                guard selected == index + 1 else { throw LiveError.unchanged }
                guard observe({ $0.korean == wantKorean }) else { throw LiveError.unchanged }
            }
        } catch { problem = error }
        // Restore even if either selection or verification failed.
        if KeyboardSources.current()?.id != original.id {
            guard TISSelectInputSource(original.ref) == noErr else { throw LiveError.restoreFailed }
        }
        guard observe({ $0.id == original.id }) else { throw LiveError.restoreFailed }
        if let problem { throw problem }
        print("PASS real TIS Korean/Latin round trip; original source restored")
    }

    static func main() throws {
        if CommandLine.arguments.dropFirst().contains("--inventory") {
            let row = FunctionRow.internalKeyboard()
            print("Internal F-row: \(row.hardware.count) positions; standard by default: \(FunctionRow.standardByDefault)")
            print((0..<12).map { String(describing: row.target(index: $0, forced: false, mode: .system, systemStandard: FunctionRow.standardByDefault)) }.joined(separator: ", "))
            return
        }
        if CommandLine.arguments.dropFirst().contains("--round-trip") { try roundTrip(); return }
        modifiers()
        gestures()
        functionRow()
        specialCommands()
    }
}
