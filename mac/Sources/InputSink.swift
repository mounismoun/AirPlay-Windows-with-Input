import CoreGraphics
import Foundation
import IOKit.hidsystem

// SDL scancodes follow USB HID usages. Values are Quartz virtual key codes.
private let keys: [UInt8: UInt16] = [
    4:0, 5:11, 6:8, 7:2, 8:14, 9:3, 10:5, 11:4, 12:34, 13:38, 14:40,
    15:37, 16:46, 17:45, 18:31, 19:35, 20:12, 21:15, 22:1, 23:17,
    24:32, 25:9, 26:13, 27:7, 28:16, 29:6,
    30:18, 31:19, 32:20, 33:21, 34:23, 35:22, 36:26, 37:28, 38:25, 39:29,
    40:36, 41:53, 42:51, 43:48, 44:49, 45:27, 46:24, 47:33, 48:30,
    49:42, 50:42, 51:41, 52:39, 53:50, 54:43, 55:47, 56:44, 57:57,
    73:114, 74:115, 75:116, 76:117, 77:119, 78:121,
    79:124, 80:123, 81:125, 82:126, 83:71, 84:75, 85:67, 86:78, 87:69,
    88:76, 89:83, 90:84, 91:85, 92:86, 93:87, 94:88, 95:89, 96:91,
    97:92, 98:82, 99:65, 100:10,
    224:55, 225:56, 226:58, 227:54, 228:62, 229:60, 230:61, 231:59
]

struct InputFlags: OptionSet {
    let rawValue: UInt64
    static let caps = Self(rawValue: CGEventFlags.maskAlphaShift.rawValue)

    static func sided(_ family: CGEventFlags, _ side: Int32) -> Self {
        Self(rawValue: family.rawValue | UInt64(side))
    }
}
enum SourceSwitch { case hangul, caps }
enum CapsBehavior: Equatable { case lock, language(holdToUnlock: Bool) }
enum PointerAction { case move, drag, down, up }
enum MacEvent: Equatable {
    case keyboard(UInt16, down: Bool, modifier: Bool, repeated: Bool)
    case auxiliary(Int32, down: Bool, repeated: Bool)
    case desktop(DesktopAction)
    case pointer(PointerAction, button: UInt8, at: CGPoint, clicks: Int64)
    case wheel(at: CGPoint, vertical: Int32, horizontal: Int32)
}
private let modifiers: [UInt16: InputFlags] = [
    55:.sided(.maskCommand, NX_DEVICELCMDKEYMASK), 54:.sided(.maskCommand, NX_DEVICERCMDKEYMASK),
    56:.sided(.maskShift, NX_DEVICELSHIFTKEYMASK), 60:.sided(.maskShift, NX_DEVICERSHIFTKEYMASK),
    58:.sided(.maskAlternate, NX_DEVICELALTKEYMASK), 61:.sided(.maskAlternate, NX_DEVICERALTKEYMASK),
    59:.sided(.maskControl, NX_DEVICELCTLKEYMASK), 62:.sided(.maskControl, NX_DEVICERCTLKEYMASK)
]

final class InputSink {
    private let displayBounds: () -> CGRect?
    private let emit: (MacEvent, InputFlags) -> Void
    private var held = Set<UInt16>()
    private var buttons = [UInt8]()
    private var last = CGPoint.zero
    private var caps: Bool
    private let capsBehavior: () -> CapsBehavior
    private let switchSource: (SourceSwitch) -> Void
    private let toggleSystemCaps: () -> Bool?
    private let functionTarget: (Int, Bool) -> FunctionKeyTarget
    private let performCommand: (TopRowCommand) -> Bool
    private var heldFunctionKeys = [UInt8: (requested: FunctionKeyTarget, output: FunctionKeyTarget)]()
    private let uptime: () -> TimeInterval
    private var capsDown = false
    private var capsDeadline: TimeInterval?
    private var capsTimer: DispatchWorkItem?
    static let capsHoldTime: TimeInterval = 0.4
    private var clicks = [UInt8: Int64]()

    init(bounds: @escaping () -> CGRect?, caps: Bool,
         capsBehavior: @escaping () -> CapsBehavior = { .lock },
         switchSource: @escaping (SourceSwitch) -> Void = { _ in },
         toggleSystemCaps: @escaping () -> Bool? = { nil },
         functionTarget: @escaping (Int, Bool) -> FunctionKeyTarget = {
             FunctionRow(hardware: [:]).target(index: $0, forced: $1, mode: .standard, systemStandard: true)
         },
         performCommand: @escaping (TopRowCommand) -> Bool = { _ in false },
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         emit: @escaping (MacEvent, InputFlags) -> Void) {
        self.displayBounds = bounds
        self.caps = caps
        self.capsBehavior = capsBehavior
        self.switchSource = switchSource
        self.toggleSystemCaps = toggleSystemCaps
        self.functionTarget = functionTarget
        self.performCommand = performCommand
        self.uptime = uptime
        self.emit = emit
    }

    private var flags: InputFlags {
        held.reduce(into: caps ? InputFlags.caps : []) {
            if let flag = modifiers[$1] { $0.formUnion(flag) }
        }
    }

    private func keyboard(_ code: UInt16, _ action: UInt8) {
        if action == 0 {
            guard held.remove(code) != nil else { return }
        } else if action == 1 {
            guard held.insert(code).inserted else { return }
        } else if !held.contains(code) || modifiers[code] != nil { return }
        emit(.keyboard(code, down: action != 0, modifier: modifiers[code] != nil,
                       repeated: action == 2), flags)
    }

