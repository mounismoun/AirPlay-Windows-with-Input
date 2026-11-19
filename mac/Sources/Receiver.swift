import ApplicationServices
import Combine
import Foundation
import Network

final class Receiver: ObservableObject {
    @Published private(set) var trusted = false
    @Published private(set) var listening = [String]()
    @Published private(set) var issue = ""
    @Published private(set) var peer = ""
    @Published private(set) var lastSession = ""
    @Published private(set) var keyboardIssue = ""
    private let keyboardSources = KeyboardSources()
    private let functionRow = FunctionRow.internalKeyboard()
    @Published var functionRowMode = FunctionRowMode(rawValue: UserDefaults.standard.string(forKey: "functionRow") ?? "") ?? .system {
        didSet { UserDefaults.standard.set(functionRowMode.rawValue, forKey: "functionRow") }
    }
    @Published private(set) var paused = false
    var display: CGDirectDisplayID? {
        didSet {
            if display != oldValue { session?.stop(L10n.text("Display changed")) }
        }
    }

    private let monitors = [NWPathMonitor(requiredInterfaceType: .wifi),
                            NWPathMonitor(requiredInterfaceType: .wiredEthernet)]
    private var key: Data?
    private var poll: DispatchSourceTimer?
    private var listeners: [LANAddress: NWListener] = [:]
    private var ready = Set<LANAddress>()
    private var failures: [LANAddress: (Date, String)] = [:]
    private var session: InputSession?
    private var sessionAddress: LANAddress?
    private var running = false

    func start() {
        running = true
        for monitor in monitors {
            monitor.pathUpdateHandler = { [weak self] _ in self?.refresh() }
            monitor.start(queue: .main)
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        poll = timer
    }

    func changeKey(_ key: Data?) {
        reset()
        self.key = key
        refresh()
    }

    func togglePause() {
        paused.toggle()
        refresh()
    }

    func stop() {
        running = false
        poll?.cancel()
        poll = nil
        monitors.forEach { $0.cancel() }
        reset()
        key = nil
    }

    private func reset() {
        session?.stop(L10n.text("Receiver stopped"))
        for address in Array(listeners.keys) { remove(address) }
        failures.removeAll()
        publish()
    }

    private func remove(_ address: LANAddress) {
        if sessionAddress == address { session?.stop(L10n.text("Network changed")) }
        listeners.removeValue(forKey: address)?.cancel()
        ready.remove(address)
    }

    private func publish() {
        let addresses = ready.map { $0.interfaceName + "  ·  " + $0.description }.sorted()
        if addresses != listening { listening = addresses }
        let message = Set(failures.values.map { $0.1 }).sorted().joined(separator: "\n")
        if message != issue { issue = message }
    }

    private func addresses() -> [LANAddress: NWInterface] {
        LANAddress.discover(interfaces: monitors.flatMap { $0.currentPath.availableInterfaces })
    }

    private func refresh() {
        guard running else { return }
        let permission = AXIsProcessTrusted()
        if permission != trusted { trusted = permission }
        guard let key, trusted, !paused else { reset(); return }
        let available = addresses()
        for address in Array(listeners.keys) where available[address] == nil { remove(address) }
        failures = failures.filter { available[$0.key] != nil }
        for (address, interface) in available where listeners[address] == nil {
            if let failure = failures[address], failure.0 > Date() { continue }
            do {
                let listener = try Transport.listener(key: key, endpoint: address.endpoint(on: interface, port: Transport.port),
                                                      interface: interface)
                listeners[address] = listener
                listener.newConnectionHandler = { [weak self, weak listener] conn in
                    guard let self, let listener, self.listeners[address] === listener,
                          self.session == nil, AXIsProcessTrusted(), address.permits(conn.endpoint),
                          self.addresses()[address] != nil else { conn.cancel(); return }
                    self.accept(conn, on: address)
                }
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, let listener, self.listeners[address] === listener else { return }
                    switch state {
                    case .ready:
                        self.failures.removeValue(forKey: address)
                        self.ready.insert(address)
                    case .waiting(let error), .failed(let error):
                        self.record(error, on: address)
                    case .cancelled: self.remove(address)
                    default: break
                    }
                    self.publish()
                }
                listener.start(queue: .main)
            } catch { record(error, on: address) }
        }
        publish()
    }

    private func record(_ error: Error, on address: LANAddress) {
        remove(address)
        let message: String
        switch error as? NWError {
        case .posix(.EADDRINUSE):
            message = L10n.text("Port 49721 is in use. Close the other receiver. AirPlay Input will retry automatically.")
        case .posix(.EPERM), .posix(.EACCES):
            message = L10n.text("Allow local network access for AirPlay Input in System Settings.")
        default: message = L10n.format("Unable to listen for connections (%@). Retrying…", L10n.errorCode(error))
        }
        failures[address] = (Date().addingTimeInterval(8), message)
    }

    private func accept(_ conn: NWConnection, on address: LANAddress) {
        let output = QuartzOutput(display: display ?? CGMainDisplayID()) { [weak self] in self?.keyboardIssue = $0 }
        let sink = InputSink(bounds: output.bounds,
                             caps: CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift),
                             capsBehavior: keyboardSources.capsBehavior,
                             switchSource: { [weak self] intent in
                                 guard let self else { return }
                                 self.keyboardIssue = self.keyboardSources.select(intent) ?? ""
                             },
                             toggleSystemCaps: QuartzOutput.toggleCapsLock,
                             functionTarget: { [functionRow, weak self] index, forced in
                                 functionRow.target(index: index, forced: forced, mode: self?.functionRowMode ?? .system,
                                                    systemStandard: FunctionRow.standardByDefault)
                             },
                             performCommand: output.perform,
                             emit: output.post)
        sessionAddress = address
        lastSession = ""
        keyboardIssue = ""
        session = InputSession(connection: conn, sink: sink, permitted: AXIsProcessTrusted,
                               onReady: { [weak self] in self?.peer = String(describing: conn.endpoint) },
                               onEnd: { [weak self] reason in
            self?.session = nil
            self?.sessionAddress = nil
            self?.peer = ""
            self?.lastSession = reason
        })
        session?.start()
    }
}
