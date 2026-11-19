import ApplicationServices
import AppKit
import Foundation
import IOKit.hidsystem

final class QuartzOutput {
    private let source = CGEventSource(stateID: .privateState)
    private let display: CGDirectDisplayID
    private let notice: (String) -> Void
    private var nextCheck: UInt64 = 0
    private var cachedBounds: CGRect?

    init(display: CGDirectDisplayID, notice: @escaping (String) -> Void = { _ in }) {
        self.display = display
        self.notice = notice
    }

    func bounds() -> CGRect? {
        let now = DispatchTime.now().uptimeNanoseconds
        if now >= nextCheck {
            cachedBounds = CGDisplayIsActive(display) != 0 ? CGDisplayBounds(display) : nil
            nextCheck = now + 250_000_000
        }
        return cachedBounds
    }

    static func toggleCapsLock() -> Bool? {
        guard AXIsProcessTrusted() else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = IO_OBJECT_NULL
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connection) == KERN_SUCCESS
        else { return nil }
        defer { IOServiceClose(connection) }
        var state = false
        let selector = Int32(kIOHIDCapsLockState)
        guard IOHIDGetModifierLockState(connection, selector, &state) == KERN_SUCCESS,
              IOHIDSetModifierLockState(connection, selector, !state) == KERN_SUCCESS else { return nil }
        return !state
    }

    func event(for input: MacEvent, flags: InputFlags) -> CGEvent? {
        let event: CGEvent?
        switch input {
        case .desktop: return nil
        case let .auxiliary(key, down, repeated):
            let state = Int(down ? NX_KEYDOWN : NX_KEYUP) << 8
            let modifiers = NSEvent.ModifierFlags(rawValue: UInt(flags.rawValue) | UInt(state))
            let payload = (Int(key) << 16) | state | (repeated ? 1 : 0)
            return NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: modifiers,
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                      subtype: Int16(NX_SUBTYPE_AUX_CONTROL_BUTTONS), data1: payload, data2: -1)?.cgEvent
        case let .keyboard(code, down, modifier, repeated):
            event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            if modifier { event?.type = .flagsChanged }
            if repeated { event?.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        case let .pointer(action, id, point, clicks):
            let button: CGMouseButton = id == 3 ? .right : id == 2 ? .center : .left
            let type: CGEventType
            switch action {
            case .move: type = .mouseMoved
            case .drag: type = id == 1 ? .leftMouseDragged : id == 3 ? .rightMouseDragged : .otherMouseDragged
            case .down: type = id == 1 ? .leftMouseDown : id == 3 ? .rightMouseDown : .otherMouseDown
            case .up:   type = id == 1 ? .leftMouseUp : id == 3 ? .rightMouseUp : .otherMouseUp
            }
            event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
            event?.setIntegerValueField(.mouseEventClickState, value: clicks)
        case let .wheel(point, vertical, horizontal):
            event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2,
                            wheel1: vertical, wheel2: horizontal, wheel3: 0)
            event?.location = point
        }
        event?.flags = CGEventFlags(rawValue: flags.rawValue)
        return event
    }

    func post(_ input: MacEvent, flags: InputFlags) {
        if case .desktop(let action) = input {
            if case .unavailable(let name) = action {
                notice("\(name) 전용 키는 이 앱에서 지원하지 않습니다.")
            } else if let url = action.applicationURL {
                // Launch Services addresses the built-in system app even if its shortcut was reassigned.
                NSWorkspace.shared.openApplication(at: url, configuration: .init()) { [notice] _, error in
                    if error != nil { DispatchQueue.main.async { notice("\(url.deletingPathExtension().lastPathComponent)을 열 수 없습니다.") } }
                }
            }
            return
        }
        event(for: input, flags: flags)?.post(tap: .cghidEventTap)
    }

    func perform(_ command: TopRowCommand) -> Bool {
        switch command {
        case .dictation:
            return DictationMenu.startInFrontApplication()
        case .spotlight, .doNotDisturb:
            let action: SystemShortcut.Action = command == .spotlight ? .spotlight : .doNotDisturb
            guard let pair = SystemShortcut.configured(action)?.events(source: source) else { return false }
            pair.down.post(tap: .cghidEventTap)
            pair.up.post(tap: .cghidEventTap)
            return true
        }
    }
}
