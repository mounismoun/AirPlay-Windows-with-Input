import CoreGraphics
import CryptoKit
import Foundation
import IOKit.hidsystem
import Network
import Security

@main struct CoreTests {
    static func ip(_ s: String) -> Data {
        IPv4Address(s)?.rawValue ?? IPv6Address(s)!.rawValue
    }
    static func policy() {
        func subnet(_ addr: String, _ mask: String) -> LANAddress? {
            LANAddress(interface: "en0", index: 1, ip: ip(addr), mask: ip(mask))
        }
        func peer(_ s: String) -> NWEndpoint { .hostPort(host: NWEndpoint.Host(s), port: 40000) }
        let lan = subnet("192.168.1.7", "255.255.255.0")!
        for allowed in ["192.168.1.5", "::ffff:192.168.1.5"] {
            precondition(lan.permits(peer(allowed)))
        }
        for denied in ["192.168.2.5", "192.168.1.7", "127.0.0.1", "8.8.8.8", "localhost", "fd00::5"] {
            precondition(!lan.permits(peer(denied)))
        }
        let ula = subnet("fd01:abcd::1", "ffff:ffff:ffff:ffff::")!
        let link = subnet("fe80::1", "ffff:ffff:ffff:ffff::")!
        precondition(ula.permits(peer("fd01:abcd::2")) && !ula.permits(peer("fd01:abce::2")))
        precondition(link.permits(peer("fe80::2")) && !link.permits(peer("2001:db8::42")))
        for addr in ["8.8.8.8", "0.0.0.0", "127.0.0.1", "100.64.0.1", "172.32.0.1"] {
            precondition(subnet(addr, "255.255.255.0") == nil)
        }
        for addr in ["::", "::1", "ff02::1", "2001:db8::1"] {
            precondition(subnet(addr, "ffff:ffff:ffff:ffff::") == nil)
        }
        precondition(subnet("10.0.0.1", "255.0.255.0") == nil)
        precondition(subnet("10.0.0.1", "0.0.0.0") == nil)
        print("PASS LAN address and source policy")
    }
    static func inputs() {
        var events = [(MacEvent, InputFlags)]()
        let sink = InputSink(bounds: { CGRect(x: -100, y: 10, width: 101, height: 51) }, caps: false) {
            events.append(($0, $1))
        }
        var frames = InputFrames()
        func apply(_ packet: [UInt8]) {
            for byte in packet { precondition(frames.receive(Data([byte]), apply: sink.apply) != nil) }
        }
        for (usage, code, flag): (UInt8, UInt16, InputFlags) in [
            (224,55,.sided(.maskCommand, NX_DEVICELCMDKEYMASK)), (225,56,.sided(.maskShift, NX_DEVICELSHIFTKEYMASK)),
            (226,58,.sided(.maskAlternate, NX_DEVICELALTKEYMASK)), (227,54,.sided(.maskCommand, NX_DEVICERCMDKEYMASK)),
            (228,62,.sided(.maskControl, NX_DEVICERCTLKEYMASK)), (229,60,.sided(.maskShift, NX_DEVICERSHIFTKEYMASK)),
            (230,61,.sided(.maskAlternate, NX_DEVICERALTKEYMASK)), (231,59,.sided(.maskControl, NX_DEVICELCTLKEYMASK))
        ] {
            apply([4,usage,1,0,0,0,0,0])
            precondition(events.last!.0 == .keyboard(code, down: true, modifier: true, repeated: false))
            precondition(events.last!.1 == flag)
            sink.release()
            precondition(events.last!.1.isEmpty)
        }
        events.removeAll()
        let corner = CGPoint(x: 0, y: 60)
        apply([2,3,1,2,255,255,255,255])
        precondition(events.last!.0 == .pointer(.down, button: 3, at: corner, clicks: 2))
        apply([1,0,0,0,0,0,0,0])
        precondition(events.last!.0 == .pointer(.drag, button: 3, at: CGPoint(x: -100, y: 10), clicks: 2))
        apply([3,255,2,0,255,255,255,255])
        precondition(events.last!.0 == .wheel(at: corner, vertical: 2, horizontal: -1))
        sink.release()
        precondition(events.last!.0 == .pointer(.up, button: 3, at: corner, clicks: 2))
        print("PASS r3 keyboard, pointer, scroll, frame splits and release")
    }

    static let testPrefix = "local.airplay-input.test."
    static func storage() throws {
        let store = PairingKey(service: testPrefix + UUID().uuidString)
        let first = try store.loadOrCreate()
        defer { precondition(SecItemDelete(store.query as CFDictionary) == errSecSuccess) }
        func checkInNewProcess(_ expected: Data) throws {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            task.arguments = ["--verify-key", store.service]
            let input = Pipe()
            task.standardInput = input
            try task.run()
            input.fileHandleForWriting.write(Data(SHA256.hash(data: expected)))
            try input.fileHandleForWriting.close()
            task.waitUntilExit()
            precondition(task.terminationStatus == 0)
        }
        try checkInNewProcess(first)
        let second = try store.rotate()
        precondition(first.count == 16 && second.count == 16 && first != second)
        try checkInNewProcess(second)
        print("PASS Keychain creation, relaunch, rotation and relaunch with new key")
    }
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.count == 2 && args[0] == "--verify-key" && args[1].hasPrefix(testPrefix) {
            let installed = try PairingKey(service: args[1]).loadOrCreate()
            precondition(Data(SHA256.hash(data: installed)) == FileHandle.standardInput.readDataToEndOfFile())
            return
        }
        precondition(L10n.language(for: ["ko-KR", "en-US"]) == "ko")
        precondition(L10n.language(for: ["en-KR", "ko"]) == "en")
        precondition(L10n.language(for: ["ja-JP", "ko", "en"]) == "en")
        precondition(L10n.language(for: []) == "en")
        policy()
        inputs()
        try storage()
    }
}
