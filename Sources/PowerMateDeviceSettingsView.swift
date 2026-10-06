import SwiftUI
import AppKit

/// Main editor for reusable PowerMate Profiles and their hardware assignments.
///
/// The left column is the reusable Profile library:
///   PowerMate A
///     Default
///     CLIP STUDIO PAINT
///
/// Hardware is intentionally separate. Selecting a Profile shows its hardware
/// assignment in the detail column; selecting a mapping shows only its Actions.
struct PowerMateDeviceSettingsView: View {
    @ObservedObject private var store = PowerMateConfigurationStore.shared

    @State private var expandedProfileIDs: Set<UUID> = []
    @State private var selection: SettingsSelection?
    @State private var showingNewProfile = false
    @State private var renameRequest: RenameProfileRequest?
    @State private var pendingDeleteProfileID: UUID?
    @State private var pendingForgetDeviceID: UUID?
    @State private var showingForgetConfirmation = false

    var body: some View {
        NavigationSplitView {
            List {
                Section("Profiles") {
                    ForEach(store.configuration.profiles) { profile in
                        profileTree(profile)
                    }
                }

                Section("Hardware") {
                    if store.configuration.devices.isEmpty {
                        Text("No registered PowerMates")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.configuration.devices) { device in
                            Button {
                                selection = .device(device.id)
                            } label: {
                                hardwareRow(device)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Forget PowerMate", role: .destructive) {
                                    pendingForgetDeviceID = device.id
                                    showingForgetConfirmation = true
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("PowerMates")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingNewProfile = true
                    } label: {
                        Label("New Profile", systemImage: "plus")
                    }
                }
            }
        } detail: {
            detailView
        }
        .frame(width: 900, height: 620)
        .sheet(isPresented: $showingNewProfile) {
            ProfileNameSheet(
                title: "New Profile",
                initialName: "New Profile"
            ) { name in
                let profile = store.createProfile(name: name)
                expandedProfileIDs.insert(profile.id)
                selection = .profile(profile.id)
            }
        }
        .sheet(item: $renameRequest) { request in
            ProfileNameSheet(
                title: "Rename Profile",
                initialName: request.currentName
            ) { name in
                store.renameProfile(id: request.profileID, name: name)
                selection = .profile(request.profileID)
            }
        }
        .alert("Forget PowerMate?", isPresented: $showingForgetConfirmation) {
            Button("Cancel", role: .cancel) {
                pendingForgetDeviceID = nil
            }
            Button("Forget", role: .destructive) {
                guard let deviceID = pendingForgetDeviceID else { return }

                if selection == .device(deviceID) {
                    selection = nil
                }

                store.forgetDevice(id: deviceID)
                pendingForgetDeviceID = nil
            }
        } message: {
            Text("The hardware registration will be removed. Its assigned Profile and all Profile settings will remain.")
        }
        .onAppear {
            if selection == nil, let firstProfile = store.configuration.profiles.first {
                expandedProfileIDs.insert(firstProfile.id)
                selection = .profile(firstProfile.id)
            }
        }
    }

    // MARK: - Tree

    @ViewBuilder
    private func profileTree(_ profile: PowerMateProfile) -> some View {
        DisclosureGroup(
            isExpanded: expandedBinding(for: profile.id)
        ) {
            ForEach(profile.appProfiles) { mapping in
                Button {
                    selection = .mapping(
                        profileID: profile.id,
                        mappingID: mapping.id
                    )
                } label: {
                    mappingRow(
                        mapping,
                        selected: selection == .mapping(
                            profileID: profile.id,
                            mappingID: mapping.id
                        )
                    )
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if !mapping.isGlobal {
                        Button("Remove Mapping", role: .destructive) {
                            store.removeApplicationMapping(
                                fromProfileID: profile.id,
                                mappingID: mapping.id
                            )

                            if selection == .mapping(
                                profileID: profile.id,
                                mappingID: mapping.id
                            ) {
                                selection = .profile(profile.id)
                            }
                        }
                    }
                }
            }
        } label: {
            Button {
                selection = .profile(profile.id)
            } label: {
                profileRow(profile)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Rename Profile") {
                    renameRequest = RenameProfileRequest(
                        profileID: profile.id,
                        currentName: profile.name
                    )
                }

                Button("Duplicate Profile") {
                    if let copy = store.duplicateProfile(id: profile.id) {
                        expandedProfileIDs.insert(copy.id)
                        selection = .profile(copy.id)
                    }
                }

                if store.configuration.profiles.count > 1 {
                    Divider()

                    Button("Delete Profile", role: .destructive) {
                        pendingDeleteProfileID = profile.id
                        selection = nil
                        store.deleteProfile(id: profile.id)
                        pendingDeleteProfileID = nil
                    }
                }
            }
        }
    }

