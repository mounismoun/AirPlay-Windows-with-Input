import Foundation
import Network

// Test executable only. The ephemeral key comes from the parent process over
// an anonymous pipe. Events are counted in memory and never reach Quartz.
@main struct TLSFixture {
    static func main() throws {
        let key = FileHandle.standardInput.readDataToEndOfFile()
        guard key.count == 16 else { exit(2) }
        let v6 = CommandLine.arguments.contains("--ipv6")
        let endpoint = NWEndpoint.hostPort(host: v6 ? .ipv6(.loopback) : .ipv4(.loopback), port: .any)
        let listener = try Transport.listener(key: key, endpoint: endpoint, interface: nil)
        var session: InputSession?
        func line(_ text: String) {
            FileHandle.standardOutput.write(Data((text + "\n").utf8))
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: line("PORT \(listener.port!.rawValue)")
            case .failed(let error): line("FAILED \(error)"); exit(3)
            default: break
            }
        }
        listener.newConnectionHandler = { connection in
            guard session == nil else { connection.cancel(); return }
            let sink = InputSink(bounds: { CGRect(x: 0, y: 0, width: 100, height: 100) }, caps: false) { event, _ in
                if case .keyboard(0, let down, _, _) = event { line(down ? "DOWN" : "UP") }
            }
            session = InputSession(connection: connection, sink: sink, permitted: { true }, onReady: {},
                                   onEnd: { _ in session = nil; line("END") })
            session?.start()
        }
        listener.start(queue: .main)
        dispatchMain()
    }
}