    private func cancelCapsHold() {
        capsTimer?.cancel()
        capsTimer = nil
        capsDeadline = nil
    }

    private func toggleCaps() {
        if let systemState = toggleSystemCaps() {
            caps = systemState
        } else {
            // Preserve Caps on remote events if the HID system cannot set the hardware lock.
            caps.toggle()
            emit(.keyboard(57, down: caps, modifier: true, repeated: false), flags)
        }
    }

    private func commitCapsHold() {
        guard capsDeadline != nil else { return }
        cancelCapsHold()
        toggleCaps()
    }

    private func capsKey(_ action: UInt8) {
        if action == 1 && !capsDown {
            capsDown = true
            guard case .language(let holdToUnlock) = capsBehavior(), !caps || holdToUnlock else {
                toggleCaps()
                return
            }
            capsDeadline = uptime() + Self.capsHoldTime
            let timer = DispatchWorkItem { [weak self] in self?.commitCapsHold() }
            capsTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.capsHoldTime, execute: timer)
        } else if action == 0 && capsDown {
            capsDown = false
            if capsDeadline != nil {
                cancelCapsHold()
                switchSource(.caps)
            }
        }
    }

    private func mouse(_ id: UInt8, _ action: PointerAction) {
        emit(.pointer(action, button: id, at: last, clicks: clicks[id] ?? 1), flags)
    }

    private func functionKey(_ usage: UInt8, _ action: UInt8) {
        let target: FunctionKeyTarget
        if action == 1 {
            guard heldFunctionKeys[usage] == nil else { return }
            let forced = usage >= 240
            let requested = functionTarget(Int(usage) - (forced ? 240 : 58), forced)
            if let existing = heldFunctionKeys.values.first(where: { $0.requested == requested }) {
                heldFunctionKeys[usage] = existing
                return
            }
            // Preserve modified function keys for user and application shortcuts.
            if case .preferred(let command) = requested,
               held.contains(where: { modifiers[$0] != nil }) || !performCommand(command) {
                target = .standard(command.fallback)
            } else { target = requested }
            let alreadyDown = heldFunctionKeys.values.contains { $0.output == target }
            heldFunctionKeys[usage] = (requested, target)
            if alreadyDown { return }
        } else {
            guard let existing = heldFunctionKeys[usage] else { return }
            target = existing.output
            if action == 0 {
                heldFunctionKeys.removeValue(forKey: usage)
                if heldFunctionKeys.values.contains(where: { $0.output == target }) { return }
            }
        }
        switch target {
        case .standard(let code): keyboard(code, action)
        case .auxiliary(let key):
            if action == 2 && (key == NX_KEYTYPE_PLAY || key == NX_KEYTYPE_MUTE) { return }
            emit(.auxiliary(key, down: action != 0, repeated: action == 2), flags)
        case .desktop(let command):
            if action == 1 { emit(.desktop(command), flags) }
        case .preferred: break  // Already dispatched once on the initial down.
        }
    }

    private func up(_ id: UInt8) {
        guard buttons.contains(id) else { return }
        mouse(id, .up)
        buttons.removeAll { $0 == id }
        clicks.removeValue(forKey: id)
    }

    func release() {
        cancelCapsHold()
        capsDown = false
        for id in Array(buttons.reversed()) { up(id) }
        for usage in Array(heldFunctionKeys.keys) { functionKey(usage, 0) }
        for code in held.sorted(by: { (modifiers[$0] == nil ? 0 : 1) < (modifiers[$1] == nil ? 0 : 1) }) {
            keyboard(code, 0)
        }
    }

    func apply(_ p: ArraySlice<UInt8>) -> Bool {
        guard p.count == 8, let bounds = displayBounds() else { return false }
        // Also check the clock when multiple frames arrive in the same main-queue callback.
        if let capsDeadline, uptime() >= capsDeadline { commitCapsHold() }
        let i = p.startIndex, kind = p[i], code = p[i+1], action = p[i+2]
        if kind == 0 { return true }
        if kind == 4 {
            guard action <= 2 else { return false }
            if code == 144 {
                // Older Windows senders may omit key-up for Hangul.
                if action == 1 { switchSource(.hangul) }
            } else if code == 57 {
                capsKey(action)
            } else if (58...69).contains(code) || (240...251).contains(code) {
                functionKey(code, action)
            } else if let mapped = keys[code] { keyboard(mapped, action) }
            return true
        }
        guard (1...3).contains(kind) else { return false }
        guard bounds.width > 1 && bounds.height > 1 else { return false }
        let x = Int(p[i+4]) * 256 + Int(p[i+5]), y = Int(p[i+6]) * 256 + Int(p[i+7])
        last = CGPoint(x: bounds.minX + CGFloat(x) / 65535 * (bounds.width-1),
                       y: bounds.minY + CGFloat(y) / 65535 * (bounds.height-1))
        if kind == 1 {
            let id = buttons.last ?? 0
            mouse(id, id == 0 ? .move : .drag)
        } else if kind == 2 {
            guard (1...3).contains(code), action <= 1 else { return false }
            if action == 0 { up(code) }
            else if !buttons.contains(code) {
                clicks[code] = Int64(max(1, p[i+3]))
                buttons.append(code)
                mouse(code, .down)
            }
        } else {
            emit(.wheel(at: last, vertical: Int32(Int8(bitPattern: action)),
                        horizontal: Int32(Int8(bitPattern: code))), flags)
        }
        return true
    }
}
