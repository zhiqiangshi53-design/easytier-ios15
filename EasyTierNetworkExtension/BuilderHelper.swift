import Darwin
import NetworkExtension
import Network
import os

import EasyTierShared

let magicDNSCIDR = RunningIPv4CIDR(from: "100.100.100.101/32")!

func buildSettings(_ options: EasyTierOptions) -> NEPacketTunnelNetworkSettings {
    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
    let runningInfo = fetchRunningInfo()
    if runningInfo == nil {
        logger.warning("prepareSettings() running info is nil")
    }

    let ipv4Settings: NEIPv4Settings?
    if let ipv4 = runningInfo?.myNodeInfo?.virtualIPv4,
       let mask = cidrToSubnetMask(ipv4.networkLength) {
        ipv4Settings = NEIPv4Settings(
            addresses: [ipv4.address.description],
            subnetMasks: [mask]
        )
    } else if let ipv4 = options.ipv4,
              let cidr = RunningIPv4CIDR(from: ipv4),
              let mask = cidrToSubnetMask(cidr.networkLength) {
        ipv4Settings = NEIPv4Settings(
            addresses: [cidr.address.description],
            subnetMasks: [mask]
        )
    } else {
        ipv4Settings = nil
    }
    var routes = buildIPv4RouteCIDRs(info: runningInfo, options: options)
    if let ipv4Settings, !routes.isEmpty {
        // Office/home Wi-Fi often shares the subnet a peer proxies (e.g. both
        // sides are 192.168.119.0/24). Without an exclusion every LAN packet
        // would be pulled into the tunnel, which stalls the local network and
        // usually kills the tunnel itself. Excluded routes win over included
        // ones, so on-link traffic stays on the physical interface.
        let excluded = buildExcludedRouteCIDRs(tunnelAddress: ipv4Settings.addresses.first)
        if !excluded.isEmpty {
            let isCovered: (RunningIPv4CIDR) -> Bool = { route in
                excluded.contains { subnet in
                    subnet.networkLength <= route.networkLength
                        && ipv4SubnetsOverlap(bigger: subnet, smaller: route)
                }
            }
            let covered = routes.filter(isCovered)
            if !covered.isEmpty {
                logger.warning("prepareSettings() local subnet overrides tunnel routes: \(covered.map { "\($0.address.description)/\($0.networkLength)" }.joined(separator: ","), privacy: .public)")
                routes.removeAll(where: isCovered)
            }
            // An empty includedRoutes means "route everything through the
            // tunnel", so only publish IPv4 settings while routes remain.
            if !routes.isEmpty {
                ipv4Settings.excludedRoutes = excluded.compactMap(cidrToRoute)
            }
        }
        if !routes.isEmpty {
            logger.info("prepareSettings() ipv4 routes: \(routes.count)")
            ipv4Settings.includedRoutes = routes.compactMap(cidrToRoute)
            settings.ipv4Settings = ipv4Settings
        }
    }

    if let ipv6CIDR = options.ipv6?.split(separator: "/"), ipv6CIDR.count == 2 {
        let ip = ipv6CIDR[0], cidrStr = ipv6CIDR[1]
        if let cidr = Int(cidrStr), (0...128).contains(cidr), let address = IPv6Address(String(ip)) {
            settings.ipv6Settings = .init(
                addresses: [String(ip)],
                networkPrefixLengths: [NSNumber(value: cidr)]
            )
            var subnet = Array(address.rawValue)
            for index in subnet.indices {
                let bits = max(0, min(8, cidr - index * 8))
                subnet[index] &= bits == 0 ? 0 : UInt8.max << (8 - bits)
            }
            if let network = IPv6Address(Data(subnet)) {
                settings.ipv6Settings?.includedRoutes = [NEIPv6Route(
                    destinationAddress: network.debugDescription,
                    networkPrefixLength: NSNumber(value: cidr)
                )]
            }
        }
    }

    // DHCP may not have assigned an address yet. Keep the Web control tunnel
    // alive without DNS, MTU, or a premature TUN binding until an address arrives.
    guard settings.ipv4Settings != nil || settings.ipv6Settings != nil else { return settings }

    if (settings.ipv4Settings != nil || !options.dns.isEmpty), let dns = buildDNSServers(options: options) {
        settings.dnsSettings = dns
    }
    
    if let mtu = options.mtu {
        settings.mtu = NSNumber(value: mtu)
    }

    return settings
}

