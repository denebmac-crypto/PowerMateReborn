import Foundation
import Combine

/// Persistent registry for physical PowerMates and reusable Profiles.
final class PowerMateConfigurationStore: ObservableObject {
    static let shared = PowerMateConfigurationStore()

    @Published private(set) var configuration: PowerMateConfiguration
    @Published private(set) var connectedIdentities: Set<PowerMateHardwareIdentity> = []

    private let userDefaultsKey = "powermate.deviceProfiles.configuration"

    private init() {
        if
            let data = UserDefaults.standard.data(forKey: userDefaultsKey),
            let decoded = try? JSONDecoder().decode(
                PowerMateConfiguration.self,
                from: data
            )
        {
            configuration = decoded
        } else {
            configuration = PowerMateConfiguration()
            configuration.profiles = [Self.makeEmptyProfile(name: "Default Profile")]
            persist()
        }
    }

    /// One-time migration bridge from the existing Custom Mode profile library.
    /// It preserves existing mappings when the reusable device-profile system is introduced.
    func seedDefaultProfileIfNeeded(from legacyProfiles: [CodableAppProfile]) {
        guard
            configuration.profiles.count == 1,
            configuration.profiles[0].name == "Default Profile"
        else {
            return
        }

        let current = configuration.profiles[0].appProfiles
        let hasConfiguredAction = current.contains { app in
            app.rotateLeft.type != .unassigned ||
            app.rotateRight.type != .unassigned ||
            app.singleClick.type != .unassigned ||
            app.doubleClick.type != .unassigned ||
            app.longPressAction.type != .unassigned
        }

        guard !hasConfiguredAction, !legacyProfiles.isEmpty else {
            return
        }

        configuration.profiles[0].appProfiles = legacyProfiles
        persist()
        NSLog(
            "Config: seeded Default Profile from %d existing Custom Mode profile(s)",
            legacyProfiles.count
        )
    }

    // MARK: - Devices

    @discardableResult
    func registerDevice(
        identity: PowerMateHardwareIdentity
    ) -> PowerMateDevice {
        if let existing = configuration.devices.first(
            where: { $0.hardwareIdentity == identity }
        ) {
            return existing
        }

        let profileID = configuration.profiles.first?.id
        let device = PowerMateDevice(
            name: nextDeviceName(),
            transportType: identity.transportType,
            hardwareIdentity: identity,
            assignedProfileID: profileID
        )

        configuration.devices.append(device)
        persist()

        NSLog(
            "Config: registered device '%@' (%@)",
            device.name,
            identity.identifier
        )

        return device
    }

    func markConnected(_ identity: PowerMateHardwareIdentity) {
        connectedIdentities.insert(identity)
    }

    func markDisconnected(_ identity: PowerMateHardwareIdentity) {
        connectedIdentities.remove(identity)
    }

    func device(
        for identity: PowerMateHardwareIdentity
    ) -> PowerMateDevice? {
        configuration.devices.first {
            $0.hardwareIdentity == identity
        }
    }

    func renameDevice(
        id: UUID,
        name: String
    ) {
        guard let index = configuration.devices.firstIndex(
            where: { $0.id == id }
        ) else {
            return
        }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        configuration.devices[index].name = trimmed
        persist()
    }

    func assignProfile(
        _ profileID: UUID?,
        toDeviceID deviceID: UUID
    ) {
        guard let index = configuration.devices.firstIndex(
            where: { $0.id == deviceID }
        ) else {
            return
        }

        configuration.devices[index].assignedProfileID = profileID
        persist()
    }

    func forgetDevice(id: UUID) {
        configuration.devices.removeAll { $0.id == id }
        persist()
    }

    // MARK: - Profiles

    @discardableResult
    func createProfile(name: String = "New Profile") -> PowerMateProfile {
        let profile = Self.makeEmptyProfile(name: name)
        configuration.profiles.append(profile)
        persist()
        return profile
    }

    @discardableResult
    func duplicateProfile(id: UUID) -> PowerMateProfile? {
        guard let source = profile(id: id) else {
            return nil
        }

        var copy = source
        copy.id = UUID()
        copy.name = source.name + " Copy"
        configuration.profiles.append(copy)
        persist()
        return copy
    }

    func updateProfile(_ profile: PowerMateProfile) {
        guard let index = configuration.profiles.firstIndex(
            where: { $0.id == profile.id }
        ) else {
            return
        }

        configuration.profiles[index] = profile
        persist()
    }

    func deleteProfile(id: UUID) {
        guard configuration.profiles.count > 1 else {
            return
        }

        configuration.profiles.removeAll { $0.id == id }

        let fallbackID = configuration.profiles.first?.id
        for index in configuration.devices.indices {
            if configuration.devices[index].assignedProfileID == id {
                configuration.devices[index].assignedProfileID = fallbackID
            }
        }

        persist()
    }

    func profile(id: UUID?) -> PowerMateProfile? {
        guard let id else { return nil }
        return configuration.profiles.first { $0.id == id }
    }

    func profile(for identity: PowerMateHardwareIdentity) -> PowerMateProfile? {
        guard let device = device(for: identity) else {
            return nil
        }

        return profile(id: device.assignedProfileID)
    }

    // MARK: - Persistence

    private func persist() {
        do {
            let data = try JSONEncoder().encode(configuration)
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
            objectWillChange.send()
        } catch {
            NSLog(
                "Config: failed to save device/profile configuration: %@",
                error.localizedDescription
            )
        }
    }

    private func nextDeviceName() -> String {
        let existing = Set(configuration.devices.map { $0.name })

        for scalar in Unicode.Scalar("A").value...Unicode.Scalar("Z").value {
            let suffix = String(UnicodeScalar(scalar)!)
            let candidate = "PowerMate " + suffix
            if !existing.contains(candidate) {
                return candidate
            }
        }

        return "PowerMate " + String(configuration.devices.count + 1)
    }

    private static func makeEmptyProfile(
        name: String
    ) -> PowerMateProfile {
        let global = CodableAppProfile(
            name: "Global Default",
            isGlobal: true,
            bundleIdentifier: nil,
            iconName: "globe"
        )

        return PowerMateProfile(
            name: name,
            appProfiles: [global]
        )
    }
}
