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
        return "키체인 접근 실패 (\(status)). 로그인 키체인을 잠금 해제하고 다시 시도하세요."
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
        } catch { loginError = "로그인 항목 변경 실패 · " + error.localizedDescription }
        refreshSettings()
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var receiver: Receiver
    @State private var confirmRotate = false

    private var status: String {
        if receiver.paused { return "수신 일시 정지" }
        if !receiver.trusted { return "손쉬운 사용 권한 필요" }
        if !model.hasKey { return "페어링 키 필요" }
        if !receiver.peer.isEmpty { return "Windows 연결됨" }
        if !receiver.listening.isEmpty { return "Windows 연결 대기 중" }
        return receiver.issue.isEmpty ? "로컬 Wi-Fi 또는 이더넷 연결 대기 중" : "수신 대기 실패"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("수신 상태") {
                    Text(status)
                    Button(receiver.paused ? "재개" : "일시 정지") { receiver.togglePause() }
                }
                if !receiver.peer.isEmpty { LabeledContent("연결된 기기", value: receiver.peer) }
                if !receiver.listening.isEmpty {
                    LabeledContent("LAN 주소 · TCP 49721", value: receiver.listening.joined(separator: "\n"))
                        .font(.callout.monospacedDigit())
                }
                if !receiver.lastSession.isEmpty { Text(receiver.lastSession).foregroundStyle(.secondary) }
                if !receiver.issue.isEmpty { Text(receiver.issue).foregroundStyle(.orange) }
                if !receiver.keyboardIssue.isEmpty { Text(receiver.keyboardIssue).foregroundStyle(.orange) }
                LabeledContent("손쉬운 사용") {
                    Text(receiver.trusted ? "허용됨" : "키보드와 마우스 입력에 필요")
                    Button("권한 설정 열기") { model.permissionSettings() }
                }
                Picker("F1–F12 동작", selection: $receiver.functionRowMode) {
                    ForEach(FunctionRowMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("입력할 디스플레이", selection: $model.display) {
                    Text("주 디스플레이 (자동)").tag(0)
                    ForEach(model.screens, id: \.self) { screen in
                        if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                            Text(screen.localizedName + " · " + id.stringValue).tag(id.intValue)
                        }
                    }
                    if model.display != 0 && !model.screens.contains(where: {
                        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue == model.display
                    }) { Text("연결 해제된 디스플레이 · \(model.display)").tag(model.display) }
                }
            }
            Section {
                LabeledContent("페어링 키") {
                    Button(model.visibleKey == nil ? "키 표시" : "가리기") { model.reveal() }
                    Button(model.copied ? "복사됨" : "복사") { model.copyKey() }
                    Button("재발급…") { confirmRotate = true }
                }.disabled(!model.hasKey || model.readingKey)
                if model.readingKey {
                    Text("키체인 확인 중 · macOS에서 접근 요청을 표시하면 확인하세요.")
                }
                if let key = model.visibleKey {
                    Text(verbatim: key).font(.system(.body, design: .monospaced))
                }
                if !model.keyError.isEmpty {
                    Text(model.keyError)
                    Button("키체인 다시 열기") { model.load() }
                }
            } footer: {
                Text("Windows 미러링 창에서 F8을 누르고 처음 한 번만 키를 입력하세요. 다음 연결부터 저장된 키를 사용합니다.")
            }
            Section {
                Toggle("로그인 시 AirPlay Input 시작", isOn: Binding(
                    get: { model.login == .enabled || model.login == .requiresApproval },
                    set: model.setLogin))
                if model.login == .requiresApproval {
                    Button("시스템 설정에서 로그인 항목 허용") { SMAppService.openSystemSettingsLoginItems() }
                }
                if !model.loginError.isEmpty { Text(model.loginError) }
            }
        }
        .formStyle(.grouped)
        .alert("페어링 키를 재발급할까요?", isPresented: $confirmRotate) {
            Button("취소", role: .cancel) {}
            Button("재발급", role: .destructive) { model.rotate() }
        } message: { Text("현재 연결을 종료합니다. Windows에서 F8을 눌러 새 키를 입력하세요.") }
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
        menu.addItem(withTitle: "AirPlay Input 열기", action: #selector(showWindow), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "AirPlay Input 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
