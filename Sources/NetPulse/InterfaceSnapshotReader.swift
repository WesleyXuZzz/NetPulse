import Foundation
import SystemConfiguration

struct InterfaceOption: Identifiable, Hashable {
    let id: String
    let displayName: String
    let summaryName: String
}

struct InterfaceSnapshot {
    let rxBytes: UInt64
    let txBytes: UInt64
    let sampledInterfaces: [InterfaceOption]
    let availableInterfaces: [InterfaceOption]
}

enum InterfaceSnapshotReader {
    static func read(selectedInterfaceName: String?) -> InterfaceSnapshot {
        var addressList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressList) == 0, let firstAddress = addressList else {
            return InterfaceSnapshot(rxBytes: 0, txBytes: 0, sampledInterfaces: [], availableInterfaces: [])
        }
        defer { freeifaddrs(addressList) }

        var rxBytes: UInt64 = 0
        var txBytes: UInt64 = 0
        var sampledInterfaceIDs = Set<String>()
        var availableInterfaceIDs = Set<String>()

        for pointer in sequence(first: firstAddress, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let rawAddress = interface.ifa_addr else { continue }
            guard rawAddress.pointee.sa_family == UInt8(AF_LINK) else { continue }

            let name = String(cString: interface.ifa_name)
            guard isSupportedInterface(named: name) else { continue }
            availableInterfaceIDs.insert(name)

            if let selectedInterfaceName, selectedInterfaceName != name {
                continue
            }

            let flags = Int32(interface.ifa_flags)
            guard (flags & IFF_UP) != 0 else { continue }
            guard (flags & IFF_RUNNING) != 0 else { continue }
            guard (flags & IFF_LOOPBACK) == 0 else { continue }

            guard let dataPointer = interface.ifa_data?.assumingMemoryBound(to: if_data.self) else {
                continue
            }

            let interfaceData = dataPointer.pointee
            rxBytes += UInt64(interfaceData.ifi_ibytes)
            txBytes += UInt64(interfaceData.ifi_obytes)
            sampledInterfaceIDs.insert(name)
        }

        let availableInterfaces = InterfaceDisplayNameResolver.resolve(ids: availableInterfaceIDs)
        let sampledInterfaces = InterfaceDisplayNameResolver.resolve(ids: sampledInterfaceIDs)

        return InterfaceSnapshot(
            rxBytes: rxBytes,
            txBytes: txBytes,
            sampledInterfaces: sampledInterfaces,
            availableInterfaces: availableInterfaces
        )
    }

    static func isSupportedInterface(named name: String) -> Bool {
        guard name.hasPrefix("en") else {
            return false
        }

        let excludedPrefixes = [
            "awdl",
            "llw",
            "lo",
            "utun",
            "vmnet",
            "vnic",
        ]

        return !excludedPrefixes.contains(where: { name.hasPrefix($0) })
    }
}

private enum InterfaceDisplayNameResolver {
    static func resolve(ids: Set<String>) -> [InterfaceOption] {
        let resolvedOptions = loadOptions()

        return ids.sorted().map { id in
            resolvedOptions[id] ?? InterfaceOption(id: id, displayName: id, summaryName: id)
        }
    }

    private static func loadOptions() -> [String: InterfaceOption] {
        var refreshedOptions: [String: InterfaceOption] = [:]
        if let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for interface in interfaces {
                collect(interface, into: &refreshedOptions)
            }
        }

        return refreshedOptions
    }

    private static func collect(_ interface: SCNetworkInterface, into options: inout [String: InterfaceOption]) {
        if let bsdName = SCNetworkInterfaceGetBSDName(interface) as String? {
            let localizedName = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
            options[bsdName] = makeOption(id: bsdName, localizedName: localizedName)
        }

        if let child = SCNetworkInterfaceGetInterface(interface) {
            collect(child, into: &options)
        }
    }

    private static func makeOption(id: String, localizedName: String?) -> InterfaceOption {
        let cleanLocalizedName = localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let cleanLocalizedName, !cleanLocalizedName.isEmpty, cleanLocalizedName != id {
            return InterfaceOption(
                id: id,
                displayName: "\(cleanLocalizedName) (\(id))",
                summaryName: cleanLocalizedName
            )
        }

        return InterfaceOption(id: id, displayName: id, summaryName: id)
    }
}
