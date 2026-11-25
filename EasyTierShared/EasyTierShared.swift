import Foundation
@preconcurrency import NetworkExtension
import os

private func provisioningAppGroups() -> [String] {
    guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
          let data = try? Data(contentsOf: url),
          let raw = String(data: data, encoding: .isoLatin1),
          let start = raw.range(of: "<?xml"),
          let end = raw.range(of: "</plist>"),
          let plistData = String(raw[start.lowerBound..<end.upperBound]).data(using: .utf8),
          let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
          let entitlements = plist["Entitlements"] as? [String: Any],
          let groups = entitlements["com.apple.security.application-groups"] as? [String] else {
        return []
    }
    return groups
}

public let APP_BUNDLE_ID: String = {
    guard let id = Bundle.main.bundleIdentifier, !id.isEmpty else {
        return "cn.easytier"
    }
    if Bundle.main.bundleURL.pathExtension == "appex",
       let dot = id.lastIndex(of: ".") {
        return String(id[..<dot])
    }
    return id
}()

public let TUNNEL_PROVIDER_BUNDLE_ID: String = {
    if let plugInsURL = Bundle.main.builtInPlugInsURL,
       let items = try? FileManager.default.contentsOfDirectory(at: plugInsURL, includingPropertiesForKeys: nil) {
        for url in items where url.pathExtension == "appex" {
            if let bundle = Bundle(url: url),
               let nsExt = bundle.infoDictionary?["NSExtension"] as? [String: Any],
               let point = nsExt["NSExtensionPointIdentifier"] as? String,
               point == "com.apple.networkextension.packet-tunnel",
               let id = bundle.bundleIdentifier, !id.isEmpty {
                return id
            }
        }
    }
    return "\(APP_BUNDLE_ID).tunnel"
}()

public let APP_GROUP_ID: String = {
    var candidates = ["group.\(APP_BUNDLE_ID)", "group.cn.easytier"]
    for group in provisioningAppGroups() where !candidates.contains(group) {
        candidates.append(group)
    }
    for candidate in candidates {
        if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: candidate) != nil {
            return candidate
        }
    }
    return candidates.first ?? "group.\(APP_BUNDLE_ID)"
}()

public let ICLOUD_CONTAINER_ID: String = "iCloud.\(APP_BUNDLE_ID)"
public let LOG_FILENAME: String = "easytier.log"
public let RUNNING_INFO_FILENAME: String = "running_info.json"
public let LAST_SETTINGS_FILENAME: String = "last_network_settings.json"
public let WEB_STATUS_FILENAME: String = "web_management_status.json"

public enum LogLevel: String, Codable, CaseIterable {
    case trace = "trace"
    case debug = "debug"
    case info = "info"
    case warn = "warn"
    case error = "error"
}

public enum EasyTierConnectionMode: String, Codable, CaseIterable {
    case local
    case web
}

public struct WebManagementOptions: Codable, Equatable {
    public var server: String
    public var machineID: String
    public var hostname: String
    public var secureMode: Bool

    public init(server: String = "", machineID: String = "", hostname: String = "", secureMode: Bool = false) {
        self.server = server
        self.machineID = machineID
        self.hostname = hostname
        self.secureMode = secureMode
    }

    private enum CodingKeys: String, CodingKey {
        case server, machineID, hostname, secureMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        server = try container.decode(String.self, forKey: .server)
        machineID = try container.decode(String.self, forKey: .machineID)
        hostname = try container.decode(String.self, forKey: .hostname)
        secureMode = try container.decodeIfPresent(Bool.self, forKey: .secureMode) ?? false
    }
}

