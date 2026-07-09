import Foundation

/// Resolves the Mac's own active LAN IPv4 address at runtime.
///
/// This machine's pf configuration (`/etc/pf.anchors/backupmanager`, a
/// `rdr` rule redirecting lo0 port 80 -> 8787 for the iPhone's convenience)
/// has a known loopback hairpin-NAT side effect: direct connections to
/// 127.0.0.1:8787 on lo0 intermittently fail at the TCP handshake level,
/// confirmed via isolated testing (a dummy server on the same port/interface
/// with zero Flask involvement reproduces it; a control port with no pf rule
/// does not). Connections to the LAN interface are untouched by that rule
/// (it only matches destination 127.0.0.1), so the native app talks to
/// Flask over the LAN IP instead of loopback. Resolved fresh at launch
/// rather than hardcoded, so a DHCP lease change doesn't strand the app.
enum LocalNetwork {
    static func currentLANAddress() -> String? {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }

        var candidates: [(name: String, address: String)] = []

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0,
                  let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET)
            else { continue }

            let name = String(cString: ptr.pointee.ifa_name)
            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                                      &hostBuffer, socklen_t(hostBuffer.count),
                                      nil, 0, NI_NUMERICHOST)
            guard result == 0 else { continue }
            candidates.append((name, String(cString: hostBuffer)))
        }

        // Prefer en0 (typically Wi-Fi/primary) if present, otherwise the
        // first non-loopback IPv4 address found.
        return candidates.first(where: { $0.name == "en0" })?.address ?? candidates.first?.address
    }
}
