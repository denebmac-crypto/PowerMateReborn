import SwiftUI
import AppKit

struct PowerMateDeviceSettingsView: View {
    @ObservedObject private var store = PowerMateConfigurationStore.shared

    @State private var selectedDeviceID: UUID?
    @State private var selectedProfileID: UUID?
    @State private var showingAddProfile = false

    var body: some View {
        TabView {
            devicesTab
                .tabItem {
                    Label("Devices", systemImage: "dial.medium")
                }

            profilesTab
                .tabItem {
                    Label("Profiles", systemImage: "square.stack.3d.up")
                }
        }
        .frame(width: 820, height: 600)
        .onAppear {
            if selectedDeviceID == nil {
                selectedDeviceID = store.configuration.devices.first?.id
            }
            if selectedProfileID == nil {
                selectedProfileID = store.configuration.profiles.first?.id
            }
        }
    }

    private var devicesTab: some View {
        NavigationSplitView {
            List(store.configuration.devices, selection: $selectedDeviceID) { device in
                HStack(spacing: 8) {
                    Circle()
                        .fill(
                            store.connectedIdentities.contains(device.hardwareIdentity)
                                ? Color.green
                                : Color.secondary
                        )
                        .frame(width: 8, height: 8)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                        Text(device.transportType.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(device.id)
            }
            .navigationTitle("PowerMates")
        } detail: {
            if let selectedDeviceID,
               let device = store.configuration.devices.first(where: { $0.id == selectedDeviceID }) {
                DeviceDetailView(
                    store: store,
                    device: device
                )
            } else {
                ContentUnavailableView(
                    "No PowerMate Selected",
                    systemImage: "dial.medium",
                    description: Text("Connect a PowerMate or select a device.")
                )
            }
        }
    }

    private var profilesTab: some View {
        NavigationSplitView {
            List(store.configuration.profiles, selection: $selectedProfileID) { profile in
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                    Text("(profile.appProfiles.count) application mapping(s)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(profile.id)
            }
            .navigationTitle("Profiles")
            .toolbar {
                ToolbarItem {
                    Button {
                        let profile = store.createProfile()
                        selectedProfileID = profile.id
                    } label: {
                        Label("New Profile", systemImage: "plus")
                    }
                }
            }
        } detail: {
            if let selectedProfileID,
               let profile = store.profile(id: selectedProfileID) {
                ReusableProfileEditorView(
                    store: store,
                    profile: profile
                )
            } else {
                ContentUnavailableView(
                    "No Profile Selected",
                    systemImage: "square.stack.3d.up",
                    description: Text("Create a reusable Profile.")
                )
            }
        }
    }
}

private struct DeviceDetailView: View {
    @ObservedObject var store: PowerMateConfigurationStore
    let device: PowerMateDevice

    @State private var name: String
    @State private var selectedProfileID: UUID?

    init(
        store: PowerMateConfigurationStore,
        device: PowerMateDevice
    ) {
        self.store = store
        self.device = device
        _name = State(initialValue: device.name)
        _selectedProfileID = State(initialValue: device.assignedProfileID)
    }

    var body: some View {
        Form {
            Section("Device") {
                TextField("Name", text: $name)
                    .onSubmit {
                        store.renameDevice(id: device.id, name: name)
                    }

                LabeledContent("Transport", value: device.transportType.displayName)
                LabeledContent("Hardware ID", value: device.hardwareIdentity.identifier)

                let connected = store.connectedIdentities.contains(device.hardwareIdentity)
                LabeledContent("Status", value: connected ? "Connected" : "Not Connected")
            }

            Section("Assigned Profile") {
                Picker("Profile", selection: $selectedProfileID) {
                    Text("None").tag(UUID?.none)
                    ForEach(store.configuration.profiles) { profile in
                        Text(profile.name).tag(Optional(profile.id))
                    }
                }
                .onChange(of: selectedProfileID) { newValue in
                    store.assignProfile(newValue, toDeviceID: device.id)
                }

                Text("The assigned Profile is used when this PowerMate is in Custom mode. Application-specific mappings inside the Profile are selected automatically from the frontmost app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Forget This Device", role: .destructive) {
                    store.forgetDevice(id: device.id)
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .navigationTitle(device.name)
        .onDisappear {
            store.renameDevice(id: device.id, name: name)
        }
        .onChange(of: device.name) { newValue in
            name = newValue
        }
        .onChange(of: device.assignedProfileID) { newValue in
            selectedProfileID = newValue
        }
    }
}

private struct ReusableProfileEditorView: View {
    @ObservedObject var store: PowerMateConfigurationStore
    let profile: PowerMateProfile

    @State private var name: String
    @State private var selectedAppProfileID: UUID?
    @State private var showingAddApplication = false

    init(
        store: PowerMateConfigurationStore,
        profile: PowerMateProfile
    ) {
        self.store = store
        self.profile = profile
        _name = State(initialValue: profile.name)
        _selectedAppProfileID = State(
            initialValue: profile.appProfiles.first?.id
        )
    }

    private var selectedAppProfile: CodableAppProfile? {
        guard let selectedAppProfileID else { return nil }
        return profile.appProfiles.first { $0.id == selectedAppProfileID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Profile Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        var updated = profile
                        updated.name = name
                        store.updateProfile(updated)
                    }

                Button {
                    showingAddApplication = true
                } label: {
                    Label("Add Application", systemImage: "plus")
                }
            }

            Divider()

            if profile.appProfiles.isEmpty {
                ContentUnavailableView(
                    "No Application Mappings",
                    systemImage: "rectangle.slash",
                    description: Text("Add a Global Default or an application-specific mapping.")
                )
            } else {
                Picker("Application Mapping", selection: $selectedAppProfileID) {
                    ForEach(profile.appProfiles) { appProfile in
                        Text(appProfile.isGlobal ? "Global Default" : appProfile.name)
                            .tag(Optional(appProfile.id))
                    }
                }
                .padding(.horizontal)

                if let selectedAppProfile,
                   let index = profile.appProfiles.firstIndex(
                    where: { $0.id == selectedAppProfile.id }
                   ) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(selectedAppProfile.name)
                                .font(.title3)
                                .bold()
                                .padding(.bottom, 12)

                            ActionConfigRow(
                                title: "Rotate Left",
                                icon: "arrow.counterclockwise",
                                config: actionBinding(
                                    profileIndex: index,
                                    keyPath: \.rotateLeft
                                )
                            )

                            ActionConfigRow(
                                title: "Rotate Right",
                                icon: "arrow.clockwise",
                                config: actionBinding(
                                    profileIndex: index,
                                    keyPath: \.rotateRight
                                )
                            )

                            Divider().padding(.vertical, 10)

                            ActionConfigRow(
                                title: "Single Tap",
                                icon: "hand.tap",
                                config: actionBinding(
                                    profileIndex: index,
                                    keyPath: \.singleClick
                                )
                            )

                            ActionConfigRow(
                                title: "Double Tap",
                                icon: "hand.tap.fill",
                                config: actionBinding(
                                    profileIndex: index,
                                    keyPath: \.doubleClick
                                )
                            )

                            Divider().padding(.vertical, 10)

                            Toggle(
                                "Override Global Mode Cycling",
                                isOn: appProfileBinding(
                                    profileIndex: index,
                                    keyPath: \.overrideLongPress
                                )
                            )

                            if selectedAppProfile.overrideLongPress {
                                Picker(
                                    "Hold Behavior",
                                    selection: appProfileBinding(
                                        profileIndex: index,
                                        keyPath: \.holdBehavior
                                    )
                                ) {
                                    ForEach(CodableHoldBehavior.allCases) { behavior in
                                        Text(behavior.displayName).tag(behavior)
                                    }
                                }

                                ActionConfigRow(
                                    title: selectedAppProfile.holdBehavior == .longPress
                                        ? "Long Press"
                                        : "Extended Press",
                                    icon: "hand.draw",
                                    config: actionBinding(
                                        profileIndex: index,
                                        keyPath: \.longPressAction
                                    )
                                )
                            }
                        }
                        .padding(20)
                    }
                }
            }

            Spacer()
        }
        .padding(.top, 12)
        .navigationTitle(profile.name)
        .sheet(isPresented: $showingAddApplication) {
            AddApplicationToProfileSheet(
                store: store,
                profile: profile,
                isPresented: $showingAddApplication
            ) { id in
                selectedAppProfileID = id
            }
        }
        .onChange(of: profile.name) { newValue in
            name = newValue
        }
    }

    private func appProfileBinding<T>(
        profileIndex: Int,
        keyPath: WritableKeyPath<CodableAppProfile, T>
    ) -> Binding<T> {
        Binding(
            get: {
                profile.appProfiles[profileIndex][keyPath: keyPath]
            },
            set: { value in
                var updated = profile
                updated.appProfiles[profileIndex][keyPath: keyPath] = value
                store.updateProfile(updated)
            }
        )
    }

    private func actionBinding(
        profileIndex: Int,
        keyPath: WritableKeyPath<CodableAppProfile, CodableActionConfig>
    ) -> Binding<CodableActionConfig> {
        appProfileBinding(
            profileIndex: profileIndex,
            keyPath: keyPath
        )
    }
}

private struct AddApplicationToProfileSheet: View {
    @ObservedObject var store: PowerMateConfigurationStore
    let profile: PowerMateProfile
    @Binding var isPresented: Bool
    let onAdd: (UUID) -> Void

    @State private var apps: [(name: String, bundleID: String, icon: NSImage?)] = []
    @State private var selectedBundleID = ""

    var body: some View {
        VStack(spacing: 14) {
            Text("Add Application Mapping")
                .font(.headline)

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
            .frame(height: 280)

            HStack {
                Button("Cancel") {
                    isPresented = false
                }

                Spacer()

                Button("Add") {
                    guard
                        let app = apps.first(where: { $0.bundleID == selectedBundleID })
                    else {
                        return
                    }

                    var updated = profile
                    updated.appProfiles.append(
                        CodableAppProfile(
                            name: app.name,
                            isGlobal: false,
                            bundleIdentifier: app.bundleID,
                            iconName: "app"
                        )
                    )
                    store.updateProfile(updated)

                    if let newID = updated.appProfiles.last?.id {
                        onAdd(newID)
                    }

                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedBundleID.isEmpty)
            }
        }
        .padding()
        .frame(width: 420)
        .onAppear {
            let existing = Set(
                profile.appProfiles.compactMap { $0.bundleIdentifier }
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
