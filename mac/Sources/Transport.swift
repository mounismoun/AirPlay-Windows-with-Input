import Foundation
import Network
import Security

enum Transport {
    static let port: NWEndpoint.Port = 49721
    static let cipher = tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!

    static func listener(key: Data, endpoint: NWEndpoint, interface: NWInterface?) throws -> NWListener {
        precondition(key.count == 16)
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(options, cipher)
        sec_protocol_options_set_tls_tickets_enabled(options, false)
        sec_protocol_options_set_tls_resumption_enabled(options, false)
        let psk = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Array("airplay-input-v1".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, psk as __DispatchData, identity as __DispatchData)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: tls, tcp: tcp)
        params.acceptLocalOnly = true
        // Network.framework otherwise reserves the port across both address
        // families, even for listeners bound to distinct concrete addresses.
        params.allowLocalEndpointReuse = true
        params.requiredInterface = interface
        params.requiredLocalEndpoint = endpoint
        return try NWListener(using: params)
    }

    static func paired(_ connection: NWConnection) -> Bool {
        guard let tls = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata
        else { return false }
        let metadata = tls.securityProtocolMetadata
        return sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata) == .TLSv12 &&
            sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata) == cipher
    }
}

// All connection, timer and input callbacks run on the main queue.
final class InputSession {
    let connection: NWConnection
    private let sink: InputSink
    private let permitted: () -> Bool
    private let onReady: () -> Void
    private let onEnd: (String) -> Void
    private var timer: DispatchSourceTimer?
    private var frames = InputFrames()
    private var ended = false

    init(connection: NWConnection, sink: InputSink, permitted: @escaping () -> Bool,
         onReady: @escaping () -> Void, onEnd: @escaping (String) -> Void) {
        self.connection = connection
        self.sink = sink
        self.permitted = permitted
        self.onReady = onReady
        self.onEnd = onEnd
    }

    func start() {
        let watchdog = DispatchSource.makeTimerSource(queue: .main)
        timer = watchdog
        watchdog.setEventHandler { [weak self] in self?.stop(L10n.text("Connection timed out")) }
        watchdog.schedule(deadline: .now() + 6)
        watchdog.resume()
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.ended else { return }
            switch state {
            case .ready:
                guard Transport.paired(self.connection), self.permitted() else {
                    self.stop(L10n.text("Check the connection permissions"))
                    return
                }
                self.connection.send(content: Data([1]), completion: .contentProcessed { [weak self] error in
                    guard let self, !self.ended else { return }
                    guard error == nil else { self.stop(L10n.text("Could not send the reply")); return }
                    self.onReady()
                    self.timer?.schedule(deadline: .now() + 3)
                    self.receive()
                })
            case .failed: self.stop(L10n.text("Connection failed. Check the pairing key and network."))
            case .cancelled: self.stop(L10n.text("Connection closed"))
            default: break
            }
        }
        connection.start(queue: .main)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 2048) { [weak self] data, _, eof, error in
            guard let self, !self.ended else { return }
            guard self.permitted() else { self.stop(L10n.text("Input permissions changed")); return }
            if let data, !data.isEmpty {
                guard let count = self.frames.receive(data, apply: self.sink.apply) else {
                    self.stop(L10n.text("Check the display or input frame"))
                    return
                }
                if count > 0 { self.timer?.schedule(deadline: .now() + 3) }
            }
            if eof || error != nil { self.stop(L10n.text("Connection closed")) }
            else { self.receive() }
        }
    }

    func stop(_ reason: String) {
        guard !ended else { return }
        ended = true
        timer?.cancel()
        timer = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        sink.release()
        onEnd(reason)
    }
}
