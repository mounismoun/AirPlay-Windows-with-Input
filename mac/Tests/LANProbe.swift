import Foundation
import Network

// One-shot coordination probe. Only this test executable has a public test
// vector. There is no Keychain, Accessibility, or Quartz output dependency.
@main struct LANProbe {
    static func line(_ text: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardOutput.write(Data((stamp + " " + text + "\n").utf8))
    }

    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 1, let peer = IPv4Address(args[0]), LANAddress.isPrivate(peer.rawValue) else {
            line("Usage: LANProbe PRIVATE_WINDOWS_IPV4")
            exit(2)
        }
        let monitors = [NWPathMonitor(requiredInterfaceType: .wifi), NWPathMonitor(requiredInterfaceType: .wiredEthernet)]
        var updated = Set<Int>()
        var listener: NWListener?
        var session: InputSession?
        let target = NWEndpoint.hostPort(host: .ipv4(peer), port: 1)
        for (index, monitor) in monitors.enumerated() {
            monitor.pathUpdateHandler = { _ in
                updated.insert(index)
                guard updated.count == monitors.count, listener == nil else { return }
                let interfaces = monitors.flatMap { $0.currentPath.availableInterfaces }
                let available = LANAddress.discover(interfaces: interfaces)
                guard let (address, interface) = available.first(where: { $0.key.permits(target) }) else {
                    line("No eligible Wi-Fi/Ethernet IPv4 subnet for the requested Windows peer.")
                    exit(3)
                }
                do {
                    let socket = try Transport.listener(key: Data(UInt8(0)...15),
                        endpoint: address.endpoint(on: interface, port: .any), interface: interface)
                    listener = socket
                    var accepted = false
                    socket.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            line("READY \(address.description) \(socket.port!.rawValue)")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 180) {
                                line("EXPIRED"); exit(4)
                            }
                        case .waiting(let err), .failed(let err): line("BIND FAILED \(err)"); exit(5)
                        default: break
                        }
                    }
                    socket.newConnectionHandler = { conn in
                        guard !accepted, session == nil, address.permits(conn.endpoint),
                              case .hostPort(let host, _) = conn.endpoint else { conn.cancel(); return }
                        let actual: Data?
                        switch host {
                        case .ipv4(let v4): actual = v4.rawValue
                        case .ipv6(let v6) where v6.isIPv4Mapped: actual = Data(v6.rawValue.suffix(4))
                        case .name(let name, _): actual = IPv4Address(name)?.rawValue
                        default: actual = nil
                        }
                        guard actual == peer.rawValue else { conn.cancel(); return }
                        line("TCP accepted from allowed Windows peer")
                        var paired = false
                        let sink = InputSink(bounds: { CGRect(x: 0, y: 0, width: 100, height: 100) },
                                             caps: false, emit: { _, _ in })
                        session = InputSession(connection: conn, sink: sink, permitted: { true },
                            onReady: { paired = true; accepted = true; line("TLS PAIRED · ready sent") },
                            onEnd: { reason in
                                if paired { line("DONE"); exit(0) }
                                line("HANDSHAKE FAILED · " + reason + " · listening")
                                session = nil
                            })
                        session?.start()
                    }
                    socket.start(queue: .main)
                } catch { line("Could not create listener: \(error.localizedDescription)"); exit(7) }
            }
            monitor.start(queue: .main)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            if listener?.port == nil { line("No eligible listening socket became ready."); exit(8) }
        }
        dispatchMain()
    }
}
