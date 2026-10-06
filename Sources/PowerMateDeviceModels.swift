import Foundation

// MARK: - PowerMate Transport Type

enum PowerMateTransportType: String, Codable, CaseIterable, Identifiable {
    case usb
    case bluetooth

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .usb:
            return "USB"
        case .bluetooth:
            return "Bluetooth"
        }
    }
}

// MARK: - Hardware Identity

/// Identifies the currently connected physical PowerMate.
///
/// USB uses the IORegistry Location ID because the Griffin USB PowerMate
/// does not expose a useful serial number on macOS.
///
/// Bluetooth uses CBPeripheral.identifier (UUID).
///
/// IMPORTANT:
/// This identity belongs to the Device record, not to a Profile.
/// A PowerMate appearing at a new USB location therefore becomes a
/// new Device while existing Profiles remain untouched.
enum PowerMateHardwareIdentity: Codable, Hashable {
    case usb(locationID: String)
    case bluetooth(peripheralUUID: String)

    var transportType: PowerMateTransportType {
        switch self {
        case .usb:
            return .usb
        case .bluetooth:
            return .bluetooth
        }
    }

    var identifier: String {
        switch self {
        case .usb(let locationID):
            return locationID
        case .bluetooth(let peripheralUUID):
            return peripheralUUID
        }
    }
}

// MARK: - Profile

/// A reusable PowerMate configuration.
struct PowerMateProfile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()

    /// User-editable display name.
    var name: String

    /// User-editable accent color stored as a hex string.
    var colorHex: String = "#4A90E2"

    /// Per-application mappings.
    ///
    /// Each CodableAppProfile represents one application's mapping.
    /// A global mapping can also be represented by isGlobal == true.
    var appProfiles: [CodableAppProfile] = []

    init(
        id: UUID = UUID(),
        name: String,
        colorHex: String = "#4A90E2",
        appProfiles: [CodableAppProfile] = []
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.appProfiles = appProfiles
    }
}

// MARK: - Device

/// A physical PowerMate known to the application.
struct PowerMateDevice: Codable, Identifiable, Equatable {
    var id: UUID = UUID()

    /// User-editable device name.
    var name: String

    /// Hardware transport used by this device.
    var transportType: PowerMateTransportType

    /// Current hardware identity.
    var hardwareIdentity: PowerMateHardwareIdentity

    /// ID of the reusable Profile assigned to this device.
    var assignedProfileID: UUID?

    /// User-editable accent color for the device itself.
    /// This is independent from the Profile color.
    var colorHex: String = "#4A90E2"

    init(
        id: UUID = UUID(),
        name: String,
        transportType: PowerMateTransportType,
        hardwareIdentity: PowerMateHardwareIdentity,
        assignedProfileID: UUID? = nil,
        colorHex: String = "#4A90E2"
    ) {
        self.id = id
        self.name = name
        self.transportType = transportType
        self.hardwareIdentity = hardwareIdentity
        self.assignedProfileID = assignedProfileID
        self.colorHex = colorHex
    }
}

// MARK: - Persistent Configuration Container

/// Root object for the new device/profile configuration.
struct PowerMateConfiguration: Codable, Equatable {
    var devices: [PowerMateDevice] = []
    var profiles: [PowerMateProfile] = []
}
