import Foundation

// SDL scancodes follow USB HID usages. Values are Quartz virtual key codes.
private let keys: [UInt8: UInt16] = [
    4:0, 5:11, 6:8, 7:2, 8:14, 9:3, 10:5, 11:4, 12:34, 13:38, 14:40,
    15:37, 16:46, 17:45, 18:31, 19:35, 20:12, 21:15, 22:1, 23:17,
    24:32, 25:9, 26:13, 27:7, 28:16, 29:6,
    30:18, 31:19, 32:20, 33:21, 34:23, 35:22, 36:26, 37:28, 38:25, 39:29,
    40:36, 41:53, 42:51, 43:48, 44:49, 45:27, 46:24, 47:33, 48:30,
    49:42, 50:42, 51:41, 52:39, 53:50, 54:43, 55:47, 56:44, 57:57,
    58:122, 59:120, 60:99, 61:118, 62:96, 63:97, 64:98, 65:100, 66:101,
    67:109, 68:103, 69:111, 73:114, 74:115, 75:116, 76:117, 77:119, 78:121,
    79:124, 80:123, 81:125, 82:126, 83:71, 84:75, 85:67, 86:78, 87:69,
    88:76, 89:83, 90:84, 91:85, 92:86, 93:87, 94:88, 95:89, 96:91,
    97:92, 98:82, 99:65, 100:10,
    224:55, 225:56, 226:58, 227:54, 228:62, 229:60, 230:61, 231:59
]
struct InputFlags: OptionSet {
    let rawValue: UInt8
    static let command = Self(rawValue: 1)
    static let shift = Self(rawValue: 2)
    static let option = Self(rawValue: 4)
    static let control = Self(rawValue: 8)
    static let caps = Self(rawValue: 16)
}
enum PointerAction { case move, drag, down, up }
enum MacEvent: Equatable {
    case keyboard(UInt16, down: Bool, modifier: Bool, repeated: Bool)
    case pointer(PointerAction, button: UInt8, at: CGPoint, clicks: Int64)
    case wheel(at: CGPoint, vertical: Int32, horizontal: Int32)
}
private let modifiers: [UInt16: InputFlags] = [
    55:.command, 54:.command, 56:.shift, 60:.shift,
    58:.option, 61:.option, 59:.control, 62:.control
]

final class InputSink {
    private let displayBounds: () -> CGRect?
    private let emit: (MacEvent, InputFlags) -> Void
    private var held = Set<UInt16>()
    private var buttons = [UInt8]()
    private var last = CGPoint.zero
    private var caps: Bool
    private var clicks = [UInt8: Int64]()

    init(bounds: @escaping () -> CGRect?, caps: Bool, emit: @escaping (MacEvent, InputFlags) -> Void) {
        self.displayBounds = bounds
        self.caps = caps
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
            if code == 57 { caps.toggle() }
        } else if !held.contains(code) { return }
        emit(.keyboard(code, down: action != 0, modifier: modifiers[code] != nil || code == 57,
                       repeated: action == 2), flags)
    }

    private func mouse(_ id: UInt8, _ action: PointerAction) {
        emit(.pointer(action, button: id, at: last, clicks: clicks[id] ?? 1), flags)
    }

    private func up(_ id: UInt8) {
        guard buttons.contains(id) else { return }
        mouse(id, .up)
        buttons.removeAll { $0 == id }
        clicks.removeValue(forKey: id)
    }

    func release() {
        for id in Array(buttons.reversed()) { up(id) }
        for code in held.sorted(by: { (modifiers[$0] == nil ? 0 : 1) < (modifiers[$1] == nil ? 0 : 1) }) {
            keyboard(code, 0)
        }
    }

    func apply(_ p: ArraySlice<UInt8>) -> Bool {
        guard p.count == 8, let bounds = displayBounds() else { return false }
        let i = p.startIndex, kind = p[i], code = p[i+1], action = p[i+2]
        if kind == 0 { return true }
        if kind == 4 {
            guard action <= 2 else { return false }
            if code == 144 { // Hangul or F9: macOS "Select the previous input source"
                if action == 1 && held.isEmpty {
                    keyboard(59, 1); keyboard(49, 1); keyboard(49, 0); keyboard(59, 0)
                }
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
