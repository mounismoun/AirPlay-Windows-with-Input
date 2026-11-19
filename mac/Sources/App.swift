import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

final class SettingsModel: ObservableObject {
    let receiver = Receiver()
    private let store = PairingKey()
    private let keyQueue = DispatchQueue(label: "local.airplay-input.keychain")
    private var key: Data?
    private var copyCount: Int?
    private var copyExpiry: DispatchWorkItem?
    private var revealExpiry: DispatchWorkItem?
    @Published private(set) var hasKey = false
    @Published private(set) var readingKey = false
    @Published private(set) var visibleKey: String?
    @Published private(set) var keyError = ""
    @Published private(set) var copied = false
    @Published private(set) var login = SMAppService.mainApp.status
    @Published private(set) var loginError = ""
    @Published private(set) var screens: [NSScreen] = []
    @Published var display = UserDefaults.standard.integer(forKey: "display") {
        didSet {
            UserDefaults.standard.set(display, forKey: "display")
            receiver.display = display == 0 ? nil : CGDirectDisplayID(display)
        }
    }

    func start() {
        screens = NSScreen.screens
        receiver.display = display == 0 ? nil : CGDirectDisplayID(display)
        receiver.start()
        load()
    }

    func stop() {
        receiver.stop()
        hideKey()
        clearCopy()
    }

    func load() {
        updateKey(rotate: false)
    }

    func rotate() {
        updateKey(rotate: true)
    }

    private func updateKey(rotate: Bool) {
        guard !readingKey else { return }
        readingKey = true
        // Keychain may wait for the user's password or access decision after
        // an update. Keep the settings window and the input watchdog responsive.
        keyQueue.async { [store] in
            let result = Result { try rotate ? store.rotate() : store.loadOrCreate() }
            DispatchQueue.main.async {
                self.readingKey = false
                switch result {
                case .success(let key): self.setKey(key)
                case .failure(let error): self.keyError = self.keyMessage(error)
                }
            }
        }
    }

    private func keyMessage(_ error: Error) -> String {
        let status = (error as? KeychainError)?.status ?? errSecInternalError
        return L10n.format("Keychain access failed (%@). Unlock your login keychain and try again.", String(status))
    }

    private func setKey(_ newKey: Data) {
        hideKey()
        clearCopy()
        key = newKey
        hasKey = true
        keyError = ""
        receiver.changeKey(newKey)
    }

    private var hex: String? { key?.map { String(format: "%02x", $0) }.joined() }

    func hideKey() {
        revealExpiry?.cancel()
        visibleKey = nil
    }