    private func expandedBinding(for profileID: UUID) -> Binding<Bool> {
        Binding(
            get: {
                expandedProfileIDs.contains(profileID)
            },
            set: { expanded in
                if expanded {
                    expandedProfileIDs.insert(profileID)
                } else {
                    expandedProfileIDs.remove(profileID)
                }
            }
        )
    }

    private func profileRow(_ profile: PowerMateProfile) -> some View {
        let assignedDevice = store.assignedDevice(for: profile.id)

        return HStack(spacing: 8) {
            Image(systemName: "dial.medium")
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.headline)

                if let assignedDevice {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(
                                store.connectedIdentities.contains(assignedDevice.hardwareIdentity)
                                    ? Color.green
                                    : Color.secondary
                            )
                            .frame(width: 6, height: 6)

                        Text(assignedDevice.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Not assigned")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if selection == .profile(profile.id) {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func mappingRow(
        _ mapping: CodableAppProfile,
        selected: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: mapping.isGlobal ? "globe" : "app")
                .frame(width: 18)

            Text(mapping.isGlobal ? "Default" : mapping.name)

            Spacer()

            if selected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
        }
        .padding(.leading, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(selected ? Color.accentColor.opacity(0.12) : .clear)
        )
        .contentShape(Rectangle())
    }

