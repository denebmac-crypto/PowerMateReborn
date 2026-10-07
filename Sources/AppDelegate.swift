import AppKit
import CoreAudio
import Foundation
import ServiceManagement
import Sparkle
import SwiftUI

// MARK: - Knob Modes

enum KnobMode: String, CaseIterable {
    case volume = "Volume"
    case brightness = "Brightness"
    case midi = "MIDI"
    case custom = "Custom"

    var icon: String {
        switch self {
        case .volume:     return "speaker.wave.2.fill"
        case .brightness: return "sun.max.fill"
        case .midi:       return "pianokeys"
        case .custom:     return "slider.horizontal.3"
        }
    }

    var menuBarImage: NSImage {
        switch self {
        case .volume:     return MenuBarIcon.volume()
        case .brightness: return MenuBarIcon.brightness()
        case .midi:       return MenuBarIcon.custom()  // reuse for now
        case .custom:     return MenuBarIcon.custom()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, PowerMateDelegate, VolumeChangeDelegate, SPUUpdaterDelegate {
    static private(set) var shared: AppDelegate!

    private var statusItem: NSStatusItem!
    private var powerMate = PowerMateManager()
    private let deviceConfiguration = PowerMateConfigurationStore.shared
    private var volumeController = VolumeController()
    private(set) var brightnessController = BrightnessController()
    private var midiController = MIDIController()
    private let customEngine = CustomModeEngine.shared
    private var updaterController: SPUStandardUpdaterController!
    private let osd = OSDOverlay()

    // Multi-mode
    private var currentMode: KnobMode = .custom
    // Custom is the only selectable mode in the current UI. The other mode
    // implementations remain intact for now, but are intentionally unavailable.
    private var enabledModes: [KnobMode] = [.custom]

    // Settings
    private var stepSize: Float = 0.03  // 3% per rotation tick
    private var ledFollowsLevel: Bool = true

    // Launch at login
    private var launchAtLogin: Bool = false

    // Snap-to-value state (double-tap toggles)
    private var volumeBeforeSnap: Float?
    private var brightnessBeforeSnap: Float?
    private var volumeSnapValue: Float = 0.20      // 20%
    private var brightnessSnapValue: Float = 0.67  // 67%

    // UI Window Controllers
    private var customSettingsWindowController: NSWindowController?
    private var deviceSettingsWindowController: NSWindowController?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only initialize Sparkle when a valid appcast feed is configured.
        // The distributable .app currently has no SUFeedURL, so keep updater disabled
        // rather than starting Sparkle in an incomplete configuration.
        if Bundle.main.bundleURL.pathExtension == "app",
           let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
           !feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: self,
                userDriverDelegate: nil
            )
        }
        
        requestPostEventAccessIfNeeded()
        loadSettings()
        deviceConfiguration.seedDefaultProfileIfNeeded(from: customEngine.profiles)
        setupMenuBar()
        volumeController.delegate = self
        let usbTransport = PowerMateUSBTransport()
        let bleTransport = PowerMateBLETransport()
        powerMate.addTransport(usbTransport)
        powerMate.addTransport(bleTransport)
        powerMate.delegate = self
        powerMate.start()
        updateStatusDisplay()
    }

    func applicationWillTerminate(_ notification: Notification) {
        brightnessController.restoreGamma()
        customEngine.shutdown()
        powerMate.setLEDBrightness(0)
        powerMate.stop()
        saveSettings()
    }

    private func requestPostEventAccessIfNeeded() {
        guard !CGPreflightPostEventAccess() else { return }
        NSLog("Accessibility: requesting post-event access")
        _ = CGRequestPostEventAccess()
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.title = "PM"
            button.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
            NSLog("Menu: statusItem created, button frame=%@", NSStringFromRect(button.frame))
        } else {
            NSLog("Menu: ERROR - statusItem.button is nil!")
        }

