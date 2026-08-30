import Foundation
import IOKit
import SystemConfiguration

struct DirectUSBRouteContext: Equatable, Sendable {
    let interfaceName: String
    let usbRegistryEntryID: UInt64
}

struct DirectUSBServiceDescriptor: Equatable, Sendable {
    let interfaceName: String
    let interfaceType: String
    let serviceName: String
    let displayName: String
    let isEnabled: Bool
}

protocol USBInterfaceInspecting: Sendable {
    func usbAncestorRegistryEntryID(interfaceName: String) -> UInt64?
}

struct IOKitUSBInterfaceInspector: USBInterfaceInspecting {
    private static let usbClassNames = [
        "IOUSBHostDevice",
        "IOUSBHostInterface",
        "IOUSBDevice",
        "IOUSBInterface",
    ]

    func usbAncestorRegistryEntryID(interfaceName: String) -> UInt64? {
        guard SafeConnectionValue.isHost(interfaceName),
              let matching = interfaceName.withCString({
                  IOBSDNameMatching(kIOMainPortDefault, 0, $0)
              }) else {
            return nil
        }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            matching,
            &iterator
        ) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { return nil }
            let ancestorID = Self.usbAncestorRegistryEntryID(startingAt: service)
            IOObjectRelease(service)
            if let ancestorID { return ancestorID }
        }
    }

    private static func usbAncestorRegistryEntryID(
        startingAt entry: io_registry_entry_t
    ) -> UInt64? {
        var current = entry
        var ownsCurrent = false

        while true {
            let isUSB = usbClassNames.contains { className in
                className.withCString { IOObjectConformsTo(current, $0) != 0 }
            }
            if isUSB {
                var entryID: UInt64 = 0
                let result = IORegistryEntryGetRegistryEntryID(current, &entryID)
                if ownsCurrent { IOObjectRelease(current) }
                return result == KERN_SUCCESS ? entryID : nil
            }

            var parent: io_registry_entry_t = 0
            let result = kIOServicePlane.withCString {
                IORegistryEntryGetParentEntry(current, $0, &parent)
            }
            if ownsCurrent { IOObjectRelease(current) }
            guard result == KERN_SUCCESS else { return nil }
            current = parent
            ownsCurrent = true
        }
    }
}

enum DirectUSBRouteVerification: Equatable, Sendable {
    case verified(DirectUSBRouteContext)
    case accessoryApprovalRequired
    case unavailable
    case unsafeRoute
}

private enum USBAccessoryAuthorizationInspector {
    private static let portClassName = "AppleHPMInterfaceType10"
    private static let usbTransportClassNames = [
        "IOPortTransportStateUSB2",
        "IOPortTransportStateUSB3",
    ]

