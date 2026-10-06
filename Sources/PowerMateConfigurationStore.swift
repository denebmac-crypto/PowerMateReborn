import Foundation
import Combine

/// Persistent registry for physical PowerMates and reusable Profiles.
///
/// Profiles are independent settings. Devices only remember which Profile
/// is assigned to them. Hardware registration is based on the transport
/// identity; USB uses locationID because the Griffin PowerMate does not expose
/// a stable USB serial number.
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
            normalizeConfiguration()
        } else {
            configuration = PowerMateConfiguration()
            configuration.profiles = [Self.makeEmptyProfile(name: "Default Profile")]
            persist()
        }
    }

    /// One-time bridge from the legacy Custom Mode profile library.
    /// This only fills an otherwise empty first profile; it never creates
    /// device-owned copies of application mappings.
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
            "Config: seeded Default Profile from %d legacy Custom Mode profile(s)",
            legacyProfiles.count
        )
    }

    // MARK: - Devices

    /// Registers a physical PowerMate if its hardware identity is new.
    ///
    /// A new device is intentionally left unassigned. The user chooses its
    /// Profile from the Profile detail view. No Profile is cloned here.
    @discardableResult
    func registerDevice(
        identity: PowerMateHardwareIdentity
    ) -> PowerMateDevice {
        if let index = configuration.devices.firstIndex(
            where: { $0.hardwareIdentity == identity }
        ) {
            configuration.devices[index].transportType = identity.transportType
            persist()
            return configuration.devices[index]
        }

        let deviceName = nextDeviceName()
        let device = PowerMateDevice(
            name: deviceName,
            transportType: identity.transportType,
            hardwareIdentity: identity,
            assignedProfileID: nil
        )

        configuration.devices.append(device)
        persist()

        NSLog(
            "Config: registered hardware '%@' (%@)",
            device.name,
            identity.identifier
        )

        return device
    }

    func markConnected(_ identity: PowerMateHardwareIdentity) {
        connectedIdentities.insert(identity)
        objectWillChange.send()
    }

    func markDisconnected(_ identity: PowerMateHardwareIdentity) {
        connectedIdentities.remove(identity)
        objectWillChange.send()
    }

    func device(
        for identity: PowerMateHardwareIdentity
    ) -> PowerMateDevice? {
        configuration.devices.first {
            $0.hardwareIdentity == identity
        }
    }

    func device(id: UUID) -> PowerMateDevice? {
        configuration.devices.first { $0.id == id }
    }

    /// Assigns one Profile to a Device.
    ///
    /// A Profile is intentionally assigned to at most one Device at a time,
    /// matching the UI's single "Select PowerMate" relationship. Reassigning
    /// a Profile or Device simply moves the assignment; existing Profile data
    /// is never copied or deleted.
    func assignProfile(
        _ profileID: UUID?,
        toDeviceID deviceID: UUID
    ) {
        guard let deviceIndex = configuration.devices.firstIndex(where: { $0.id == deviceID }) else {
            return
        }

        if let profileID {
            guard configuration.profiles.contains(where: { $0.id == profileID }) else {
                return
            }

            for index in configuration.devices.indices
                where configuration.devices[index].assignedProfileID == profileID {
                configuration.devices[index].assignedProfileID = nil
            }
        }

        configuration.devices[deviceIndex].assignedProfileID = profileID
        persist()

        NSLog(
            "Config: %@ -> %@",
            configuration.devices[deviceIndex].name,
            profileID?.uuidString ?? "Unassigned"
        )
    }

    /// Assigns a Device to a Profile. This is the inverse operation used by
    /// the Profile detail view.
    func assignDevice(
        _ deviceID: UUID?,
        toProfileID profileID: UUID
    ) {
        guard configuration.profiles.contains(where: { $0.id == profileID }) else {
            return
        }

        // Release this Profile from any existing Device first.
        for index in configuration.devices.indices
            where configuration.devices[index].assignedProfileID == profileID {
            configuration.devices[index].assignedProfileID = nil
        }

        guard let deviceID else {
            persist()
            return
        }

        guard let deviceIndex = configuration.devices.firstIndex(where: { $0.id == deviceID }) else {
            return
        }

        // Moving a Device to this Profile also releases whatever Profile it
        // previously used. The old Profile itself remains intact.
        configuration.devices[deviceIndex].assignedProfileID = profileID
        persist()

        NSLog(
            "Config: %@ assigned to Profile %@",
            configuration.devices[deviceIndex].name,
            profileID.uuidString
        )
    }

    func assignedDevice(for profileID: UUID) -> PowerMateDevice? {
        configuration.devices.first {
            $0.assignedProfileID == profileID
        }
    }

    /// Forget only the hardware record. The assigned Profile remains intact.
    ///
    /// This lets the user clean up accumulated USB-location records without
    /// losing any Profile settings.
    func forgetDevice(id: UUID) {
        guard let index = configuration.devices.firstIndex(where: { $0.id == id }) else {
            return
        }

        let device = configuration.devices[index]
        connectedIdentities.remove(device.hardwareIdentity)
        configuration.devices.remove(at: index)
        persist()

        NSLog(
            "Config: forgot hardware '%@' (%@); Profile remains untouched",
            device.name,
            device.hardwareIdentity.identifier
        )
    }

    // MARK: - Profiles

    @discardableResult
    func createProfile(name: String = "New Profile") -> PowerMateProfile {
        let profile = Self.makeEmptyProfile(name: normalizedProfileName(name))
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
        copy.name = uniqueProfileName(source.name + " Copy")

        // Mapping IDs are local to a Profile. Give the duplicated mapping tree
        // new IDs so future edits/selections are fully independent.
        copy.appProfiles = copy.appProfiles.map { mapping in
            var newMapping = mapping
            newMapping.id = UUID()
            return newMapping
        }

        configuration.profiles.append(copy)
        persist()
        return copy
    }

    func renameProfile(
        id: UUID,
        name: String
    ) {
        guard let index = configuration.profiles.firstIndex(where: { $0.id == id }) else {
            return
        }

        let trimmed = normalizedProfileName(name)
        guard !trimmed.isEmpty else { return }

        configuration.profiles[index].name = trimmed
        persist()
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

        guard configuration.profiles.contains(where: { $0.id == id }) else {
            return
        }

        configuration.profiles.removeAll { $0.id == id }

        // Do not silently switch a hardware device to another Profile.
        for index in configuration.devices.indices
            where configuration.devices[index].assignedProfileID == id {
            configuration.devices[index].assignedProfileID = nil
        }

        persist()
    }

    func profile(id: UUID?) -> PowerMateProfile? {
        guard let id else { return nil }
        return configuration.profiles.first { $0.id == id }
    }

    // MARK: - Application Mappings

    @discardableResult
    func addApplicationMapping(
        toProfileID profileID: UUID,
        name: String,
        bundleIdentifier: String
    ) -> UUID? {
        guard
            let index = configuration.profiles.firstIndex(where: { $0.id == profileID })
        else {
            return nil
        }

        guard !bundleIdentifier.isEmpty else {
            return nil
        }

        if configuration.profiles[index].appProfiles.contains(
            where: { $0.bundleIdentifier == bundleIdentifier }
        ) {
            return nil
        }

        let mapping = CodableAppProfile(
            name: name,
            isGlobal: false,
            bundleIdentifier: bundleIdentifier,
            iconName: "app"
        )
        configuration.profiles[index].appProfiles.append(mapping)
        persist()
        return mapping.id
    }

    func removeApplicationMapping(
        fromProfileID profileID: UUID,
        mappingID: UUID
    ) {
        guard let index = configuration.profiles.firstIndex(where: { $0.id == profileID }) else {
            return
        }

        configuration.profiles[index].appProfiles.removeAll {
            $0.id == mappingID && !$0.isGlobal
        }
        persist()
    }

    // MARK: - Runtime Lookup

    func profile(for identity: PowerMateHardwareIdentity) -> PowerMateProfile? {
        guard let device = device(for: identity) else {
            return nil
        }

        return profile(id: device.assignedProfileID)
    }

    // MARK: - Backward-Compatible Store API

    /// Compatibility helpers retained while older UI code is phased out.
    /// They now operate on the reusable Profile assigned to the Device rather
    /// than creating or owning a device-specific Profile.
    func deviceProfile(for deviceID: UUID) -> PowerMateProfile? {
        guard let device = device(id: deviceID) else {
            return nil
        }
        return profile(id: device.assignedProfileID)
    }

    func updateDeviceProfile(
        _ profile: PowerMateProfile,
        for deviceID: UUID
    ) {
        guard
            let device = device(id: deviceID),
            device.assignedProfileID == profile.id
        else {
            return
        }
        updateProfile(profile)
    }

    @discardableResult
    func addApplicationMapping(
        toDeviceID deviceID: UUID,
        name: String,
        bundleIdentifier: String
    ) -> UUID? {
        guard let device = device(id: deviceID), let profileID = device.assignedProfileID else {
            return nil
        }
        return addApplicationMapping(
            toProfileID: profileID,
            name: name,
            bundleIdentifier: bundleIdentifier
        )
    }

    func removeApplicationMapping(
        fromDeviceID deviceID: UUID,
        mappingID: UUID
    ) {
        guard let device = device(id: deviceID), let profileID = device.assignedProfileID else {
            return
        }
        removeApplicationMapping(
            fromProfileID: profileID,
            mappingID: mappingID
        )
    }

    /// Retained only for compatibility with older callers. Hardware names are
    /// normally assigned automatically and are no longer edited in the new UI.
    func renameDevice(
        id: UUID,
        name: String
    ) {
        guard let index = configuration.devices.firstIndex(where: { $0.id == id }) else {
            return
        }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        configuration.devices[index].name = trimmed
        persist()
    }

    // MARK: - Migration / Normalization

    /// Normalizes configuration created by earlier builds.
    ///
    /// Earlier versions used "PowerMate A", "PowerMate B", ... as hardware
    /// names and sometimes treated each Device as the owner of a Profile.
    /// We keep every existing Profile and its ID, but normalize hardware names
    /// to persistent numeric device names. No Profile is removed here.
    private func normalizeConfiguration() {
        var changed = false

        if configuration.profiles.isEmpty {
            configuration.profiles = [Self.makeEmptyProfile(name: "Default Profile")]
            changed = true
        }

        // Drop invalid Profile references but never delete the Profile object.
        let profileIDs = Set(configuration.profiles.map(\.id))
        for index in configuration.devices.indices {
            if let assignedID = configuration.devices[index].assignedProfileID,
               !profileIDs.contains(assignedID) {
                configuration.devices[index].assignedProfileID = nil
                changed = true
            }
        }

        // Convert legacy letter names to numeric names and fill missing /
        // duplicate names with the next unused number. Once assigned, the
        // numeric name remains stable until the hardware record is forgotten.
        var usedNumbers = Set<Int>()

        for index in configuration.devices.indices {
            let oldName = configuration.devices[index].name
            let candidateNumber = Self.legacyOrNumericDeviceNumber(from: oldName)
            let number = candidateNumber.flatMap { usedNumbers.contains($0) ? nil : $0 }
                ?? nextAvailableNumber(usedNumbers)

            usedNumbers.insert(number)

            let normalizedName = "PowerMate \(number)"
            if oldName != normalizedName {
                configuration.devices[index].name = normalizedName
                changed = true
            }
        }

        if changed {
            persist()
            NSLog("Config: normalized reusable Profiles and hardware registry")
        }
    }

    private func nextAvailableNumber(_ usedNumbers: Set<Int>) -> Int {
        var number = 1
        while usedNumbers.contains(number) {
            number += 1
        }
        return number
    }

    private func nextDeviceName() -> String {
        let highest = configuration.devices.compactMap {
            Self.legacyOrNumericDeviceNumber(from: $0.name)
        }.max() ?? 0

        return "PowerMate \(highest + 1)"
    }

    private func normalizedProfileName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "New Profile" : trimmed
    }

    private func uniqueProfileName(_ requested: String) -> String {
        let base = normalizedProfileName(requested)
        let existing = Set(configuration.profiles.map { $0.name })

        if !existing.contains(base) {
            return base
        }

        var suffix = 2
        while existing.contains("\(base) \(suffix)") {
            suffix += 1
        }
        return "\(base) \(suffix)"
    }

    private static func legacyOrNumericDeviceNumber(from name: String) -> Int? {
        let prefix = "PowerMate "
        guard name.hasPrefix(prefix) else { return nil }

        let suffix = String(name.dropFirst(prefix.count))

        if let numeric = Int(suffix), numeric > 0 {
            return numeric
        }

        guard suffix.count == 1,
              let scalar = suffix.unicodeScalars.first,
              scalar.value >= Unicode.Scalar("A").value,
              scalar.value <= Unicode.Scalar("Z").value
        else {
            return nil
        }

        return Int(scalar.value - Unicode.Scalar("A").value) + 1
    }

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