    func reveal() {
        if visibleKey != nil { hideKey(); return }
        visibleKey = hex
        let hide = DispatchWorkItem { [weak self] in self?.hideKey() }
        revealExpiry = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: hide)
    }

    func copyKey() {
        guard let hex else { return }
        clearCopy()
        let board = NSPasteboard.general
        board.prepareForNewContents(with: .currentHostOnly)
        let item = NSPasteboardItem()
        item.setString(hex, forType: .string)
        item.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        guard board.writeObjects([item]) else { return }
        copyCount = board.changeCount
        copied = true
        let clear = DispatchWorkItem { [weak self] in self?.clearCopy() }
        copyExpiry = clear
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: clear)
    }

    private func clearCopy() {
        copyExpiry?.cancel()
        if let copyCount, NSPasteboard.general.changeCount == copyCount {
            NSPasteboard.general.clearContents()
        }
        copyCount = nil
        copied = false
    }

    func permissionSettings() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func refreshSettings() {
        screens = NSScreen.screens
        login = SMAppService.mainApp.status
    }

    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginError = ""
        } catch { loginError = L10n.format("Could not change the login item (%@).", L10n.errorCode(error)) }
        refreshSettings()
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var receiver: Receiver
    @State private var confirmRotate = false

    private var status: String {
        if receiver.paused { return L10n.text("Receiver paused") }
        if !receiver.trusted { return L10n.text("Accessibility permission required") }
        if !model.hasKey { return L10n.text("Pairing key required") }
        if !receiver.peer.isEmpty { return L10n.text("Connected to Windows") }
        if !receiver.listening.isEmpty { return L10n.text("Waiting for Windows") }
        return receiver.issue.isEmpty ? L10n.text("Waiting for a local Wi-Fi or Ethernet connection") : L10n.text("Unable to listen for connections")
    }

    var body: some View {
        Form {
            Section {
                LabeledContent(L10n.text("Receiver status")) {
                    Text(status)
                    Button(receiver.paused ? L10n.text("Resume") : L10n.text("Pause")) { receiver.togglePause() }
                }
                if !receiver.peer.isEmpty { LabeledContent(L10n.text("Connected device"), value: receiver.peer) }
                if !receiver.listening.isEmpty {
                    LabeledContent(L10n.text("LAN address · TCP 49721"), value: receiver.listening.joined(separator: "\n"))
                        .font(.callout.monospacedDigit())
                }
                if !receiver.lastSession.isEmpty { Text(receiver.lastSession).foregroundStyle(.secondary) }
                if !receiver.issue.isEmpty { Text(receiver.issue).foregroundStyle(.orange) }
                if !receiver.keyboardIssue.isEmpty { Text(receiver.keyboardIssue).foregroundStyle(.orange) }
                LabeledContent(L10n.text("Accessibility")) {
                    Text(receiver.trusted ? L10n.text("Allowed") : L10n.text("Required for keyboard and mouse input"))
                    Button(L10n.text("Open Permission Settings")) { model.permissionSettings() }
                }
                Picker(L10n.text("F1–F12 behavior"), selection: $receiver.functionRowMode) {
                    ForEach(FunctionRowMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker(L10n.text("Display to control"), selection: $model.display) {
                    Text(L10n.text("Main display (automatic)")).tag(0)
                    ForEach(model.screens, id: \.self) { screen in
                        if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                            Text(screen.localizedName + " · " + id.stringValue).tag(id.intValue)
                        }
                    }
                    if model.display != 0 && !model.screens.contains(where: {
                        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue == model.display
                    }) { Text(L10n.format("Disconnected display · %@", String(model.display))).tag(model.display) }
                }
            }
            Section {
                LabeledContent(L10n.text("Pairing key")) {
                    Button(model.visibleKey == nil ? L10n.text("Show key") : L10n.text("Hide")) { model.reveal() }
                    Button(model.copied ? L10n.text("Copied") : L10n.text("Copy")) { model.copyKey() }
                    Button(L10n.text("Replace key…")) { confirmRotate = true }
                }.disabled(!model.hasKey || model.readingKey)
                if model.readingKey {
                    Text(L10n.text("Checking the keychain. Allow access if macOS asks."))
                }
                if let key = model.visibleKey {
                    Text(verbatim: key).font(.system(.body, design: .monospaced))
                }
                if !model.keyError.isEmpty {
                    Text(model.keyError)
                    Button(L10n.text("Retry keychain access")) { model.load() }
                }
            } footer: {
                Text(L10n.text("Press F8 in the Windows mirroring window and enter the key once. Windows remembers it for future connections."))
            }
            Section {
                Toggle(L10n.text("Start AirPlay Input at login"), isOn: Binding(
                    get: { model.login == .enabled || model.login == .requiresApproval },
                    set: model.setLogin))
                if model.login == .requiresApproval {
                    Button(L10n.text("Allow the login item in System Settings")) { SMAppService.openSystemSettingsLoginItems() }
                }
                if !model.loginError.isEmpty { Text(model.loginError) }
            }
        }
        .formStyle(.grouped)
        .alert(L10n.text("Replace the pairing key?"), isPresented: $confirmRotate) {
            Button(L10n.text("Cancel"), role: .cancel) {}
            Button(L10n.text("Replace key"), role: .destructive) { model.rotate() }
        } message: { Text(L10n.text("This will end the current connection. Press F8 on Windows and enter the new key.")) }
    }
}

@main final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = SettingsModel()
    private var window: NSWindow!
    private var statusItem: NSStatusItem!

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        let view = SettingsView(model: model, receiver: model.receiver)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 490),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.minSize = NSSize(width: 490, height: 420)
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        window.title = "AirPlay Input"
        window.delegate = self
        window.center()
        let menu = NSMenu()
        menu.addItem(withTitle: L10n.text("Open AirPlay Input"), action: #selector(showWindow), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.text("Quit AirPlay Input"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let main = NSMenu()
        let appMenu = NSMenuItem()
        appMenu.submenu = menu
        main.addItem(appMenu)
        NSApp.mainMenu = main
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "AirPlay Input")
        statusItem.button?.toolTip = "AirPlay Input"
        statusItem.menu = menu.copy() as? NSMenu
        showWindow()
    }

    @objc private func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) { model.hideKey() }
    func applicationDidResignActive(_ notification: Notification) { model.hideKey() }
    func applicationDidBecomeActive(_ notification: Notification) { model.refreshSettings() }
    func applicationDidChangeScreenParameters(_ notification: Notification) { model.refreshSettings() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }
    func applicationWillTerminate(_ notification: Notification) { model.stop() }
}
