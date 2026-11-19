import Foundation
import Network

// Bind all eligible addresses simultaneously on one ephemeral port. Every
// incoming connection is cancelled, including connections from the local host.
@main struct Bindings {
    static func main() throws {
        let key = try PairingKey.generate()
        let monitors = [NWPathMonitor(requiredInterfaceType: .wifi), NWPathMonitor(requiredInterfaceType: .wiredEthernet)]
        var updated = Set<Int>()
        var listeners = [NWListener]()
        var ready = 0
        var port: NWEndpoint.Port?
        var available = [(key: LANAddress, value: NWInterface)]()
        func bind(_ index: Int) throws {
            let (address, interface) = available[index]
            let endpoint = address.endpoint(on: interface, port: port ?? .any)
            let listener = try Transport.listener(key: key, endpoint: endpoint, interface: interface)
            listeners.append(listener)
            listener.newConnectionHandler = { $0.cancel() }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if port == nil { port = listener.port }
                    precondition(port == listener.port)
                    ready += 1
                    print("BOUND \(address.description) \(port!.rawValue)")
                    if ready == available.count { exit(0) }
                    do { try bind(index+1) } catch { print(error.localizedDescription); exit(2) }
                case .waiting(let err), .failed(let err):
                    print("FAILED \(address.description) \(err)"); exit(3)
                default: break
                }
            }
            listener.start(queue: .main)
        }
        for (index, monitor) in monitors.enumerated() {
            monitor.pathUpdateHandler = { _ in
                updated.insert(index)
                guard updated.count == monitors.count, listeners.isEmpty else { return }
                available = LANAddress.discover(interfaces: monitors.flatMap { $0.currentPath.availableInterfaces })
                    .sorted { $0.key.description < $1.key.description }
                guard !available.isEmpty else { print("SKIP no eligible local LAN address"); exit(77) }
                do { try bind(0) } catch { print(error.localizedDescription); exit(2) }
            }
            monitor.start(queue: .main)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { print("FAILED timed out"); exit(4) }
        dispatchMain()
    }
}