public struct EasyTierOptions: Codable {
    public var mode: EasyTierConnectionMode = .local
    public var webManagement: WebManagementOptions?
    public var config: String = ""
    public var ipv4: String?
    public var ipv6: String?
    public var mtu: Int?
    public var routes: [String] = []
    public var logLevel: LogLevel = .info
    public var magicDNS: Bool = false
    public var dns: [String] = []

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case mode, webManagement, config, ipv4, ipv6, mtu, routes, logLevel, magicDNS, dns
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(EasyTierConnectionMode.self, forKey: .mode) ?? .local
        webManagement = try container.decodeIfPresent(WebManagementOptions.self, forKey: .webManagement)
        config = try container.decodeIfPresent(String.self, forKey: .config) ?? ""
        ipv4 = try container.decodeIfPresent(String.self, forKey: .ipv4)
        ipv6 = try container.decodeIfPresent(String.self, forKey: .ipv6)
        mtu = try container.decodeIfPresent(Int.self, forKey: .mtu)
        routes = try container.decodeIfPresent([String].self, forKey: .routes) ?? []
        logLevel = try container.decodeIfPresent(LogLevel.self, forKey: .logLevel) ?? .info
        magicDNS = try container.decodeIfPresent(Bool.self, forKey: .magicDNS) ?? false
        dns = try container.decodeIfPresent([String].self, forKey: .dns) ?? []
    }
}

public enum TunnelInstanceState: String, Codable {
    case idle
    case connectingServer = "connecting_server"
    case waitingConfig = "waiting_config"
    case starting
    case running
    case error
}

public struct TunnelInstanceOptions: Codable, Equatable {
    public var ipv4: String?
    public var ipv6: String?
    public var mtu: Int?
    public var routes: [String]
    public var magicDNS: Bool
    public var dns: [String]

    public func applying(to source: EasyTierOptions) -> EasyTierOptions {
        var result = source
        result.ipv4 = ipv4
        result.ipv6 = ipv6
        // Local profiles also contain host-only defaults (effective MTU and DNS).
        result.mtu = source.mode == .local ? (source.mtu ?? mtu) : mtu
        result.routes = routes
        result.magicDNS = magicDNS
        result.dns = source.mode == .local ? source.dns : dns
        return result
    }
}

public struct TunnelInstanceStatus: Codable, Equatable {
    public var status: TunnelInstanceState
    public var serverConnected: Bool
    public var instanceID: String?
    public var instanceName: String?
    public var networkName: String?
    public var generation: UInt64
    public var error: String?
    public var options: TunnelInstanceOptions?
}

public struct TunnelInstanceEvent: Codable, Equatable {
    public var event: String
    public var instanceID: String
    public var instanceName: String
    public var networkName: String
    public var generation: UInt64

    private enum CodingKeys: String, CodingKey {
        case event, generation
        case instanceID = "instance_id"
        case instanceName = "instance_name"
        case networkName = "network_name"
    }
}

public struct TunnelNetworkSettingsSnapshot: Codable, Equatable {
    public struct IPv4Subnet: Codable, Hashable {
        public var address: String
        public var subnetMask: String

        public init(address: String, subnetMask: String) {
            self.address = address
            self.subnetMask = subnetMask
        }
    }

    public struct IPv6Subnet: Codable, Hashable {
        public var address: String
        public var networkPrefixLength: Int

        public init(address: String, networkPrefixLength: Int) {
            self.address = address
            self.networkPrefixLength = networkPrefixLength
        }
    }

    public struct IPv4: Codable, Equatable {
        public var subnets: Set<IPv4Subnet>
        public var includedRoutes: Set<IPv4Subnet>?
        public var excludedRoutes: Set<IPv4Subnet>?

        public init(
            addresses: [String],
            subnetMasks: [String],
            includedRoutes: [IPv4Subnet]? = nil,
            excludedRoutes: [IPv4Subnet]? = nil
        ) {
            subnets = .init()
            for (index, address) in addresses.enumerated() {
                subnets.insert(
                    IPv4Subnet(address: address, subnetMask: subnetMasks[index])
                )
            }
            if let includedRoutes, !includedRoutes.isEmpty {
                self.includedRoutes = Set(includedRoutes)
            }
            if let excludedRoutes, !excludedRoutes.isEmpty {
                self.excludedRoutes = Set(excludedRoutes)
            }
        }
    }

    public struct IPv6: Codable, Equatable {
        public var subnets: Set<IPv6Subnet>
        public var includedRoutes: Set<IPv6Subnet>?
        public var excludedRoutes: Set<IPv6Subnet>?

        public init(
            addresses: [String],
            networkPrefixLengths: [Int],
            includedRoutes: [IPv6Subnet]? = nil,
            excludedRoutes: [IPv6Subnet]? = nil
        ) {
            subnets = .init()
            for (index, address) in addresses.enumerated() {
                subnets.insert(
                    IPv6Subnet(
                        address: address,
                        networkPrefixLength: networkPrefixLengths[index]
                    )
                )
            }
            if let includedRoutes {
                self.includedRoutes = Set(includedRoutes)
            }
            if let excludedRoutes {
                self.excludedRoutes = Set(excludedRoutes)
            }
        }
    }

