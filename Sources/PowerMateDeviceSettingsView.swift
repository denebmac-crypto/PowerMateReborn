import SwiftUI
import AppKit

struct PowerMateDeviceSettingsView: View {
    @ObservedObject private var store = PowerMateConfigurationStore.shared

    @State private var expandedDeviceIDs: Set<UUID> = []
    @State private var selection: MappingSelection?

    var body: some View {
        NavigationSplitView {
            List {
                ForEach(store.configuration.devices) { device in
                    DisclosureGroup(
                        isExpanded: expandedBinding(for: device.id)
                    ) {
                        let mappings = store.deviceProfile(for: device.id)?.appProfiles ?? []

                        ForEach(mappings) { mapping in
                            Button {
                                selection = MappingSelection(
                                    deviceID: device.id,
                                    mappingID: mapping.id
                                )
                            } label: {
                                mappingRow(mapping, selected: selection == MappingSelection(
                                    deviceID: device.id,
                                    mappingID: mapping.id
                                ))
                            }
                            .buttonStyle(.plain)
                        }
                    } label: {
                        deviceRow(device)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("PowerMates")
        } detail: {
            if let selection,
               let device = store.configuration.devices.first(
                    where: { $0.id == selection.deviceID }
               ) {
                DeviceMappingEditorView(
                    store: store,
                    device: device,
                    mappingID: selection.mappingID,
                    onSelectMapping: { mappingID in
                        self.selection = MappingSelection(
                            deviceID: device.id,
                            mappingID: mappingID
                        )
                    }
                )
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "dial.medium")
                        .font(.system(size: 32))
                    Text("Select a PowerMate")
                        .font(.headline)
                    Text("Choose Default or an application mapping from the left.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 900, height: 620)
        .onAppear {
            if let firstDevice = store.configuration.devices.first {
                expandedDeviceIDs.insert(firstDevice.id)

                if let firstMapping = store.deviceProfile(for: firstDevice.id)?.appProfiles.first {
                    selection = MappingSelection(
                        deviceID: firstDevice.id,
                        mappingID: firstMapping.id
                    )
                }
            }
        }
    }

    private func expandedBinding(for deviceID: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedDeviceIDs.contains(deviceID) },
            set: { isExpanded in
                if isExpanded {
                    expandedDeviceIDs.insert(deviceID)
                } else {
                    expandedDeviceIDs.remove(deviceID)
                }
            }
        )
    }

    private func deviceRow(_ device: PowerMateDevice) -> some View {
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
                    .font(.headline)
                Text(device.transportType.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
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
}

private struct MappingSelection: Hashable {
    let deviceID: UUID
    let mappingID: UUID
}

private struct DeviceMappingEditorView: View {
    @ObservedObject var store: PowerMateConfigurationStore
    let device: PowerMateDevice
    let mappingID: UUID
    let onSelectMapping: (UUID) -> Void

    @State private var deviceName: String
    @State private var showingAddApplication = false

    init(
        store: PowerMateConfigurationStore,
        device: PowerMateDevice,
        mappingID: UUID,
        onSelectMapping: @escaping (UUID) -> Void
    ) {
        self.store = store
        self.device = device
        self.mappingID = mappingID
        self.onSelectMapping = onSelectMapping
        _deviceName = State(initialValue: device.name)
    }

    private var profile: PowerMateProfile? {
        store.deviceProfile(for: device.id)
    }

    private var mapping: CodableAppProfile? {
        profile?.appProfiles.first(where: { $0.id == mappingID })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let profile, let mapping,
               let index = profile.appProfiles.firstIndex(where: { $0.id == mapping.id }) {
                Form {
                    Section("PowerMate") {
                        TextField("Name", text: $deviceName)
                            .onSubmit {
                                store.renameDevice(id: device.id, name: deviceName)
                            }

                        LabeledContent("Transport", value: device.transportType.displayName)
                        LabeledContent("Hardware ID", value: device.hardwareIdentity.identifier)
                        LabeledContent(
                            "Status",
                            value: store.connectedIdentities.contains(device.hardwareIdentity)
                                ? "Connected"
                                : "Not Connected"
                        )
                    }

                    Section {
                        HStack {
                            Text(mapping.isGlobal ? "Default" : mapping.name)
                                .font(.title3)
                                .bold()

                            Spacer()

                            if !mapping.isGlobal {
                                Button("Remove Mapping", role: .destructive) {
                                    store.removeApplicationMapping(
                                        fromDeviceID: device.id,
                                        mappingID: mapping.id
                                    )
                                }
                            }
                        }

                        if !mapping.isGlobal, let bundleID = mapping.bundleIdentifier {
                            LabeledContent("Application", value: bundleID)
                        }

                        Text(
                            mapping.isGlobal
                                ? "Used whenever the frontmost application has no mapping on this PowerMate."
                                : "Used only when this application is frontmost. Other applications fall back to Default."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Section("Actions") {
                        ActionConfigRow(
                            title: "Rotate Left",
                            icon: "arrow.counterclockwise",
                            config: actionBinding(
                                profile: profile,
                                index: index,
                                keyPath: \.rotateLeft
                            )
                        )

                        ActionConfigRow(
                            title: "Rotate Right",
                            icon: "arrow.clockwise",
                            config: actionBinding(
                                profile: profile,
                                index: index,
                                keyPath: \.rotateRight
                            )
                        )

                        Divider().padding(.vertical, 4)

                        ActionConfigRow(
                            title: "Single Tap",
                            icon: "hand.tap",
                            config: actionBinding(
                                profile: profile,
                                index: index,
                                keyPath: \.singleClick
                            )
                        )

                        ActionConfigRow(
                            title: "Double Tap",
                            icon: "hand.tap.fill",
                            config: actionBinding(
                                profile: profile,
                                index: index,
                                keyPath: \.doubleClick
                            )
                        )

                        Divider().padding(.vertical, 4)

                        Toggle(
                            "Override Global Mode Cycling",
                            isOn: appProfileBinding(
                                profile: profile,
                                index: index,
                                keyPath: \.overrideLongPress
                            )
                        )

                        if mapping.overrideLongPress {
                            Picker(
                                "Hold Behavior",
                                selection: appProfileBinding(
                                    profile: profile,
                                    index: index,
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
                                    profile: profile,
                                    index: index,
                                    keyPath: \.longPressAction
                                )
                            )
                        }
                    }
                }
                .formStyle(.grouped)
            } else {
                Text("Mapping not found")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack {
                Spacer()

                Button {
                    showingAddApplication = true
                } label: {
                    Label("Add Application", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .navigationTitle(device.name)
        .sheet(isPresented: $showingAddApplication) {
            AddApplicationToDeviceSheet(
                store: store,
                deviceID: device.id,
                onAdded: { id in
                    onSelectMapping(id)
                }
            )
        }
        .onDisappear {
            store.renameDevice(id: device.id, name: deviceName)
        }
    }

    private func appProfileBinding<T>(
        profile: PowerMateProfile,
        index: Int,
        keyPath: WritableKeyPath<CodableAppProfile, T>
    ) -> Binding<T> {
        Binding(
            get: {
                profile.appProfiles[index][keyPath: keyPath]
            },
            set: { value in
                var updated = profile
                updated.appProfiles[index][keyPath: keyPath] = value
                store.updateDeviceProfile(updated, for: device.id)
            }
        )
    }

    private func actionBinding(
        profile: PowerMateProfile,
        index: Int,
        keyPath: WritableKeyPath<CodableAppProfile, CodableActionConfig>
    ) -> Binding<CodableActionConfig> {
        appProfileBinding(
            profile: profile,
            index: index,
            keyPath: keyPath
        )
    }
}

private struct AddApplicationToDeviceSheet: View {
    @ObservedObject var store: PowerMateConfigurationStore
    let deviceID: UUID
    let onAdded: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var apps: [(name: String, bundleID: String, icon: NSImage?)] = []
    @State private var selectedBundleID = ""

    var body: some View {
        VStack(spacing: 14) {
            Text("Add Application Mapping")
                .font(.headline)

            Text("Choose a running application to add to this PowerMate.")
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
                            toDeviceID: deviceID,
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
                (store.deviceProfile(for: deviceID)?.appProfiles ?? [])
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