    /// Apple silicon can keep a cable-visible USB-C port in Restricted Mode
    /// before it creates an IOUSBHostDevice. This is intentionally a best-effort
    /// read of the live I/O Registry: it never changes the Mac's accessory
    /// security policy or attempts to authorize a device on the owner's behalf.
    static func approvalIsRequired() -> Bool {
        guard let matching = IOServiceMatching(portClassName) else { return false }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            matching,
            &iterator
        ) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(iterator) }

        while true {
            let port = IOIteratorNext(iterator)
            guard port != 0 else { return false }
            defer { IOObjectRelease(port) }

            guard boolProperty("ConnectionActive", on: port),
                  stringProperty("IOAccessoryUSBConnectString", on: port) == "Device",
                  boolProperty("AuthorizationRequired", on: port),
                  hasBlockedUSBTransport(port) else {
                continue
            }
            return true
        }
    }

    private static func hasBlockedUSBTransport(
        _ port: io_registry_entry_t
    ) -> Bool {
        var iterator: io_iterator_t = 0
        guard kIOServicePlane.withCString({ plane in
            IORegistryEntryGetChildIterator(port, plane, &iterator)
        }) == KERN_SUCCESS else {
            return false
        }
        defer { IOObjectRelease(iterator) }

        var hasActiveUSBTransport = false
        var hasBlockedUSBTransport = false

        while true {
            let transport = IOIteratorNext(iterator)
            guard transport != 0 else {
                return hasBlockedUSBTransport && !hasActiveUSBTransport
            }
            defer { IOObjectRelease(transport) }

            let isUSBTransport = usbTransportClassNames.contains { className in
                className.withCString { IOObjectConformsTo(transport, $0) != 0 }
            }
            guard isUSBTransport else { continue }
            if boolProperty("Active", on: transport) {
                hasActiveUSBTransport = true
                continue
            }
            if boolProperty("AuthorizationRequired", on: transport),
               stringProperty("AuthorizationStatusDescription", on: transport) == "Unauthorized",
               boolProperty("TRM_TransportRestricted", on: transport) {
                hasBlockedUSBTransport = true
            }
        }
    }

    private static func boolProperty(
        _ key: String,
        on entry: io_registry_entry_t
    ) -> Bool {
        guard let value = IORegistryEntryCreateCFProperty(
            entry,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else {
            return false
        }
        return (value as? NSNumber)?.boolValue == true
    }

    private static func stringProperty(
        _ key: String,
        on entry: io_registry_entry_t
    ) -> String? {
        IORegistryEntryCreateCFProperty(
            entry,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String
    }
}

actor DirectUSBRouteVerifier {
    private static let routeExecutable = URL(filePath: "/sbin/route")
    private let processRegistry: OwnedProcessRegistry
    private let usbInterfaceInspector: any USBInterfaceInspecting

    init(
        processRegistry: OwnedProcessRegistry,
        usbInterfaceInspector: any USBInterfaceInspecting = IOKitUSBInterfaceInspector()
    ) {
        self.processRegistry = processRegistry
        self.usbInterfaceInspector = usbInterfaceInspector
    }

    func verify() async -> DirectUSBRouteVerification {
        let request = ProcessRequest(
            executableURL: Self.routeExecutable,
            arguments: ["-n", "get", DeviceProfile.requiredHostKeyAlias],
            generation: .make(),
            role: .pairingRouteCheck,
            outputLimit: 8_192
        )
        let result: ProcessExecutionResult
        do {
            result = try await processRegistry.run(request, timeout: .seconds(3))
        } catch {
            return USBAccessoryAuthorizationInspector.approvalIsRequired()
                ? .accessoryApprovalRequired
                : .unavailable
        }
        guard result.outcome == .exited(status: 0) else {
            return USBAccessoryAuthorizationInspector.approvalIsRequired()
                ? .accessoryApprovalRequired
                : .unavailable
        }
        guard !result.standardOutput.wasTruncated,
              let interfaceName = Self.parseDirectInterface(result.standardOutput.data) else {
            return USBAccessoryAuthorizationInspector.approvalIsRequired()
                ? .accessoryApprovalRequired
                : .unsafeRoute
        }
        guard let context = Self.eligibleUSBContext(
            interfaceName: interfaceName,
            services: Self.currentNetworkServices(),
            usbRegistryEntryID: usbInterfaceInspector.usbAncestorRegistryEntryID(
                interfaceName: interfaceName
            )
        ) else {
            return USBAccessoryAuthorizationInspector.approvalIsRequired()
                ? .accessoryApprovalRequired
                : .unsafeRoute
        }
        return .verified(context)
    }

    static func parseDirectInterface(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var destination: String?
        var interface: String?
        var flags: Set<String>?
        for line in text.split(whereSeparator: \Character.isNewline) {
            let fields = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard fields.count == 2 else { continue }
            switch fields[0] {
            case "destination": destination = fields[1]
            case "interface": interface = fields[1]
            case "flags":
                flags = Set(
                    fields[1]
                        .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
                )
            default: break
            }
        }
        guard let destination,
              destination == DeviceProfile.requiredHostKeyAlias ||
                destination.hasPrefix("10.11.99."),
              let interface,
              SafeConnectionValue.isHost(interface),
              let flags,
              flags.contains("UP"),
              !flags.contains("GATEWAY") else {
            return nil
        }
        return interface
    }

    static func eligibleUSBContext(
        interfaceName: String,
        services: [DirectUSBServiceDescriptor],
        usbRegistryEntryID: UInt64?
    ) -> DirectUSBRouteContext? {
        guard let usbRegistryEntryID,
              services.contains(where: { service in
                  guard service.interfaceName == interfaceName,
                        service.interfaceType == (kSCNetworkInterfaceTypeEthernet as String),
                        service.isEnabled else {
                      return false
                  }
                  let label = "\(service.serviceName) \(service.displayName)".lowercased()
                  return label.contains("remarkable") || label.contains("paper pro move")
              }) else {
            return nil
        }
        return DirectUSBRouteContext(
            interfaceName: interfaceName,
            usbRegistryEntryID: usbRegistryEntryID
        )
    }

    private static func currentNetworkServices() -> [DirectUSBServiceDescriptor] {
        guard let preferences = SCPreferencesCreate(
            nil,
            "com.ifixrobots.ReMarkableMirror.route-check" as CFString,
            nil
        ),
        let networkSet = SCNetworkSetCopyCurrent(preferences),
        let services = SCNetworkSetCopyServices(networkSet) as? [SCNetworkService] else {
            return []
        }

        return services.compactMap { service in
            guard let interface = SCNetworkServiceGetInterface(service),
                  let interfaceName = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let interfaceType = SCNetworkInterfaceGetInterfaceType(interface) as String?
            else {
                return nil
            }
            return DirectUSBServiceDescriptor(
                interfaceName: interfaceName,
                interfaceType: interfaceType,
                serviceName: (SCNetworkServiceGetName(service) as String?) ?? "",
                displayName: (SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?) ?? "",
                isEnabled: SCNetworkServiceGetEnabled(service)
            )
        }
    }
}
