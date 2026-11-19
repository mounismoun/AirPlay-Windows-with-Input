import ApplicationServices
import Foundation

final class QuartzOutput {
    private let source = CGEventSource(stateID: .privateState)
    private let display: CGDirectDisplayID
    private var nextCheck: UInt64 = 0
    private var cachedBounds: CGRect?

    init(display: CGDirectDisplayID) { self.display = display }

    func bounds() -> CGRect? {
        let now = DispatchTime.now().uptimeNanoseconds
        if now >= nextCheck {
            cachedBounds = CGDisplayIsActive(display) != 0 ? CGDisplayBounds(display) : nil
            nextCheck = now + 250_000_000
        }
        return cachedBounds
    }

    func post(_ input: MacEvent, flags: InputFlags) {
        let event: CGEvent?
        switch input {
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
        var quartzFlags = CGEventFlags()
        if flags.contains(.command) { quartzFlags.insert(.maskCommand) }
        if flags.contains(.shift) { quartzFlags.insert(.maskShift) }
        if flags.contains(.option) { quartzFlags.insert(.maskAlternate) }
        if flags.contains(.control) { quartzFlags.insert(.maskControl) }
        if flags.contains(.caps) { quartzFlags.insert(.maskAlphaShift) }
        event?.flags = quartzFlags
        event?.post(tap: .cghidEventTap)
    }
}
