import Foundation
import IOKit
import SystemConfiguration

/// Device identity for the "About this Mac" popover. During Setup Assistant
/// this is the only place anyone can look things up: there is no Finder, no
/// System Settings and no signed-in user, so a technician reading a serial
/// number off the screen — or checking the Mac is actually on the network —
/// has nowhere else to go.
public struct DeviceInfo: Equatable, Sendable {
    /// "MacBook Air (15-inch, M4, 2025)" when the device tree knows it.
    public let marketingName: String?
    public let computerName: String
    /// "Mac15,13"
    public let modelIdentifier: String
    /// "Apple M4"
    public let chip: String?
    public let memoryBytes: UInt64?
    public let storageBytes: Int64?
    public let serialNumber: String?
    /// "macOS 27.0 (26A428)"
    public let osVersion: String
    public let isOnline: Bool?

    public init(
        marketingName: String? = nil,
        computerName: String,
        modelIdentifier: String,
        chip: String? = nil,
        memoryBytes: UInt64? = nil,
        storageBytes: Int64? = nil,
        serialNumber: String?,
        osVersion: String,
        isOnline: Bool? = nil
    ) {
        self.marketingName = marketingName
        self.computerName = computerName
        self.modelIdentifier = modelIdentifier
        self.chip = chip
        self.memoryBytes = memoryBytes
        self.storageBytes = storageBytes
        self.serialNumber = serialNumber
        self.osVersion = osVersion
        self.isOnline = isOnline
    }

    // MARK: - Formatted

    /// Decimal GB, as the Mac's own About This Mac reports it.
    public var memory: String? {
        memoryBytes.map { $0.formatted(.byteCount(style: .memory)) }
    }

    public var storage: String? {
        storageBytes.map { $0.formatted(.byteCount(style: .file)) }
    }

    /// One line for a log or a footer. Org naming conventions often bake the
    /// serial into the computer name, and printing it twice just makes the
    /// line harder to read out loud.
    public var summary: String {
        var parts = [computerName, modelIdentifier]
        if let serialNumber, !computerName.contains(serialNumber) {
            parts.append(serialNumber)
        }
        parts.append(osVersion)
        return parts.joined(separator: " · ")
    }

    // MARK: - Current device

    public static func current() -> DeviceInfo {
        DeviceInfo(
            marketingName: deviceTreeString(path: "IODeviceTree:/product", key: "product-name"),
            computerName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            modelIdentifier: sysctlString("hw.model") ?? "Mac",
            chip: sysctlString("machdep.cpu.brand_string"),
            memoryBytes: sysctlValue(UInt64.self, "hw.memsize"),
            storageBytes: bootVolumeCapacity(),
            serialNumber: registryString(kIOPlatformSerialNumberKey),
            osVersion: operatingSystem(),
            isOnline: isNetworkReachable()
        )
    }

    /// The IOPlatformUUID — `%udid%` in `deviceNameTemplate`. Not a stored
    /// field: nothing displays it, only the namer asks.
    public static func platformUUID() -> String? {
        registryString(kIOPlatformUUIDKey)
    }

    // MARK: - Implementation

    private static func operatingSystem() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let short = "\(version.majorVersion).\(version.minorVersion)"
            + (version.patchVersion > 0 ? ".\(version.patchVersion)" : "")
        if let build = sysctlString("kern.osversion") {
            return "macOS \(short) (\(build))"
        }
        return "macOS \(short)"
    }

    private static func bootVolumeCapacity() -> Int64? {
        let values = try? URL(filePath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey])
        return values?.volumeTotalCapacity.map(Int64.init)
    }

    /// Reachability only — whether the stack thinks it can route somewhere.
    /// Deliberately not a speed test: this runs while Installomator is pulling
    /// gigabytes, and competing for that bandwidth to draw a number would be
    /// a poor trade.
    private static func isNetworkReachable() -> Bool? {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)

        let reachability = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                SCNetworkReachabilityCreateWithAddress(nil, $0)
            }
        }
        guard let reachability else { return nil }

        var flags = SCNetworkReachabilityFlags()
        guard SCNetworkReachabilityGetFlags(reachability, &flags) else { return nil }
        return flags.contains(.reachable) && !flags.contains(.connectionRequired)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        if let terminator = buffer.firstIndex(of: 0) {
            buffer.removeSubrange(terminator...)
        }
        let value = String(decoding: buffer, as: UTF8.self)
        return value.isEmpty ? nil : value
    }

    private static func sysctlValue<T>(_ type: T.Type, _ name: String) -> T? {
        var value = [UInt8](repeating: 0, count: MemoryLayout<T>.size)
        var size = MemoryLayout<T>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value.withUnsafeBytes { $0.loadUnaligned(as: T.self) }
    }

    private static func registryString(_ key: String) -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return property(of: service, key: key)
    }

    /// The marketing name ("MacBook Pro (14-inch, Nov 2023)") lives at
    /// `IODeviceTree:/product`, *not* on IOPlatformExpertDevice — checked on
    /// hardware, where the latter returns nothing. Values arrive as
    /// null-terminated data rather than strings.
    private static func deviceTreeString(path: String, key: String) -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, path)
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        return property(of: entry, key: key)
    }

    private static func property(of entry: io_registry_entry_t, key: String) -> String? {
        guard let value = IORegistryEntryCreateCFProperty(
            entry, key as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else { return nil }

        if let string = value as? String {
            return string.isEmpty ? nil : string
        }
        if let data = value as? Data {
            let text = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
            return text.isEmpty ? nil : text
        }
        return nil
    }
}