    private func hardwareRow(_ device: PowerMateDevice) -> some View {
        let connected = store.connectedIdentities.contains(device.hardwareIdentity)
        let assignedProfile = store.profile(id: device.assignedProfileID)

        return HStack(spacing: 8) {
            Circle()
                .fill(connected ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.headline)

                Text(
                    assignedProfile?.name ?? "Unassigned"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if selection == .device(device.id) {
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .profile(let profileID):
            if let profile = store.profile(id: profileID) {
                ReusableProfileDetailView(
                    store: store,
                    profile: profile,
                    onAddApplication: { mappingID in
                        selection = .mapping(
                            profileID: profile.id,
                            mappingID: mappingID
                        )
                    }
                )
            } else {
                emptyDetail
            }

        case .mapping(let profileID, let mappingID):
            if
                let profile = store.profile(id: profileID),
                let mapping = profile.appProfiles.first(where: { $0.id == mappingID })
            {
                ProfileMappingEditorView(
                    store: store,
                    profileID: profile.id,
                    mappingID: mapping.id,
                    onSelectProfile: {
                        selection = .profile(profile.id)
                    }
                )
            } else {
                emptyDetail
            }

        case .device(let deviceID):
            if let device = store.device(id: deviceID) {
                HardwareDetailView(
                    store: store,
                    device: device
                )
            } else {
                emptyDetail
            }

        case nil:
            emptyDetail
        }
    }

    private var emptyDetail: some View {
        VStack(spacing: 10) {
            Image(systemName: "dial.medium")
                .font(.system(size: 32))

            Text("Select a Profile or PowerMate")
                .font(.headline)

            Text("Profiles contain settings; hardware is assigned separately.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Selection

private enum SettingsSelection: Hashable {
    case profile(UUID)
    case mapping(profileID: UUID, mappingID: UUID)
    case device(UUID)
}

private struct RenameProfileRequest: Identifiable {
    let profileID: UUID
    let currentName: String

    var id: UUID {
        profileID
    }
}

// MARK: - Profile Detail

private struct ReusableProfileDetailView: View {
    @ObservedObject var store: PowerMateConfigurationStore
    let profile: PowerMateProfile
    let onAddApplication: (UUID) -> Void

    @State private var showingAddApplication = false

    private var assignedDevice: PowerMateDevice? {
        store.assignedDevice(for: profile.id)
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "dial.medium")
                        .font(.system(size: 36))
                        .foregroundStyle(.tint)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile.name)
                            .font(.title2)
                            .bold()

                        Text("Reusable PowerMate Profile")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 6)
            }

            Section("Hardware Assignment") {
                Picker(
                    "Select PowerMate",
                    selection: Binding<UUID?>(
                        get: {
                            assignedDevice?.id
                        },
                        set: { deviceID in
                            store.assignDevice(
                                deviceID,
                                toProfileID: profile.id
                            )
                        }
                    )
                ) {
                    Text("Not Assigned")
                        .tag(nil as UUID?)

                    ForEach(store.configuration.devices) { device in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(
                                    store.connectedIdentities.contains(device.hardwareIdentity)
                                        ? Color.green
                                        : Color.secondary
                                )
                                .frame(width: 7, height: 7)

                            Text(device.name)
                        }
                        .tag(device.id as UUID?)
                    }
                }

                if let assignedDevice {
                    LabeledContent(
                        "Status",
                        value: store.connectedIdentities.contains(assignedDevice.hardwareIdentity)
                            ? "Connected"
                            : "Disconnected"
                    )

                    LabeledContent(
                        "Transport",
                        value: assignedDevice.transportType.displayName
                    )

                    LabeledContent(
                        "Hardware ID",
                        value: assignedDevice.hardwareIdentity.identifier
                    )
                } else {
                    LabeledContent("Status", value: "Not Assigned")
                }
            }

            Section {
                HStack {
                    Text("Applications")
                        .font(.headline)

                    Spacer()

                    Button {
                        showingAddApplication = true
                    } label: {
                        Label("Add Application", systemImage: "plus")
                    }
                }

                Text("Choose an application below to edit its Actions. Unmapped applications use Default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingAddApplication) {
            AddApplicationToProfileSheet(
                store: store,
                profileID: profile.id,
                onAdded: { mappingID in
                    showingAddApplication = false
                    onAddApplication(mappingID)
                }
            )
        }
        .padding()
        .navigationTitle(profile.name)
    }
}

// MARK: - Application Mapping Detail

private struct ProfileMappingEditorView: View {
    @ObservedObject var store: PowerMateConfigurationStore
    let profileID: UUID
    let mappingID: UUID
    let onSelectProfile: () -> Void

    private var profile: PowerMateProfile? {
        store.profile(id: profileID)
    }

    private var mapping: CodableAppProfile? {
        profile?.appProfiles.first(where: { $0.id == mappingID })
    }

    var body: some View {
        Group {
            if let profile, let mapping {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 12) {
                            mappingIcon(mapping)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(mapping.isGlobal ? "Default" : mapping.name)
                                    .font(.title2)
                                    .bold()

                                if !mapping.isGlobal,
                                   let bundleID = mapping.bundleIdentifier {
                                    Text(bundleID)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()

                            Button("Profile: \(profile.name)") {
                                onSelectProfile()
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.bottom, 20)

                        Text("Actions")
                            .font(.headline)
                            .padding(.bottom, 8)

                        ActionConfigRow(
                            title: "Rotate Left",
                            icon: "arrow.counterclockwise",
                            config: actionBinding(
                                keyPath: \.rotateLeft
                            )
                        )

                        ActionConfigRow(
                            title: "Rotate Right",
                            icon: "arrow.clockwise",
                            config: actionBinding(
                                keyPath: \.rotateRight
                            )
                        )

                        Divider().padding(.vertical, 12)

                        ActionConfigRow(
                            title: "Single Tap",
                            icon: "hand.tap",
                            config: actionBinding(
                                keyPath: \.singleClick
                            )
                        )

                        ActionConfigRow(
                            title: "Double Tap",
                            icon: "hand.tap.fill",
                            config: actionBinding(
                                keyPath: \.doubleClick
                            )
                        )

                        Divider().padding(.vertical, 12)

                        Toggle(
                            "Override Global Mode Cycling",
                            isOn: actionBinding(
                                keyPath: \.overrideLongPress
                            )
                        )

                        if mapping.overrideLongPress {
                            Picker(
                                "Hold Behavior",
                                selection: actionBinding(
                                    keyPath: \.holdBehavior
                                )
                            ) {
                                ForEach(CodableHoldBehavior.allCases) { behavior in
                                    Text(behavior.displayName).tag(behavior)
                                }
                            }

                            ActionConfigRow(
                                title: mapping.holdBehavior == .longPress
                                    ? "Long Press"
                                    : "Extended Press",
                                icon: "hand.draw",
                                config: actionBinding(
                                    keyPath: \.longPressAction
                                )
                            )
                        }
                    }
                    .padding(24)
                }
            } else {
                Text("Mapping not found")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(mapping?.isGlobal == true ? "Default" : (mapping?.name ?? "Mapping"))
    }

    @ViewBuilder
    private func mappingIcon(_ mapping: CodableAppProfile) -> some View {
        if
            !mapping.isGlobal,
            let bundleID = mapping.bundleIdentifier,
            let app = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == bundleID
            }),
            let icon = app.icon
        {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 40, height: 40)
        } else {
            Image(systemName: mapping.isGlobal ? "globe" : "app")
                .font(.system(size: 34))
                .foregroundStyle(
                    mapping.isGlobal
                        ? Color.accentColor
                        : Color.primary
                )
                .frame(width: 40, height: 40)
        }
    }

    private func actionBinding<T>(
        keyPath: WritableKeyPath<CodableAppProfile, T>
    ) -> Binding<T> {
        Binding(
            get: {
                guard
                    let currentProfile = store.profile(id: profileID),
                    let currentMapping = currentProfile.appProfiles.first(where: {
                        $0.id == mappingID
                    })
                else {
                    return defaultValue(for: keyPath)
                }

                return currentMapping[keyPath: keyPath]
            },
            set: { value in
                guard
                    var currentProfile = store.profile(id: profileID),
                    let index = currentProfile.appProfiles.firstIndex(where: {
                        $0.id == mappingID
                    })
                else {
                    return
                }

                currentProfile.appProfiles[index][keyPath: keyPath] = value
                store.updateProfile(currentProfile)

                let liveMapping = currentProfile.appProfiles[index]
                NSLog(
                    "Config UI: profile=%@ mapping=%@ key updated",
                    currentProfile.name,
                    liveMapping.name
                )
            }
        )
    }