func buildIPv4RouteCIDRs(info: RunningInfo?, options: EasyTierOptions) -> [RunningIPv4CIDR] {
    var cidrs = Set<RunningIPv4CIDR>()
    // Additive: manual routes used to replace the derived ones, which made every peer's
    // proxied subnet unreachable as soon as one manual route existed. includedRoutes is the
    // only way a route reaches the tun device here, so there is no system table to fall back
    // on. The overlap pass below drops whatever is redundant.
    if !options.routes.isEmpty {
        logger.info("buildIPv4Routes() found manual routes: \(options.routes.count)")
        for route in options.routes {
            if let normalized = normalizeCIDR(route) {
                cidrs.insert(normalized)
            }
        }
    }
    if let routes = info?.routes {
        for route in routes {
            for cidr in route.proxyCIDRs {
                if let normalized = normalizeCIDR(cidr) {
                    cidrs.insert(normalized)
                }
            }
        }
    }
    if let ipv4 = options.ipv4, let cidr = RunningIPv4CIDR(from: ipv4) {
        cidrs.insert(.init(address: ipv4MaskedSubnet(cidr), length: cidr.networkLength))
    }
    if let ipv4 = info?.myNodeInfo?.virtualIPv4 {
        cidrs.insert(.init(address: ipv4MaskedSubnet(ipv4), length: ipv4.networkLength))
    }
    if options.magicDNS {
        cidrs.insert(magicDNSCIDR)
    }
    if cidrs.isEmpty {
        logger.warning("buildIPv4Routes() no routes")
    }
    var sortedCIDRs = Array(cidrs)
    sortedCIDRs.sort { $0.networkLength < $1.networkLength }
    var indicesToRemove = Set<Int>()
    for i in 0..<sortedCIDRs.count {
        if indicesToRemove.contains(i) {
            continue
        }
        for j in (i + 1)..<sortedCIDRs.count {
            if indicesToRemove.contains(j) {
                continue
            }
            if ipv4SubnetsOverlap(bigger: sortedCIDRs[i], smaller: sortedCIDRs[j]) {
                logger.warning("buildIPv4Routes() remove covered route: \(sortedCIDRs[j].address.description, privacy: .public)/\(sortedCIDRs[j].networkLength, privacy: .public) covered by \(sortedCIDRs[i].address.description, privacy: .public)/\(sortedCIDRs[i].networkLength, privacy: .public)")
                indicesToRemove.insert(j)
            }
        }
    }
    for index in indicesToRemove.sorted(by: >) {
        sortedCIDRs.remove(at: index)
    }
    return sortedCIDRs
}

func cidrToRoute(_ cidr: RunningIPv4CIDR) -> NEIPv4Route? {
    guard let mask = cidrToSubnetMask(cidr.networkLength) else {
        logger.warning("buildIPv4Routes() invalid cidr length: \(cidr.networkLength, privacy: .public)")
        return nil
    }
    return NEIPv4Route(destinationAddress: cidr.address.description, subnetMask: mask)
}

/// IPv4 subnets currently assigned to the Wi-Fi interface (en0 and friends).
/// The packet tunnel is a utun device, so these stay visible while the VPN runs.
func localOnLinkIPv4Subnets() -> [RunningIPv4CIDR] {
    var subnets = [RunningIPv4CIDR]()
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0, let first = interfaces else {
        logger.warning("localOnLinkIPv4Subnets() getifaddrs failed")
        return subnets
    }
    defer { freeifaddrs(first) }

    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let interface = cursor {
        defer { cursor = interface.pointee.ifa_next }
        let flags = Int32(interface.pointee.ifa_flags)
        guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
        let name = String(cString: interface.pointee.ifa_name)
        // Wi-Fi only. Cellular masks are point-to-point /32s and excluding a
        // carrier subnet would cut off the tunnel's own transport.
        guard name.hasPrefix("en") else { continue }
        guard let address = interface.pointee.ifa_addr,
              address.pointee.sa_family == UInt8(AF_INET),
              let netmask = interface.pointee.ifa_netmask,
              netmask.pointee.sa_family == UInt8(AF_INET) else { continue }

        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            address, socklen_t(address.pointee.sa_len),
            &host, socklen_t(host.count),
            nil, 0, NI_NUMERICHOST
        )
        let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
        }
        let length = mask.nonzeroBitCount
        let expected: UInt32 = length == 0 ? 0 : UInt32.max << (32 - length)
        // Non-contiguous masks cannot be expressed as a CIDR, and /31+/32
        // links carry no usable on-link subnet.
        guard result == 0, length >= 8, length <= 30, mask == expected else { continue }
        guard let cidr = RunningIPv4CIDR(from: String(cString: host) + "/\(length)") else { continue }
        subnets.append(.init(address: ipv4MaskedSubnet(cidr), length: cidr.networkLength))
    }
    return subnets
}

/// On-link Wi-Fi subnets to keep out of the tunnel, minus anything that would
/// cut the tunnel's own address or the magic-DNS route out of the VPN.
func buildExcludedRouteCIDRs(tunnelAddress: String?) -> [RunningIPv4CIDR] {
    let tunnel = tunnelAddress.flatMap { RunningIPv4CIDR(from: $0) }
    var excluded = [RunningIPv4CIDR]()
    for subnet in localOnLinkIPv4Subnets() {
        if let tunnel, ipv4SubnetsOverlap(bigger: subnet, smaller: RunningIPv4CIDR(address: tunnel.address, length: 32)) {
            logger.warning("buildExcludedRoutes() keep \(subnet.address.description, privacy: .public)/\(subnet.networkLength, privacy: .public) inside tunnel: holds tunnel address")
            continue
        }
        if ipv4SubnetsOverlap(bigger: subnet, smaller: magicDNSCIDR) {
            logger.warning("buildExcludedRoutes() keep \(subnet.address.description, privacy: .public)/\(subnet.networkLength, privacy: .public) inside tunnel: holds magic DNS")
            continue
        }
        excluded.append(subnet)
        logger.info("buildExcludedRoutes() exclude local subnet: \(subnet.address.description, privacy: .public)/\(subnet.networkLength, privacy: .public)")
    }
    return excluded
}

func buildDNSServers(options: EasyTierOptions) -> NEDNSSettings? {
    var settings: NEDNSSettings
    if !options.dns.isEmpty {
        logger.info("buildDNSServers() use override dns: \(options.dns.count)")
        settings = .init(servers: options.dns)
        settings.matchDomains = [""]
    } else if options.magicDNS {
        settings = .init(servers: [magicDNSCIDR.address.description])
        settings.matchDomains = ["et.net"]
    } else {
        return nil
    }
    
    if options.magicDNS {
        logger.info("buildDNSServers() enabled magic dns")
        settings.searchDomains = ["et.net"]
    }
    return settings
}
