import Foundation
import IOKit.hidsystem

enum FunctionRowMode: String, CaseIterable {
    case system, macBook, standard

    var label: String {
        switch self {
        case .system: return "Mac 시스템 설정 따르기"
        case .macBook: return "MacBook 상단 기능"
        case .standard: return "표준 F1–F12"
        }
    }
}

enum DesktopAction: Hashable {
    case missionControl, unavailable(String)

    var applicationURL: URL? {
        switch self {
        case .missionControl: return URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        case .unavailable: return nil
        }
    }
}

enum FunctionKeyTarget: Hashable {
    case standard(UInt16)
    case auxiliary(Int32)
    case desktop(DesktopAction)
    case preferred(TopRowCommand)
}

enum TopRowCommand: Hashable {
    case spotlight, dictation, doNotDisturb
    var fallback: UInt16 {
        switch self {
        case .spotlight: return 118
        case .dictation: return 96
        case .doNotDisturb: return 97
        }
    }
}

struct FunctionRow {
    // USB keyboard page 0x07, F1 through F12. The targets below are the
    // FnFunctionUsageMap reported by the M4 MacBook Air internal keyboard.
    static let macBook: [UInt32] = [
        0x00ff0005, 0x00ff0004, 0xff010010, 0x000c0221, 0x000c00cf, 0x0001009b,
        0x000c00b4, 0x000c00cd, 0x000c00b3, 0x000c00e2, 0x000c00ea, 0x000c00e9
    ]
    private static let virtualKeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
    let hardware: [Int: UInt32]

    static func internalKeyboard() -> FunctionRow {
        var iterator: io_iterator_t = IO_OBJECT_NULL
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleHIDKeyboardEventDriverV2"),
                                           &iterator) == KERN_SUCCESS else { return FunctionRow(hardware: [:]) }
        defer { IOObjectRelease(iterator) }
        while true {
            let device = IOIteratorNext(iterator)
            guard device != IO_OBJECT_NULL else { return FunctionRow(hardware: [:]) }
            defer { IOObjectRelease(device) }
            func property(_ key: String) -> AnyObject? {
                IORegistryEntryCreateCFProperty(device, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let product = property("Product") as? String, product.hasPrefix("Apple Internal Keyboard"),
                  let mapping = property("FnFunctionUsageMap") as? String else { continue }
            let fields = mapping.split(separator: ",").map {
                UInt32($0.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "0x", with: ""), radix: 16)
            }
            var targets = [Int: UInt32]()
            for index in stride(from: 0, to: fields.count - 1, by: 2) {
                if let source = fields[index], (0x0007003a...0x00070045).contains(source), let target = fields[index + 1] {
                    targets[Int(source - 0x0007003a)] = target
                }
            }
            if !targets.isEmpty { return FunctionRow(hardware: targets) }
        }
    }

    static var standardByDefault: Bool {
        UserDefaults.standard.bool(forKey: "com.apple.keyboard.fnState")
    }

    func target(index: Int, forced: Bool, mode: FunctionRowMode, systemStandard: Bool) -> FunctionKeyTarget {
        precondition(Self.virtualKeys.indices.contains(index))
        if !forced && (mode == .standard || (mode == .system && systemStandard)) {
            return .standard(Self.virtualKeys[index])
        }
        let usage: UInt32
        if forced || mode == .macBook {
            usage = Self.macBook[index]
        } else if let reported = hardware[index] {
            usage = reported
        } else {
            // No model-specific icon was reported (for example, a desktop Mac).
            return .standard(Self.virtualKeys[index])
        }
        switch usage {
        case 0x00ff0005: return .auxiliary(NX_KEYTYPE_BRIGHTNESS_DOWN)
        case 0x00ff0004: return .auxiliary(NX_KEYTYPE_BRIGHTNESS_UP)
        case 0xff010010: return .desktop(.missionControl)
        case 0x000c0221: return .preferred(.spotlight)
        case 0x000c00cf: return .preferred(.dictation)
        case 0x0001009b: return .preferred(.doNotDisturb)
        case 0x000c00b4: return .auxiliary(NX_KEYTYPE_REWIND)
        case 0x000c00cd: return .auxiliary(NX_KEYTYPE_PLAY)
        case 0x000c00b3: return .auxiliary(NX_KEYTYPE_FAST)
        case 0x000c00e2: return .auxiliary(NX_KEYTYPE_MUTE)
        case 0x000c00ea: return .auxiliary(NX_KEYTYPE_SOUND_DOWN)
        case 0x000c00e9: return .auxiliary(NX_KEYTYPE_SOUND_UP)
        default: return .desktop(.unavailable("F\(index + 1) 상단 기능"))
        }
    }
}
