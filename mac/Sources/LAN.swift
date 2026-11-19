import Darwin
import Foundation
import Network
import SystemConfiguration

struct LANAddress: Hashable {
    let interfaceName: String
    let interfaceIndex: Int
    let ip: Data
    let mask: Data

    static func isPrivate(_ ip: Data) -> Bool {
        let b = Array(ip)
        if b.count == 4 {
            return b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1])) ||
                (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254)
        }
        return b.count == 16 && (b[0] & 0xfe == 0xfc || (b[0] == 0xfe && b[1] & 0xc0 == 0x80))
    }

    init?(interface: String, index: Int, ip: Data, mask: Data) {
        guard index > 0, Self.isPrivate(ip), ip.count == mask.count,
              mask.first != 0 else { return nil }
        // A connected subnet mask must consist of leading ones then zeros.
        var sawZero = false
        for byte in mask {
            for shift in (0..<8).reversed() {
                if byte & (1 << shift) == 0 { sawZero = true }
                else if sawZero { return nil }
            }
        }
        interfaceName = interface
        interfaceIndex = index
        self.ip = ip
        self.mask = mask
    }

    func permits(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let peer): return permits(peer.rawValue, scope: peer.interface)
        case .ipv6(let peer):
            if peer.isIPv4Mapped {
                return permits(Data(peer.rawValue.suffix(4)), scope: peer.interface)
            }
            return permits(peer.rawValue, scope: peer.interface)
        case .name(let name, let scope):
            guard scope == nil || scope?.index == interfaceIndex else { return false }
            if let v4 = IPv4Address(name) { return permits(v4.rawValue, scope: v4.interface) }
            if let v6 = IPv6Address(name) { return permits(.hostPort(host: .ipv6(v6), port: .any)) }
            return false
        @unknown default: return false
        }
    }

    private func permits(_ peer: Data, scope: NWInterface?) -> Bool {
        guard scope == nil || scope?.index == interfaceIndex, peer.count == ip.count,
              Self.isPrivate(peer), peer != ip else { return false }
        return ip.indices.allSatisfy { (ip[$0] ^ peer[$0]) & mask[$0] == 0 }
    }

    var description: String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        _ = ip.withUnsafeBytes { inet_ntop(ip.count == 4 ? AF_INET : AF_INET6, $0.baseAddress, &buffer, socklen_t(buffer.count)) }
        return String(cString: buffer) + (ip.count == 4 ? "" : "%" + interfaceName)
    }

    func endpoint(on interface: NWInterface, port: NWEndpoint.Port) -> NWEndpoint {
        precondition(interface.index == interfaceIndex)
        let host: NWEndpoint.Host = ip.count == 4
            ? .ipv4(IPv4Address(ip, interface)!) : .ipv6(IPv6Address(ip, interface)!)
        return .hostPort(host: host, port: port)
    }

    static func discover(interfaces: [NWInterface]) -> [LANAddress: NWInterface] {
        let devices = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        let hardware = Set(devices.compactMap { device -> String? in
            let type = SCNetworkInterfaceGetInterfaceType(device) as String?
            guard type == kSCNetworkInterfaceTypeIEEE80211 as String ||
                    type == kSCNetworkInterfaceTypeEthernet as String else { return nil }
            return SCNetworkInterfaceGetBSDName(device) as String?
        })
        var eligible: [String: NWInterface] = [:]
        for interface in interfaces where hardware.contains(interface.name) &&
            (interface.type == .wifi || interface.type == .wiredEthernet) {
            eligible[interface.name] = interface
        }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [:] }
        defer { freeifaddrs(first) }
        var result: [LANAddress: NWInterface] = [:]
        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = item.pointee
            let name = String(cString: a.ifa_name)
            guard let interface = eligible[name], let addr = a.ifa_addr, let mask = a.ifa_netmask,
                  a.ifa_flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING),
                  a.ifa_flags & UInt32(IFF_LOOPBACK | IFF_POINTOPOINT) == 0 else { continue }
            let family = Int32(addr.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            // getnameinfo normalizes Darwin's embedded interface index in scoped IPv6 addresses.
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let numeric = String(String(cString: host).prefix { $0 != "%" })
            guard let bytes = IPv4Address(numeric)?.rawValue ?? IPv6Address(numeric)?.rawValue else { continue }
            let offset = family == AF_INET ? MemoryLayout<sockaddr_in>.offset(of: \.sin_addr)! :
                MemoryLayout<sockaddr_in6>.offset(of: \.sin6_addr)!
            // Darwin can omit trailing zero bytes from a sockaddr netmask.
            let length = min(bytes.count, max(0, Int(mask.pointee.sa_len) - offset))
            var netmask = Data(bytes: UnsafeRawPointer(mask).advanced(by: offset), count: length)
            netmask.append(Data(repeating: 0, count: bytes.count - length))
            if let lan = LANAddress(interface: name, index: interface.index, ip: bytes, mask: netmask) {
                result[lan] = interface
            }
        }
        return result
    }
}
