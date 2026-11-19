import ApplicationServices
import Darwin
import Foundation
import Network
import Security

func fail(_ text: String) -> Never {
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(1)
}

func privateIP(_ text: String) -> IPv4Address? {
    guard let ip = IPv4Address(text) else { return nil }
    let b = Array(ip.rawValue)
    return b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1])) ||
           (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254) ? ip : nil
}

func permits(_ endpoint: NWEndpoint, from allowed: IPv4Address) -> Bool {
    guard case let .hostPort(host, _) = endpoint else { return false }
    switch host {
    case .ipv4(let ip): return ip.rawValue == allowed.rawValue
    case .ipv6(let ip):
        let bytes = ip.rawValue
        return bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 255 && bytes[11] == 255 &&
               bytes.suffix(4).elementsEqual(allowed.rawValue)
    case .name(let name, _): return IPv4Address(name)?.rawValue == allowed.rawValue
    @unknown default: return false
    }
}

func activeDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
    return Array(ids.prefix(Int(count)))
}

let args = Array(CommandLine.arguments.dropFirst())
let displays = activeDisplays()
if args == ["--displays"] {
    for id in displays {
        let r = CGDisplayBounds(id)
        print("\(id)  \(Int(r.width)) x \(Int(r.height))  origin \(r.origin)" +
              (id == CGMainDisplayID() ? "  main" : ""))
    }
    exit(0)
}
guard (2...3).contains(args.count), let localIP = privateIP(args[0]), let windowsIP = privateIP(args[1]) else {
    fail("Usage: mac-input MAC_LAN_IPV4 WINDOWS_LAN_IPV4 [DISPLAY_ID]  |  mac-input --displays")
}
guard let display = (args.count == 3 ? UInt32(args[2]) : CGMainDisplayID()), displays.contains(display) else {
    fail("Unknown display. Use --displays after starting mirroring.")
}
let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
guard AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary) else {
    fail("Allow Accessibility access in System Settings, then restart the agent.")
}
var secret = [UInt8](repeating: 0, count: 16)
guard SecRandomCopyBytes(kSecRandomDefault, secret.count, &secret) == errSecSuccess else {
    fail("Could not generate a pairing key.")
}
let tls = NWProtocolTLS.Options()
let options = tls.securityProtocolOptions
sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
let psk = secret.withUnsafeBytes { DispatchData(bytes: $0) }
let identity = Array("airplay-input-v1".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
sec_protocol_options_add_pre_shared_key(options, psk as __DispatchData, identity as __DispatchData)
let tcp = NWProtocolTCP.Options()
tcp.noDelay = true
let params = NWParameters(tls: tls, tcp: tcp)
let port: NWEndpoint.Port = 49721
params.requiredLocalEndpoint = .hostPort(host: .ipv4(localIP), port: port)
let listener = try NWListener(using: params)
let quartz = QuartzOutput(display: display)
func makeSink() -> InputSink {
    InputSink(bounds: quartz.bounds,
              caps: CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift),
              emit: quartz.post)
}
var sink = makeSink()
var active: NWConnection?
var timer: DispatchSourceTimer?
var frames = InputFrames()

func end(_ conn: NWConnection, _ reason: String) {
    guard active === conn else { return }
    print("Input disconnected: \(reason)")
    active = nil
    timer?.cancel()
    timer = nil
    sink.release()
    frames = InputFrames()
    conn.stateUpdateHandler = nil
    conn.cancel()
}

func receive(_ conn: NWConnection) {
    conn.receive(minimumIncompleteLength: 1, maximumLength: 2048) { data, _, complete, error in
        guard active === conn else { return }
        guard AXIsProcessTrusted() else { end(conn, "Accessibility access was revoked"); return }
        if let data = data, !data.isEmpty {
            guard let count = frames.receive(data, apply: sink.apply) else {
                end(conn, "selected display unavailable or invalid input frame")
                return
            }
            if count > 0 { timer?.schedule(deadline: .now() + 3) }
        }
        if let error = error { end(conn, "receive failed (\(error))") }
        else if complete { end(conn, "Windows closed the connection") }
        else { receive(conn) }
    }
}

listener.newConnectionHandler = { conn in
    guard permits(conn.endpoint, from: windowsIP) else {
        print("Input rejected from \(conn.endpoint). Expected Windows address \(windowsIP).")
        conn.cancel()
        return
    }
    guard active == nil else {
        print("Input rejected: another connection is still active.")
        conn.cancel()
        return
    }
    print("TCP accepted from \(conn.endpoint). Starting TLS pairing.")
    active = conn
    sink = makeSink()
    let watchdog = DispatchSource.makeTimerSource(queue: .main)
    timer = watchdog
    watchdog.schedule(deadline: .now() + 6)
    watchdog.setEventHandler { end(conn, "pairing or input heartbeat timed out") }
    watchdog.resume()
    conn.stateUpdateHandler = { state in
        guard active === conn else { return }
        switch state {
        case .ready:
            guard AXIsProcessTrusted() else { end(conn, "Accessibility access required"); return }
            print("TLS paired. Sending input-ready acknowledgement.")
            conn.send(content: Data([1]), completion: .contentProcessed { err in
                if let err = err { end(conn, "ready acknowledgement failed (\(err))") }
            })
            receive(conn)
        case .failed(let error): end(conn, "Network.framework connection failed (\(error))")
        case .cancelled: end(conn, "connection cancelled")
        default: break
        }
    }
    conn.start(queue: .main)
}

listener.stateUpdateHandler = { state in
    switch state {
    case .ready:
        print("Listening on \(args[0]):49721 for \(args[1]), display \(display).")
        print("Pairing key: " + secret.map { String(format: "%02x", $0) }.joined())
        print("Press Ctrl-C here to release input and quit.")
    case .failed(let err):
        if let conn = active { end(conn, "listener failed") }
        fail("Listener failed: \(err)")
    default: break
    }
}
let signals = [SIGINT, SIGTERM, SIGHUP].map { number -> DispatchSourceSignal in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler {
        if let conn = active { end(conn, "agent stopped") }
        listener.cancel()
        exit(0)
    }
    source.resume()
    return source
}
listener.start(queue: .main)
dispatchMain()
