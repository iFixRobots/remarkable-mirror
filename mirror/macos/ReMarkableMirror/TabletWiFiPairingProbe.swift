import Foundation

enum TabletWiFiPairingProbeError: Error, Equatable, Sendable {
    case usbRouteRequired
    case wifiRouteRequired
    case boundInterfaceRequired
    case unsafeWiFiHost
    case processFailed
    case truncatedOutput
    case unexpectedStandardError
    case malformedOutput
    case capabilityMismatch
}

enum TabletWiFiPairingApproval: Equatable, Sendable {
    case ownerApproved
}

enum TabletWiFiSSHEnableVerification: Equatable, Sendable {
    case verified
}

struct TabletWiFiDiscovery: Equatable, Sendable {
    let savedNetworkCount: Int
    let activeWLAN0Count: Int
    let globalIPv4Host: String?

    var isReady: Bool {
        savedNetworkCount > 0 && activeWLAN0Count == 1 && globalIPv4Host != nil
    }
}

/// Builds opt-in pairing requests and parses their bounded results. This type
/// intentionally has no process runner and therefore cannot contact or mutate
/// a tablet on construction.
enum TabletWiFiPairingProbe {
    static let discoveryOutputLimit = 1_024
    static let enableOutputLimit = 256
    static let wakeTokenOutputLimit = 65
    static let verificationOutputLimit = 4_096