    public struct DNS: Codable, Equatable {
        public var servers: Set<String>
        public var searchDomains: Set<String>?
        public var matchDomains: Set<String>?

        public init(
            servers: [String],
            searchDomains: [String]? = nil,
            matchDomains: [String]? = nil
        ) {
            self.servers = Set(servers)
            if let searchDomains {
                self.searchDomains = Set(searchDomains)
            }
            if let matchDomains {
                self.matchDomains = Set(matchDomains)
            }
        }
    }

    public var ipv4: IPv4?
    public var ipv6: IPv6?
    public var dns: DNS?
    public var mtu: UInt32?

    public init(ipv4: IPv4? = nil, ipv6: IPv6? = nil, dns: DNS? = nil, mtu: UInt32? = nil) {
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.dns = dns
        self.mtu = mtu
    }
}

public enum ProviderCommand: String, Codable, CaseIterable {
    case clearLog = "clear_log"
    case exportOSLog = "export_oslog"
    case runningInfo = "running_info"
    case lastNetworkSettings = "last_network_settings"
    case webManagementStatus = "web_management_status"
}

public enum TunnelManagerError: LocalizedError {
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "EasyTier VPN configuration is unavailable."
        }
    }
}

private func configureManagerForConnection(_ manager: NETunnelProviderManager, logger: Logger?) -> [String: NSObject]? {
    manager.isEnabled = true
    var startOptions: [String: NSObject]? = nil
    if let tunnelProtocol = manager.protocolConfiguration as? NETunnelProviderProtocol {
        if Bundle.main.bundleURL.pathExtension != "appex" {
            tunnelProtocol.providerBundleIdentifier = TUNNEL_PROVIDER_BUNDLE_ID
        }
        if let defaults = UserDefaults(suiteName: APP_GROUP_ID),
           let configData = defaults.data(forKey: "VPNConfig") {
            var providerConfig = tunnelProtocol.providerConfiguration ?? [:]
            providerConfig["VPNConfig"] = configData
            tunnelProtocol.providerConfiguration = providerConfig
            startOptions = ["VPNConfig": configData as NSData]
        }
    }
    if let defaults = UserDefaults(suiteName: APP_GROUP_ID) {
        manager.protocolConfiguration?.includeAllNetworks = defaults.bool(forKey: "includeAllNetworks")
        manager.protocolConfiguration?.excludeLocalNetworks = defaults.bool(forKey: "excludeLocalNetworks")
        if #available(iOS 16.4, macOS 13.3, *) {
            manager.protocolConfiguration?.excludeCellularServices = defaults.bool(forKey: "excludeCellularServices")
            manager.protocolConfiguration?.excludeAPNs = defaults.bool(forKey: "excludeAPNs")
        }
        if #available(iOS 17.4, macOS 14.4, *) {
            manager.protocolConfiguration?.excludeDeviceCommunication = defaults.bool(forKey: "excludeDeviceCommunication")
        }
        manager.protocolConfiguration?.enforceRoutes = defaults.bool(forKey: "enforceRoutes")
        if let logger {
            logger.debug("connect with protocol configuration: \(manager.protocolConfiguration)")
        }
    }
    return startOptions
}

public func connectWithManager(_ manager: NETunnelProviderManager, logger: Logger? = nil) async throws {
    let startOptions = configureManagerForConnection(manager, logger: logger)
    try await manager.saveToPreferences()
    try manager.connection.startVPNTunnel(options: startOptions)
}

public func connectWithManager(_ manager: NETunnelProviderManager, logger: Logger? = nil, completionHandler: (@Sendable ((any Error)?) -> Void)? = nil) {
    let startOptions = configureManagerForConnection(manager, logger: logger)
    manager.saveToPreferences() { error in
        if let error {
            completionHandler?(error)
            return
        }
        do {
            try manager.connection.startVPNTunnel(options: startOptions)
        } catch {
            completionHandler?(error)
            return
        }
        completionHandler?(nil)
    }
}