        updateStatusDisplay()
        buildMenu()
    }

    private func updateStatusDisplay() {
        guard let button = statusItem.button else { return }

        button.title = ""
        if !powerMate.isConnected {
            button.image = MenuBarIcon.disconnected()
            button.setAccessibilityLabel("PowerMate Disconnected")
        } else {
            button.image = currentMode.menuBarImage
            button.setAccessibilityLabel("PowerMate: \(currentMode.rawValue) Mode")
        }
        button.imagePosition = .imageOnly
        NSLog("Menu: title='%@' connected=%d", button.title, powerMate.isConnected)
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // --- Connection Status ---
        let statusTitle = powerMate.isConnected ? "PowerMate Connected" : "PowerMate Disconnected"
        let statusMenuItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        let dotColor: NSColor = powerMate.isConnected ? .systemGreen : .systemGray
        if let img = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: powerMate.isConnected ? "Connected" : "Disconnected") {
            let coloredImage = img.copy() as! NSImage
            coloredImage.isTemplate = false
            coloredImage.lockFocus()
            dotColor.set()
            let rect = NSRect(origin: .zero, size: img.size)
            rect.fill(using: .sourceAtop)
            coloredImage.unlockFocus()
            statusMenuItem.image = coloredImage
        }
        menu.addItem(statusMenuItem)
        
        menu.addItem(NSMenuItem.separator())

        // --- Active Mode Selection ---
        let modeMenu = NSMenu()
        modeMenu.autoenablesItems = false
        
        for mode in KnobMode.allCases {
            guard enabledModes.contains(mode) else { continue }
            let isCurrent = (mode == currentMode)
            let item = NSMenuItem(title: mode.rawValue, action: #selector(switchToMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            if let img = NSImage(systemSymbolName: mode.icon, accessibilityDescription: nil) {
                item.image = img
            }
            if isCurrent { item.state = .on }
            modeMenu.addItem(item)
        }
        
        let modeHeader = NSMenuItem(title: "Active Mode: \(currentMode.rawValue)", action: nil, keyEquivalent: "")
        modeHeader.submenu = modeMenu
        if let img = NSImage(systemSymbolName: currentMode.icon, accessibilityDescription: nil) {
            modeHeader.image = img
        }
        menu.addItem(modeHeader)

        menu.addItem(NSMenuItem.separator())

        // Enabled Modes Config
        let modesMenu = NSMenu()
        modesMenu.autoenablesItems = false
        // Only Custom is selectable. Other mode implementations remain in the
        // codebase, but are intentionally hidden from the current UI.
        let customModeItem = NSMenuItem(
            title: KnobMode.custom.rawValue,
            action: #selector(toggleMode(_:)),
            keyEquivalent: ""
        )
        customModeItem.target = self
        customModeItem.representedObject = KnobMode.custom.rawValue
        customModeItem.state = .on
        modesMenu.addItem(customModeItem)

        let modesItem = NSMenuItem(title: "Enabled Modes", action: nil, keyEquivalent: "")
        modesItem.submenu = modesMenu
        if let img = NSImage(systemSymbolName: "checklist", accessibilityDescription: nil) {
            modesItem.image = img
        }
        menu.addItem(modesItem)

        menu.addItem(NSMenuItem.separator())

        // PowerMate Device / Profile Settings
        let deviceProfilesItem = NSMenuItem(title: "PowerMate Devices & Profiles...", action: #selector(showDeviceProfiles), keyEquivalent: "")
        deviceProfilesItem.target = self
        if let img = NSImage(systemSymbolName: "dial.medium", accessibilityDescription: nil) {
            deviceProfilesItem.image = img
        }
        menu.addItem(deviceProfilesItem)

        // Launch at Login toggle
        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = launchAtLogin ? .on : .off
        if let img = NSImage(systemSymbolName: "power", accessibilityDescription: nil) {
            loginItem.image = img
        }
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem.separator())

        // About
        let aboutItem = NSMenuItem(title: "About PowerMate...", action: #selector(showAboutWindow), keyEquivalent: "")
        aboutItem.target = self
        // Use an empty image to perfectly align the text with other menu items
        if let templateImg = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil) {
            aboutItem.image = NSImage(size: templateImg.size)
        }
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "Quit PowerMate", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        // Use an empty image to perfectly align the text with other menu items
        if let templateImg = NSImage(systemSymbolName: "power.circle", accessibilityDescription: nil) {
            quitItem.image = NSImage(size: templateImg.size)
        }
        menu.addItem(quitItem)

        statusItem.menu = menu
        updateMenuLevels()
    }

    private func refreshMenu() {
        buildMenu()
    }

    // MARK: - Mode Switching

    private func cycleMode() {
        guard enabledModes.count > 1 else { return }
        if let idx = enabledModes.firstIndex(of: currentMode) {
            let nextIdx = (idx + 1) % enabledModes.count
            currentMode = enabledModes[nextIdx]
        } else {
            currentMode = enabledModes[0]
        }
        NSLog("Mode switched to: \(currentMode.rawValue)")
        updateStatusDisplay()
        updateLEDForLevel()
        refreshMenu()

        // Flash LED briefly to indicate mode switch
        flashLEDForModeSwitch()
    }

    private func flashLEDForModeSwitch() {
        let savedBrightness = powerMate.ledBrightness
        powerMate.setLEDBrightness(255)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.powerMate.setLEDBrightness(0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.powerMate.setLEDBrightness(255)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    guard let self = self else { return }
                    if self.ledFollowsLevel {
                        self.updateLEDForLevel()
                    } else {
                        self.powerMate.setLEDBrightness(savedBrightness)
                    }
                }
            }
        }
    }

    // MARK: - Menu Actions

    @objc private func switchToMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = KnobMode(rawValue: rawValue) else { return }
        currentMode = mode
        NSLog("Mode switched to: %@", mode.rawValue)
        updateStatusDisplay()
        updateLEDForLevel()
        refreshMenu()
    }

    @objc private func switchAudioDevice(_ sender: NSMenuItem) {
        let deviceID = AudioDeviceID(sender.tag)
        volumeController.setActiveDevice(deviceID)
        // Remember this preference: "when current default is X, use device Y"
        let defaultID = volumeController.allOutputDevices.first(where: {
            // Find the actual system default (before our redirect)
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var sysDefault = AudioDeviceID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &sysDefault)
            return $0.deviceID == sysDefault
        })?.uid ?? ""
        if !defaultID.isEmpty {
            var prefs = UserDefaults.standard.dictionary(forKey: "powermate.deviceRouting") as? [String: String] ?? [:]
            let targetUID = volumeController.allOutputDevices.first(where: { $0.deviceID == deviceID })?.uid ?? ""
            if !targetUID.isEmpty {
                prefs[defaultID] = targetUID
                UserDefaults.standard.set(prefs, forKey: "powermate.deviceRouting")
                NSLog("Audio: remembered routing %@ -> %@", defaultID, targetUID)
            }
        }
        NSLog("Audio device switched to ID %d", deviceID)
        updateLEDForLevel()
        refreshMenu()
    }

    @objc private func toggleMuteClicked() {
        volumeController.toggleMute()
        updateLEDForLevel()
        refreshMenu()
    }

    @objc private func toggleMode(_ sender: NSMenuItem) {
        // Custom is intentionally the only selectable mode.
        // Keep the action harmless so it can never be disabled.
        guard let rawValue = sender.representedObject as? String,
              rawValue == KnobMode.custom.rawValue else { return }

        currentMode = .custom
        enabledModes = [.custom]
        refreshMenu()
    }

    @objc private func sensitivityChanged(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? Float {
            stepSize = value
        }
        refreshMenu()
    }

    @objc private func volumeSnapChanged(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? Float {
            volumeSnapValue = value
        }
        refreshMenu()
    }

    @objc private func brightnessSnapChanged(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? Float {
            brightnessSnapValue = value
        }
        refreshMenu()
    }

    @objc private func midiCCChanged(_ sender: NSMenuItem) {
        midiController.ccNumber = UInt8(sender.tag)
        NSLog("MIDI: CC number changed to %d", sender.tag)
        refreshMenu()
    }

    @objc private func midiChannelChanged(_ sender: NSMenuItem) {
        midiController.channel = UInt8(sender.tag - 1)  // menu shows 1-based, MIDI is 0-based
        NSLog("MIDI: channel changed to %d", sender.tag)
        refreshMenu()
    }

    @objc private func toggleDDC(_ sender: NSMenuItem) {
        brightnessController.ddcController.isEnabled.toggle()
        let enabled = brightnessController.ddcController.isEnabled
        NSLog("DDC/CI: %@", enabled ? "enabled" : "disabled")
        if enabled {
            brightnessController.reprobeDisplays()
        }
        UserDefaults.standard.set(enabled, forKey: "powermate.ddc.enabled")
        refreshMenu()
    }

    @objc private func toggleBrightnessSync(_ sender: NSMenuItem) {
        brightnessController.syncDisplays.toggle()
        NSLog("Brightness: Sync %@", brightnessController.syncDisplays ? "ON" : "OFF")
        refreshMenu()
    }

    @objc private func ledFollowLevel(_ sender: NSMenuItem) {
        ledFollowsLevel.toggle()
        if ledFollowsLevel { updateLEDForLevel() }
        refreshMenu()
    }

    @objc private func ledOff() {
        ledFollowsLevel = false
        powerMate.setLEDBrightness(0)
        refreshMenu()
    }

    @objc private func ledDim() {
        ledFollowsLevel = false
        powerMate.setLEDBrightness(64)
        refreshMenu()
    }

    @objc private func ledBright() {
        ledFollowsLevel = false
        powerMate.setLEDBrightness(255)
        refreshMenu()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        launchAtLogin.toggle()
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
                NSLog("Launch at login: enabled")
            } else {
                try SMAppService.mainApp.unregister()
                NSLog("Launch at login: disabled")
            }
        } catch {
            NSLog("Launch at login failed: %@", error.localizedDescription)
            launchAtLogin.toggle() // revert on failure
        }
        refreshMenu()
    }

    @objc private func showAboutWindow() {
        let alert = NSAlert()
        alert.messageText = "PowerMateReborn"
        alert.alertStyle = .informational
        
        // Set custom icon (logo) at the top
        if let logoPath = Bundle.module.path(forResource: "logo", ofType: "svg") ?? Bundle.main.path(forResource: "logo", ofType: "svg"),
           let logoImg = NSImage(contentsOfFile: logoPath) {
            alert.icon = logoImg
        }

        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .centerX
        container.spacing = 8
        
        // Version info
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        let versionLabel = NSTextField(labelWithString: "Version \(version) (\(build))")
        versionLabel.font = NSFont.systemFont(ofSize: 13)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.alignment = .center
        versionLabel.isEditable = false
        versionLabel.isSelectable = false
        versionLabel.drawsBackground = false
        versionLabel.isBordered = false
        container.addArrangedSubview(versionLabel)
        
        // Device status
        let connected = powerMate.isConnected
        let deviceStatus = connected ? "🟢 PowerMate Connected" : "⚪️ PowerMate Disconnected"
        let statusLabel = NSTextField(labelWithString: deviceStatus)
        statusLabel.font = NSFont.boldSystemFont(ofSize: 13)
        statusLabel.textColor = .labelColor
        statusLabel.alignment = .center
        statusLabel.isEditable = false
        statusLabel.isSelectable = false
        statusLabel.drawsBackground = false
        statusLabel.isBordered = false
        container.addArrangedSubview(statusLabel)
        
        // Audio info
        let audioInfo = "Audio: \(volumeController.activeDeviceName) (\(volumeController.volumeMethod.rawValue))"
        let audioLabel = NSTextField(labelWithString: audioInfo)
        audioLabel.font = NSFont.systemFont(ofSize: 12)
        audioLabel.textColor = .secondaryLabelColor
        audioLabel.alignment = .center
        audioLabel.isEditable = false
        audioLabel.isSelectable = false
        audioLabel.drawsBackground = false
        audioLabel.isBordered = false
        container.addArrangedSubview(audioLabel)
        
        // Brightness info
        let brightnessInfo = "Brightness: \(brightnessController.method.rawValue)"
        let brightnessLabel = NSTextField(labelWithString: brightnessInfo)
        brightnessLabel.font = NSFont.systemFont(ofSize: 12)
        brightnessLabel.textColor = .secondaryLabelColor
        brightnessLabel.alignment = .center
        brightnessLabel.isEditable = false
        brightnessLabel.isSelectable = false
        brightnessLabel.drawsBackground = false
        brightnessLabel.isBordered = false
        container.addArrangedSubview(brightnessLabel)
        
        // Tip about multi-display
        let tipLabel = NSTextField(wrappingLabelWithString: "Tip: By default, the knob dims all displays together. You can uncheck 'Sync All Displays' in the menu to control each monitor individually based on mouse location.")
        tipLabel.font = NSFont.systemFont(ofSize: 11)
        tipLabel.textColor = .secondaryLabelColor
        tipLabel.alignment = .center
        tipLabel.isEditable = false
        tipLabel.isSelectable = false
        tipLabel.drawsBackground = false
        tipLabel.isBordered = false
        tipLabel.maximumNumberOfLines = 0
        tipLabel.lineBreakMode = .byWordWrapping
        tipLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addArrangedSubview(tipLabel)
        NSLayoutConstraint.activate([
            tipLabel.widthAnchor.constraint(equalToConstant: 300)
        ])
        
        // Spacer
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        container.addArrangedSubview(spacer)
        NSLayoutConstraint.activate([
            spacer.heightAnchor.constraint(equalToConstant: 4)
        ])
        
        // Report Issue button
        let issueButton = NSButton(title: "Report Issue on GitHub", target: self, action: #selector(openGitHubIssues))
        issueButton.bezelStyle = .rounded
        container.addArrangedSubview(issueButton)
        
        // Add padding
        container.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 10, right: 10)
        container.layoutSubtreeIfNeeded()
        
        let requiredSize = container.fittingSize
        
        // Wrap the container in an explicit fixed-size NSView. 
        // NSAlert requires the accessoryView to have a fully specified frame.
        let wrapper = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: requiredSize.height))
        container.frame = wrapper.bounds
        container.autoresizingMask = [.width, .height]
        wrapper.addSubview(container)
        
        alert.accessoryView = wrapper
        alert.addButton(withTitle: "OK")

        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func openGitHubIssues() {
        if let url = URL(string: "https://github.com/EricBintner/PowerMateReborn/issues/new") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showDeviceProfiles() {
        if deviceSettingsWindowController == nil {
            let settingsView = PowerMateDeviceSettingsView()
            let hostingController = NSHostingController(rootView: settingsView)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "PowerMate Devices & Profiles"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 900, height: 620))

            deviceSettingsWindowController = NSWindowController(window: window)
        }

        deviceSettingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showCustomSettings() {
        // The reusable Profile/Device editor is the single source of truth
        // for Custom Mode. Keep the legacy menu entry as an alias so action
        // edits such as Scroll Amount always affect the live runtime store.
        if deviceSettingsWindowController == nil {
            let settingsView = PowerMateDeviceSettingsView()
            let hostingController = NSHostingController(rootView: settingsView)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "PowerMate Devices & Profiles"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 900, height: 620))

            deviceSettingsWindowController = NSWindowController(
                window: window
            )
        }

        deviceSettingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showQuickStart() {
        let alert = NSAlert()
        alert.messageText = "Quick Start"
        alert.alertStyle = .informational
        
        // Set custom icon (logo) at the top
        if let logoPath = Bundle.module.path(forResource: "logo", ofType: "svg") ?? Bundle.main.path(forResource: "logo", ofType: "svg"),
           let logoImg = NSImage(contentsOfFile: logoPath) {
            alert.icon = logoImg
        }
        
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .centerX
        container.spacing = 8
        
        // 1. PowerMate device image
        if let iconPath = Bundle.module.path(forResource: "griffin-technology-powermate-mac-os9", ofType: "png") ?? Bundle.main.path(forResource: "griffin-technology-powermate-mac-os9", ofType: "png"),
           let img = NSImage(contentsOfFile: iconPath) {
            let imageView = NSImageView(image: img)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                imageView.widthAnchor.constraint(equalToConstant: 300),
                imageView.heightAnchor.constraint(equalToConstant: 80)
            ])
            container.addArrangedSubview(imageView)
        }
        
        // 2. Grid Table for Controls
        let grid = NSGridView()
        grid.rowSpacing = 8
        grid.columnSpacing = 16
        
        let actions = [
            ("Turn knob", "Adjust volume or brightness"),
            ("Press down", "Snap to preset level (toggle)"),
            ("Double-tap", "Mute audio or sleep display"),
            ("Press & hold", "Cycle modes (Vol / Bright / MIDI)")
        ]
        
        for (action, desc) in actions {
            let actionLabel = NSTextField(labelWithString: action)
            actionLabel.font = NSFont.boldSystemFont(ofSize: 13)
            actionLabel.alignment = .right
            actionLabel.isEditable = false
            actionLabel.isSelectable = false
            actionLabel.drawsBackground = false
            actionLabel.isBordered = false
            
            let descLabel = NSTextField(labelWithString: desc)
            descLabel.font = NSFont.systemFont(ofSize: 13)
            descLabel.alignment = .left
            descLabel.isEditable = false
            descLabel.isSelectable = false
            descLabel.drawsBackground = false
            descLabel.isBordered = false
            
            grid.addRow(with: [actionLabel, descLabel])
        }
        
        container.addArrangedSubview(grid)
        
        // 3. Footer Text
        let footer = NSTextField(wrappingLabelWithString: "You can configure the active mode, output device, and rotation sensitivity using this menu.")
        footer.font = NSFont.systemFont(ofSize: 12)
        footer.textColor = .secondaryLabelColor
        footer.alignment = .center
        footer.isEditable = false
        footer.isSelectable = false
        footer.drawsBackground = false
        footer.isBordered = false
        footer.maximumNumberOfLines = 0
        footer.lineBreakMode = .byWordWrapping
        footer.translatesAutoresizingMaskIntoConstraints = false
        container.addArrangedSubview(footer)
        NSLayoutConstraint.activate([
            footer.widthAnchor.constraint(equalToConstant: 480)
        ])
        
        // Add padding
        container.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 10, right: 10)
        container.layoutSubtreeIfNeeded()
        
        let requiredSize = container.fittingSize
        
        // Wrap the container in an explicit fixed-size NSView. 
        // NSAlert requires the accessoryView to have a fully specified frame.
        let wrapper = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: requiredSize.height))
        container.frame = wrapper.bounds
        container.autoresizingMask = [.width, .height]
        wrapper.addSubview(container)
        
        alert.accessoryView = wrapper
        alert.addButton(withTitle: "Got it")
        
        // Ensure the alert appears in front of everything
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        NSLog("Sparkle: Appcast loaded successfully")
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        NSLog("Sparkle: Found valid update to version %@", item.versionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        NSLog("Sparkle: No updates available")
    }

    func updater(_ updater: SPUUpdater, failedToLoadAppcastWithError error: Error) {
        NSLog("Sparkle: Failed to load appcast: %@", error.localizedDescription)
    }

    // MARK: - Menu Helpers

    private func updateMenuLevels() {
        guard let menu = statusItem.menu else { return }
        
        if let volItem = menu.item(withTag: 100) {
            volItem.attributedTitle = attributedLevelTitle(
                "Volume",
                level: volumeController.getVolume(),
                isVirtual: volumeController.isSoftwareVolume,
                isAvailable: true
            )
        }
        
        if let brItem = menu.item(withTag: 101) {
            brItem.attributedTitle = attributedLevelTitle(
                "Brightness",
                level: brightnessController.getCurrentBrightness(),
                isVirtual: brightnessController.isVirtual,
                isAvailable: brightnessController.isAvailable
            )
        }
    }

    private func attributedLevelTitle(_ base: String, level: Float, isVirtual: Bool, isAvailable: Bool) -> NSAttributedString {
        let percentage = "\(Int(level * 100))%"
        let methodText = !isAvailable ? "Unavailable" : (isVirtual ? "Virtual" : "Hardware")
        
        let fullString = "\(base): \(percentage)   \(methodText)"
        
        let attrStr = NSMutableAttributedString(string: fullString)
        let fullRange = NSRange(location: 0, length: attrStr.length)
        
        attrStr.addAttribute(.font, value: NSFont.menuBarFont(ofSize: 0), range: fullRange)
        
        if let range = fullString.range(of: methodText) {
            let nsRange = NSRange(range, in: fullString)
            attrStr.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: nsRange)
            attrStr.addAttribute(.font, value: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), range: nsRange)
        }
        
        return attrStr
    }

    // MARK: - LED Helpers

    private func updateLEDForLevel(
        for identity: PowerMateHardwareIdentity? = nil
    ) {
        guard ledFollowsLevel else { return }

        var level: Float = 0
        switch currentMode {
        case .volume:
            level = volumeController.isMuted() ? 0 : volumeController.getVolume()
        case .brightness:
            level = brightnessController.getCurrentBrightness()
        case .midi:
            level = midiController.ccLevel
        case .custom:
            level = 0.5
        }

        let ledVal = UInt8(max(0, min(255, level * 255)))

        if let identity {
            powerMate.setLEDBrightness(ledVal, for: identity)
        } else {
            powerMate.setLEDBrightness(ledVal)
        }
    }

    // MARK: - PowerMateDelegate

    func powerMateDidConnect(identity: PowerMateHardwareIdentity) {
        deviceConfiguration.registerDevice(identity: identity)
        deviceConfiguration.markConnected(identity)

        NSLog(
            "PowerMate connected: %@ (%@)",
            identity.transportType.displayName,
            identity.identifier
        )

        updateStatusDisplay()
        refreshMenu()
        updateLEDForLevel(for: identity)
    }

    func powerMateDidDisconnect(identity: PowerMateHardwareIdentity) {
        if currentMode == .custom,
           let profile = deviceConfiguration.profile(for: identity) {
            customEngine.handleButtonReleased(
                profile: profile,
                identity: identity
            )
        }

        deviceConfiguration.markDisconnected(identity)

        NSLog(
            "PowerMate disconnected: %@ (%@)",
            identity.transportType.displayName,
            identity.identifier
        )

        updateStatusDisplay()
        refreshMenu()
    }

    func powerMateDidRotate(
        identity: PowerMateHardwareIdentity,
        delta: Int
    ) {
        let receiveTime = DispatchTime.now().uptimeNanoseconds
        NSLog(
            "BLE Timing: app delegate t=%.6f delta=%d",
            Double(receiveTime) / 1_000_000_000.0,
            delta
        )

        // BLE custom actions stay on the CoreBluetooth queue for minimum latency.
        // AppKit and the non-custom controller paths are always confined to main.
        if currentMode == .custom {
            guard let profile = deviceConfiguration.profile(for: identity) else {
                NSLog("Custom: no Profile assigned to %@", identity.identifier)
                return
            }

            NSLog(
                "Custom: rotate identity=%@ profile=%@ delta=%d",
                identity.identifier,
                profile.name,
                delta
            )

            customEngine.handleRotation(
                delta: delta,
                stepSize: stepSize,
                profile: profile
            )

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.updateLEDForLevel(for: identity)
                self.updateMenuLevels()
            }
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            switch self.currentMode {
            case .volume:
                let adjustment = Float(delta) * self.stepSize
                self.volumeController.adjustVolume(by: adjustment)
                self.osd.showVolume(
                    level: self.volumeController.getVolume(),
                    muted: self.volumeController.isMuted()
                )

            case .brightness:
                let adjustment = Float(delta) * self.stepSize
                self.brightnessController.updateTargetDisplay()
                self.brightnessController.adjustBrightness(by: adjustment)
                self.osd.showBrightness(
                    level: self.brightnessController.getCurrentBrightness()
                )

            case .midi:
                let adjustment = Float(delta) * self.stepSize
                self.midiController.adjustCC(by: adjustment)

            case .custom:
                self.powerMateDidRotate(identity: identity, delta: delta)
                return
            }

            self.updateLEDForLevel(for: identity)
            self.updateMenuLevels()
        }
    }

    func powerMateButtonPressed(
        identity: PowerMateHardwareIdentity
    ) {
        NSLog(
            "Button: single press [%@] (%@)",
            currentMode.rawValue,
            identity.identifier
        )

        switch currentMode {
        case .volume:
            if let saved = volumeBeforeSnap {
                volumeController.setVolume(saved)
                volumeBeforeSnap = nil
            } else {
                volumeBeforeSnap = volumeController.getVolume()
                volumeController.setVolume(volumeSnapValue)
            }

            osd.showVolume(
                level: volumeController.getVolume(),
                muted: volumeController.isMuted()
            )

        case .brightness:
            if let saved = brightnessBeforeSnap {
                brightnessController.setBrightness(saved)
                brightnessBeforeSnap = nil
            } else {
                brightnessBeforeSnap = brightnessController.getCurrentBrightness()
                brightnessController.setBrightness(brightnessSnapValue)
            }

            osd.showBrightness(
                level: brightnessController.getCurrentBrightness()
            )

        case .midi:
            midiController.toggleNote()

        case .custom:
            guard let profile = deviceConfiguration.profile(for: identity) else {
                NSLog("Custom: no Profile assigned to %@", identity.identifier)
                return
            }

            NSLog(
                "Custom: single tap identity=%@ profile=%@",
                identity.identifier,
                profile.name
            )
            customEngine.handleSingleTap(profile: profile)
        }

        updateLEDForLevel(for: identity)
        refreshMenu()
    }

    func powerMateButtonDoubleTapped(
        identity: PowerMateHardwareIdentity
    ) {
        NSLog(
            "Button: double tap [%@] (%@)",
            currentMode.rawValue,
            identity.identifier
        )

        switch currentMode {
        case .volume:
            volumeController.toggleMute()
            osd.showVolume(
                level: volumeController.getVolume(),
                muted: volumeController.isMuted()
            )

        case .brightness:
            brightnessController.sleepDisplay()

        case .midi:
            midiController.toggleNote()

        case .custom:
            guard let profile = deviceConfiguration.profile(for: identity) else {
                NSLog("Custom: no Profile assigned to %@", identity.identifier)
                return
            }

            NSLog(
                "Custom: double tap identity=%@ profile=%@",
                identity.identifier,
                profile.name
            )
            customEngine.handleDoubleTap(profile: profile)
        }

        updateLEDForLevel(for: identity)
        refreshMenu()
    }

    func powerMateButtonLongPressed(
        identity: PowerMateHardwareIdentity
    ) {
        if currentMode == .custom,
           let profile = deviceConfiguration.profile(for: identity),
           customEngine.handleLongPress(
               profile: profile,
               identity: identity
           ) {
            NSLog(
                "Button: long press consumed by device profile (%@)",
                identity.identifier
            )
            return
        }

        NSLog(
            "Button: long press -> cycle mode (%@)",
            identity.identifier
        )
        cycleMode()
    }

    func powerMateButtonReleased(
        identity: PowerMateHardwareIdentity
    ) {
        guard currentMode == .custom else { return }

        if let profile = deviceConfiguration.profile(for: identity) {
            customEngine.handleButtonReleased(
                profile: profile,
                identity: identity
            )
        }
    }

    // MARK: - VolumeChangeDelegate

    func volumeDidChange(volume: Float, muted: Bool) {
        // External volume change (keyboard, Control Center, another app)
        updateLEDForLevel()
        updateMenuLevels()
    }

    func audioDeviceDidChange(deviceName: String, method: VolumeControlMethod) {
        NSLog("Audio device changed to: \(deviceName) (\(method.rawValue))")

        // Apply saved per-device routing preference
        if let prefs = UserDefaults.standard.dictionary(forKey: "powermate.deviceRouting") as? [String: String],
           let currentUID = volumeController.activeDeviceInfo?.uid,
           let preferredUID = prefs[currentUID] {
            // Find device with that UID
            if let preferred = volumeController.allOutputDevices.first(where: { $0.uid == preferredUID }),
               preferred.deviceID != volumeController.activeDeviceID {
                NSLog("Audio: applying saved routing -> %@ (%@)", preferred.name, preferredUID)
                volumeController.setActiveDevice(preferred.deviceID)
            }
        }

        updateLEDForLevel()
        refreshMenu()
    }

    // MARK: - Settings Persistence

    private func loadSettings() {
        let d = UserDefaults.standard

        // The current UI exposes Custom only. Ignore legacy saved mode selections
        // so an older configuration can never restore Volume/Brightness/MIDI.
        currentMode = .custom
        enabledModes = [.custom]
        if d.object(forKey: "powermate.stepSize") != nil {
            stepSize = d.float(forKey: "powermate.stepSize")
        }
        if d.object(forKey: "powermate.ledFollowsLevel") != nil {
            ledFollowsLevel = d.bool(forKey: "powermate.ledFollowsLevel")
        }
        if d.object(forKey: "powermate.longPressThreshold") != nil {
            powerMate.longPressThreshold = d.double(forKey: "powermate.longPressThreshold")
        }
        if d.object(forKey: "powermate.doubleTapInterval") != nil {
            powerMate.doubleTapInterval = d.double(forKey: "powermate.doubleTapInterval")
        }
        if d.object(forKey: "powermate.volume.snapValue") != nil {
            volumeSnapValue = d.float(forKey: "powermate.volume.snapValue")
        }
        if d.object(forKey: "powermate.brightness.snapValue") != nil {
            brightnessSnapValue = d.float(forKey: "powermate.brightness.snapValue")
        }
        // MIDI settings
        if d.object(forKey: "powermate.midi.ccNumber") != nil {
            midiController.ccNumber = UInt8(d.integer(forKey: "powermate.midi.ccNumber"))
        }
        if d.object(forKey: "powermate.midi.channel") != nil {
            midiController.channel = UInt8(d.integer(forKey: "powermate.midi.channel"))
        }
        // DDC/CI enabled
        if d.object(forKey: "powermate.ddc.enabled") != nil {
            brightnessController.ddcController.isEnabled = d.bool(forKey: "powermate.ddc.enabled")
        }
        // Sync launch-at-login with actual SMAppService status
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        NSLog("Settings: mode=%@ step=%.0f%% led=%d login=%d ddc=%d midi=CC%d/ch%d", currentMode.rawValue, stepSize * 100, ledFollowsLevel, launchAtLogin, brightnessController.ddcController.isEnabled, midiController.ccNumber, midiController.channel + 1)
    }

    private func saveSettings() {
        let d = UserDefaults.standard
        // Persist the current UI policy as Custom-only, regardless of legacy settings.
        d.set(KnobMode.custom.rawValue, forKey: "powermate.currentMode")
        d.set([KnobMode.custom.rawValue], forKey: "powermate.enabledModes")
        d.set(stepSize, forKey: "powermate.stepSize")
        d.set(ledFollowsLevel, forKey: "powermate.ledFollowsLevel")
        d.set(powerMate.longPressThreshold, forKey: "powermate.longPressThreshold")
        d.set(powerMate.doubleTapInterval, forKey: "powermate.doubleTapInterval")
        d.set(volumeSnapValue, forKey: "powermate.volume.snapValue")
        d.set(brightnessSnapValue, forKey: "powermate.brightness.snapValue")
        d.set(Int(midiController.ccNumber), forKey: "powermate.midi.ccNumber")
        d.set(Int(midiController.channel), forKey: "powermate.midi.channel")
    }
}
