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
            let address = String(cString: hostBuffer)
            // 169.254.0.0/16 is link-local (self-assigned, no DHCP lease) --
            // never a usable LAN address, so it must never be a candidate.
            guard !address.hasPrefix("169.254.") else { continue }
            candidates.append((name, address))
        }

        // Choix, dans cet ordre : adresse PRIVÉE (RFC 1918) sur une interface
        // physique, puis n'importe quelle adresse privée, puis à défaut la
        // première trouvée.
        //
        // Prendre la première venue suffisait tant qu'il n'y avait qu'un seul
        // chemin réseau. Un tunnel WireGuard (utun*, utilisé sur le MacBook)
        // est UP, non-loopback et hors 169.254 : il devenait donc un candidat
        // parfaitement légitime. Or son adresse est souvent en 100.64.0.0/10
        // (espace partagé CGNAT), que le garde Host d'app.py ne reconnaît PAS
        // comme privée -- ipaddress.is_private y répond False (vérifié) et
        // _guard_local_host renvoie alors 403. L'app se faisait refuser par son
        // PROPRE backend, ce que le superviseur ne peut lire que « le serveur
        // est mort » : sondages en échec, relances, puis l'écran « Le serveur
        // local n'a pas pu démarrer » devant un backend parfaitement sain.
        //
        // Aucun nom d'interface n'est présumé « le bon » pour autant -- pas de
        // en0 en dur : c'est d'abord la NATURE de l'adresse qui tranche, et le
        // nom ne sert qu'à départager deux adresses privées, en préférant un
        // lien physique (Wi-Fi, Ethernet, dongle en5+, pont) à un tunnel.
        if let physiquePrivee = candidates.first(where: { isPrivateIPv4($0.address) && isPhysicalInterface($0.name) }) {
            return physiquePrivee.address
        }
        if let privee = candidates.first(where: { isPrivateIPv4($0.address) }) {
            return privee.address
        }
        return candidates.first?.address
    }

    /// RFC 1918 strictement : 10/8, 172.16/12 et 192.168/16. Volontairement
    /// PAS 100.64/10 -- c'est justement l'espace que le garde Host d'app.py
    /// rejette, le retenir ici ne ferait que rétablir le bug.
    private static func isPrivateIPv4(_ address: String) -> Bool {
        if address.hasPrefix("10.") || address.hasPrefix("192.168.") { return true }
        // 172.16.0.0/12 s'arrête à 172.31 : un simple hasPrefix("172.") prendrait
        // aussi 172.32+ et au-delà, qui sont des adresses publiques.
        let octets = address.split(separator: ".")
        if octets.count == 4, octets[0] == "172",
           let deuxieme = Int(octets[1]), (16...31).contains(deuxieme) {
            return true
        }
        return false
    }

    /// Lien physique (Wi-Fi, Ethernet, dongle USB/Thunderbolt, pont) par
    /// opposition à un tunnel (utun*, ipsec*, ppp*) ou à une interface
    /// virtuelle. Préférence, jamais une exigence : voir l'ordre de repli.
    private static func isPhysicalInterface(_ name: String) -> Bool {
        name.hasPrefix("en") || name.hasPrefix("bridge")
    }
}