    private func defaultValue<T>(
        for keyPath: WritableKeyPath<CodableAppProfile, T>
    ) -> T {
        if T.self == Bool.self {
            return false as! T
        }

        if T.self == CodableHoldBehavior.self {
            return CodableHoldBehavior.longPress as! T
        }

        if T.self == CodableActionConfig.self {
            return CodableActionConfig() as! T
        }

        fatalError("No default value for requested Profile mapping binding type")
    }
}

// MARK: - Hardware Detail

private struct HardwareDetailView: View {
    @ObservedObject var store: PowerMateConfigurationStore
    let device: PowerMateDevice

    @State private var showingForgetConfirmation = false

    private var connected: Bool {
        store.connectedIdentities.contains(device.hardwareIdentity)
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Circle()
                        .fill(connected ? Color.green : Color.secondary)
                        .frame(width: 10, height: 10)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.name)
                            .font(.title2)
                            .bold()

                        Text(connected ? "Connected" : "Disconnected")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Hardware") {
                LabeledContent(
                    "Status",
                    value: connected ? "Connected" : "Disconnected"
                )

                LabeledContent(
                    "Transport",
                    value: device.transportType.displayName
                )

                LabeledContent(
                    "Hardware ID",
                    value: device.hardwareIdentity.identifier
                )
            }

            Section("Profile Assignment") {
                Picker(
                    "Profile",
                    selection: Binding<UUID?>(
                        get: {
                            device.assignedProfileID
                        },
                        set: { profileID in
                            store.assignProfile(
                                profileID,
                                toDeviceID: device.id
                            )
                        }
                    )
                ) {
                    Text("Unassigned")
                        .tag(nil as UUID?)

                    ForEach(store.configuration.profiles) { profile in
                        Text(profile.name)
                            .tag(profile.id as UUID?)
                    }
                }
            }

            Section {
                Button("Forget PowerMate", role: .destructive) {
                    showingForgetConfirmation = true
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle(device.name)
        .alert("Forget PowerMate?", isPresented: $showingForgetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Forget", role: .destructive) {
                store.forgetDevice(id: device.id)
            }
        } message: {
            Text("The hardware registration will be removed. Its assigned Profile will remain.")
        }
    }
}

// MARK: - Add Application

private struct AddApplicationToProfileSheet: View {
    @ObservedObject var store: PowerMateConfigurationStore
    let profileID: UUID
    let onAdded: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var apps: [(name: String, bundleID: String, icon: NSImage?)] = []
    @State private var selectedBundleID = ""

    var body: some View {
        VStack(spacing: 14) {
            Text("Add Application Mapping")
                .font(.headline)

            Text("Choose a running application to add to this Profile.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List(apps, id: \.bundleID) { app in
                HStack {
                    if let icon = app.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 24, height: 24)
                    }

                    Text(app.name)
                    Spacer()

                    if selectedBundleID == app.bundleID {
                        Image(systemName: "checkmark")
                            .foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedBundleID = app.bundleID
                }
            }
            .frame(height: 300)

            HStack {
                Button("Cancel") {
                    dismiss()
                }

                Spacer()

                Button("Add") {
                    guard
                        let app = apps.first(where: { $0.bundleID == selectedBundleID }),
                        let mappingID = store.addApplicationMapping(
                            toProfileID: profileID,
                            name: app.name,
                            bundleIdentifier: app.bundleID
                        )
                    else {
                        return
                    }

                    onAdded(mappingID)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedBundleID.isEmpty)
            }
        }
        .padding()
        .frame(width: 460)
        .onAppear {
            let existing = Set(
                (store.profile(id: profileID)?.appProfiles ?? [])
                    .compactMap { $0.bundleIdentifier }
            )

            apps = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { app in
                    guard
                        let bundleID = app.bundleIdentifier,
                        !existing.contains(bundleID)
                    else {
                        return nil
                    }

                    return (
                        app.localizedName ?? bundleID,
                        bundleID,
                        app.icon
                    )
                }
                .sorted {
                    $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending
                }
        }
    }
}

// MARK: - Profile Name Sheet

private struct ProfileNameSheet: View {
    let title: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(
        title: String,
        initialName: String,
        onSave: @escaping (String) -> Void
    ) {
        self.title = title
        self.onSave = onSave
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(title)
                .font(.headline)

            TextField("Profile name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
        dismiss()
    }
}