    // Derived from interface state alone: tablet software differs on the
    // network manager it ships (3.27 has no nmcli), but a global IPv4 on
    // wlan0 proves a joined network on all of them.
    static let discoveryCommand = #"""
        set -eu
        wifi_address_rows=$(ip -4 -o address show dev wlan0 scope global 2>/dev/null) || exit 94
        wifi_addresses=$(printf '%s\n' "$wifi_address_rows" | awk '{ split($4, address, "/"); print address[1] }') || exit 95
        global_ipv4_count=$(printf '%s\n' "$wifi_addresses" | awk 'NF { count++ } END { print count + 0 }') || exit 96
        wifi_host=$(printf '%s\n' "$wifi_addresses" | awk 'NF { print; exit }') || exit 97
        active_count=0
        if [ "$global_ipv4_count" -gt 0 ]; then
          active_count=1
        fi
        printf '%s\n' \
          "SAVED_COUNT=$active_count" \
          "ACTIVE_COUNT=$active_count" \
          "GLOBAL_IPV4_COUNT=$global_ipv4_count" \
          "WIFI_HOST=$wifi_host"
        """#

    static let enableCommand = #"""
        set -eu
        rm-ssh-over-wlan on >/dev/null
        # Some tablet software enables the socket without starting it.
        systemctl start dropbear-wlan.socket
        systemctl is-active --quiet dropbear-wlan.socket
        printf '%s\n' 'RMMIRROR_WIFI_SSH=enabled'
        """#

    static let wakeTokenCommand = #"""
        set -eu
        token=/data/rmmirror/wake-token
        test "$(wc -c < "$token")" -eq 64
        LC_ALL=C grep -Eq '^[0-9a-fA-F]{64}$' "$token"
        command -v busybox >/dev/null 2>&1
        wake_token=$(cat "$token")
        response=$({
          printf 'GET /v1/status HTTP/1.1\r\n'
          printf 'Host: 127.0.0.1:51337\r\n'
          printf 'Authorization: Bearer %s\r\n' "$wake_token"
          printf 'Connection: close\r\n\r\n'
        } | busybox nc 127.0.0.1 51337)
        status_line=$(printf '%s\n' "$response" | awk 'NR == 1 { sub(/\r$/, ""); print }')
        case "$status_line" in
          'HTTP/1.1 200 '*|'HTTP/1.0 200 '*) ;;
          *) exit 98 ;;
        esac
        body=$(printf '%s\n' "$response" | awk 'body { print } /^\r?$/ { body = 1 }')
        printf '%s\n' "$body" | LC_ALL=C grep -Eq '"schema"[[:space:]]*:[[:space:]]*"rmmirror[.]wake/v1"'
        printf '%s\n' "$body" | LC_ALL=C grep -Eq '"state"[[:space:]]*:[[:space:]]*"(unlock_required|sleeping|ready|starting)"'
        printf '%s\n' "$wake_token"
        """#

    static let verificationCommand = #"""
        set -eu
        \#(TabletCapabilityProbeContract.captureCommand)

        printf '%s\n' 'RMMIRROR_WIFI=verified'
        \#(TabletCapabilityProbeContract.outputCommand)
        """#

    private static let discoveryKeys = [
        "SAVED_COUNT",
        "ACTIVE_COUNT",
        "GLOBAL_IPV4_COUNT",
        "WIFI_HOST",
    ]
    private static let verificationKeys = ["RMMIRROR_WIFI"] +
        TabletCapabilityProbeContract.orderedKeys

    static func discoveryRequest(
        usbRoute: SSHRoute,
        generation: GenerationID
    ) throws -> ProcessRequest {
        try validateUSBRoute(usbRoute)
        return request(
            route: usbRoute,
            generation: generation,
            role: .wifiPairingDiscovery,
            outputLimit: discoveryOutputLimit,
            command: discoveryCommand
        )
    }

    static func enableRequest(
        usbRoute: SSHRoute,
        generation: GenerationID,
        approval: TabletWiFiPairingApproval
    ) throws -> ProcessRequest {
        try validateUSBRoute(usbRoute)
        switch approval {
        case .ownerApproved:
            break
        }
        return request(
            route: usbRoute,
            generation: generation,
            role: .wifiPairingEnable,
            outputLimit: enableOutputLimit,
            command: enableCommand
        )
    }

    static func wakeTokenRequest(
        usbRoute: SSHRoute,
        generation: GenerationID
    ) throws -> ProcessRequest {
        try validateUSBRoute(usbRoute)
        return request(
            route: usbRoute,
            generation: generation,
            role: .wifiPairingWakeToken,
            outputLimit: wakeTokenOutputLimit,
            command: wakeTokenCommand
        )
    }

    static func verificationRequest(
        wifiRoute: SSHRoute,
        generation: GenerationID
    ) throws -> ProcessRequest {
        guard wifiRoute.kind == .wifi else {
            throw TabletWiFiPairingProbeError.wifiRouteRequired
        }
        guard wifiRoute.boundInterface != nil else {
            throw TabletWiFiPairingProbeError.boundInterfaceRequired
        }
        guard isGlobalIPv4Host(wifiRoute.host) else {
            throw TabletWiFiPairingProbeError.unsafeWiFiHost
        }
        return request(
            route: wifiRoute,
            generation: generation,
            role: .wifiPairingVerification,
            outputLimit: verificationOutputLimit,
            command: verificationCommand
        )
    }

    static func parseDiscovery(
        _ result: ProcessExecutionResult
    ) throws -> TabletWiFiDiscovery {
        let values = try parse(
            result,
            expectedKeys: discoveryKeys,
            maximumBytes: discoveryOutputLimit
        )
        guard let savedCount = boundedCount(values["SAVED_COUNT"]),
              let activeCount = boundedCount(values["ACTIVE_COUNT"]),
              let globalIPv4Count = boundedCount(values["GLOBAL_IPV4_COUNT"]),
              activeCount <= 1,
              globalIPv4Count <= 1,
              let hostValue = values["WIFI_HOST"] else {
            throw TabletWiFiPairingProbeError.malformedOutput
        }

        let host: String?
        switch globalIPv4Count {
        case 0:
            guard hostValue.isEmpty else {
                throw TabletWiFiPairingProbeError.malformedOutput
            }
            host = nil
        case 1:
            guard isGlobalIPv4Host(hostValue) else {
                throw TabletWiFiPairingProbeError.unsafeWiFiHost
            }
            host = hostValue
        default:
            throw TabletWiFiPairingProbeError.malformedOutput
        }

        guard !(savedCount == 0 && activeCount > 0),
              !(activeCount == 0 && host != nil) else {
            throw TabletWiFiPairingProbeError.malformedOutput
        }
        return TabletWiFiDiscovery(
            savedNetworkCount: savedCount,
            activeWLAN0Count: activeCount,
            globalIPv4Host: host
        )
    }

    static func parseEnableVerification(
        _ result: ProcessExecutionResult
    ) throws -> TabletWiFiSSHEnableVerification {
        let values = try parse(
            result,
            expectedKeys: ["RMMIRROR_WIFI_SSH"],
            maximumBytes: enableOutputLimit
        )
        guard values["RMMIRROR_WIFI_SSH"] == "enabled" else {
            throw TabletWiFiPairingProbeError.malformedOutput
        }
        return .verified
    }

    static func parseWakeToken(_ result: ProcessExecutionResult) throws -> Data {
        try validateSuccessfulResult(result)
        let data = result.standardOutput.data
        guard data.count == wakeTokenOutputLimit,
              data.last == 0x0A else {
            throw TabletWiFiPairingProbeError.malformedOutput
        }
        let token = data.dropLast()
        guard token.allSatisfy(Self.isASCIIHexDigit) else {
            throw TabletWiFiPairingProbeError.malformedOutput
        }
        return Data(token)
    }

    static func parseWiFiVerification(
        _ result: ProcessExecutionResult,
        matching usbCapability: PassiveRouteCapability
    ) throws -> PassiveRouteCapability {
        let values = try parse(
            result,
            expectedKeys: verificationKeys,
            maximumBytes: verificationOutputLimit
        )
        guard values["RMMIRROR_WIFI"] == "verified",
              let capability = PassiveRouteCapability.parse(result.standardOutput.data) else {
            throw TabletWiFiPairingProbeError.malformedOutput
        }
        guard usbCapability.meetsRuntimeContract,
              usbCapability.transportOperational,
              capability.meetsRuntimeContract,
              capability.transportOperational,
              capability.matchesTabletIdentity(usbCapability) else {
            throw TabletWiFiPairingProbeError.capabilityMismatch
        }
        return capability
    }

    static func isGlobalIPv4Host(_ value: String) -> Bool {
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 4 else { return false }
        var octets: [UInt8] = []
        octets.reserveCapacity(4)
        for field in fields {
            guard !field.isEmpty,
                  field.count <= 3,
                  field.allSatisfy({ $0.isASCII && $0.isNumber }),
                  !(field.count > 1 && field.first == "0"),
                  let octet = UInt8(field) else {
                return false
            }
            octets.append(octet)
        }
        guard octets[0] != 0,
              octets[0] != 127,
              !(octets[0] == 169 && octets[1] == 254),
              octets[0] < 224 else {
            return false
        }
        return true
    }

    private static func validateUSBRoute(_ route: SSHRoute) throws {
        guard route.kind == .usb,
              route.host == DeviceProfile.requiredHostKeyAlias else {
            throw TabletWiFiPairingProbeError.usbRouteRequired
        }
        guard route.boundInterface != nil else {
            throw TabletWiFiPairingProbeError.boundInterfaceRequired
        }
    }

    private static func request(
        route: SSHRoute,
        generation: GenerationID,
        role: ProcessRole,
        outputLimit: Int,
        command: String
    ) -> ProcessRequest {
        let arguments = route.baseArguments + [
            "-o", "VerifyHostKeyDNS=no",
            "-o", "ConnectionAttempts=1",
            "-o", "NumberOfPasswordPrompts=0",
            "-o", "LogLevel=ERROR",
            "-T", "root@\(route.host)", command,
        ]
        return ProcessRequest(
            executableURL: SSHRoute.executableURL,
            arguments: arguments,
            generation: generation,
            role: role,
            outputLimit: outputLimit
        )
    }

    private static func parse(
        _ result: ProcessExecutionResult,
        expectedKeys: [String],
        maximumBytes: Int
    ) throws -> [String: String] {
        try validateSuccessfulResult(result)
        let data = result.standardOutput.data
        guard !data.isEmpty,
              data.count <= maximumBytes,
              data.last == 0x0A,
              let output = String(data: data, encoding: .utf8),
              !output.contains("\r"),
              !output.contains("\0") else {
            throw TabletWiFiPairingProbeError.malformedOutput
        }

        let body = output.dropLast()
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count == expectedKeys.count else {
            throw TabletWiFiPairingProbeError.malformedOutput
        }
        var values: [String: String] = [:]
        for (line, expectedKey) in zip(lines, expectedKeys) {
            let prefix = "\(expectedKey)="
            guard line.hasPrefix(prefix) else {
                throw TabletWiFiPairingProbeError.malformedOutput
            }
            let value = String(line.dropFirst(prefix.count))
            guard values.updateValue(value, forKey: expectedKey) == nil else {
                throw TabletWiFiPairingProbeError.malformedOutput
            }
        }
        return values
    }

    private static func validateSuccessfulResult(
        _ result: ProcessExecutionResult
    ) throws {
        guard case .exited(status: 0) = result.outcome else {
            throw TabletWiFiPairingProbeError.processFailed
        }
        guard !result.standardOutput.wasTruncated,
              !result.standardError.wasTruncated else {
            throw TabletWiFiPairingProbeError.truncatedOutput
        }
        guard result.standardError.data.isEmpty else {
            throw TabletWiFiPairingProbeError.unexpectedStandardError
        }
    }

    private static func isASCIIHexDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }

    private static func boundedCount(_ value: String?) -> Int? {
        guard let value,
              !value.isEmpty,
              value.count <= 4,
              value.allSatisfy({ $0.isASCII && $0.isNumber }),
              !(value.count > 1 && value.first == "0"),
              let count = Int(value),
              count <= 1_024 else {
            return nil
        }
        return count
    }
}
