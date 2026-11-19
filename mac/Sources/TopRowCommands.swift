import AppKit
import ApplicationServices

struct SystemShortcut: Equatable {
    let key: UInt16
    let flags: CGEventFlags

    // IDs and factory bindings from Keyboard Settings' DefaultShortcutsTable.xml.
    enum Action: String { case spotlight = "64", doNotDisturb = "175" }

    static func configured(_ action: Action) -> Self? {
        let entries = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString,
                                                "com.apple.symbolichotkeys" as CFString) as? [String: Any]
        return Self(action, entry: entries?[action.rawValue])
    }

    init?(_ action: Action, entry: Any?) {
        // A missing preference uses the system default. Respect explicit
        // overrides, including disabled or unassigned bindings.
        if entry == nil {
            guard action == .spotlight else { return nil }
            key = 49
            flags = .maskCommand
            return
        }
        guard let entry = entry as? [String: Any], entry["enabled"] as? Bool == true,
              let value = entry["value"] as? [String: Any], value["type"] as? String == "standard",
              let parts = value["parameters"] as? [Int], parts.count == 3,
              (0..<127).contains(parts[1]), !(54...63).contains(parts[1]), parts[2] >= 0 else { return nil }
        let allowed: CGEventFlags = [.maskCommand, .maskControl, .maskShift, .maskAlternate, .maskSecondaryFn, .maskNumericPad]
        let flags = CGEventFlags(rawValue: UInt64(parts[2]))
        guard flags.isSubset(of: allowed) else { return nil }
        self.key = UInt16(parts[1])
        self.flags = flags
    }

    func events(source: CGEventSource?) -> (down: CGEvent, up: CGEvent)? {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return nil }
        down.flags = flags
        up.flags = flags
        return (down, up)
    }
}

enum DictationMenu {
    private static let appKit = Bundle(for: NSMenu.self)
    private static let editTitles: Set<String> = [
        "Edit", "편집", appKit.localizedString(forKey: "Edit", value: nil, table: "Document")
    ]
    private static let startTitles: Set<String> = [
        "Start Dictation", "Start Dictation…", "받아쓰기 시작", "받아쓰기 시작…",
        appKit.localizedString(forKey: "Start Dictation", value: nil, table: "DictationManager"),
        appKit.localizedString(forKey: "Start Dictation…", value: nil, table: "DictationManager")
    ]

    static func matches(title: String?, identifier: String?, enabled: Bool, hidden: Bool) -> Bool {
        guard enabled, !hidden, let title, startTitles.contains(title) else { return false }
        // Native AppKit uses the menu identifier startDictation:. Some AX
        // implementations omit it. In that case require the exact start title
        // under Edit, a unique actionable AXMenuItem and the same front app.
        return identifier == nil || identifier == "" || identifier == "startDictation:"
    }

    static func startInFrontApplication() -> Bool {
        guard AXIsProcessTrusted(), let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let item = startItem(in: AXUIElementCreateApplication(pid)),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        AXUIElementSetMessagingTimeout(item, 0.25)
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    private static func startItem(in app: AXUIElement) -> AXUIElement? {
        // This path runs on a user keypress. An unresponsive app must not
        // block the input watchdog or delay later key releases.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.18
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.04)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value
        }
        func children(_ element: AXUIElement) -> [AXUIElement] {
            attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        }
        guard let bar = attribute(app, kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() else { return nil }
        let editItems = children(bar as! AXUIElement).filter {
            editTitles.contains(attribute($0, kAXTitleAttribute) as? String ?? "")
        }
        guard editItems.count == 1, let menu = children(editItems[0]).first,
              attribute(menu, kAXRoleAttribute) as? String == kAXMenuRole else { return nil }
        var match: AXUIElement?
        for item in children(menu) {
            guard let title = attribute(item, kAXTitleAttribute) as? String, startTitles.contains(title),
                  attribute(item, kAXRoleAttribute) as? String == kAXMenuItemRole,
                  matches(title: title, identifier: attribute(item, kAXIdentifierAttribute) as? String,
                          enabled: attribute(item, kAXEnabledAttribute) as? Bool == true,
                          hidden: attribute(item, kAXHiddenAttribute) as? Bool == true) else { continue }
            var names: CFArray?
            guard AXUIElementCopyActionNames(item, &names) == .success,
                  (names as? [String])?.contains(kAXPressAction) == true else { continue }
            guard match == nil else { return nil }
            match = item
        }
        return ProcessInfo.processInfo.systemUptime < deadline ? match : nil
    }
}
