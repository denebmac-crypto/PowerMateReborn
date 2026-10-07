import AppKit
import Foundation
import CoreGraphics
import CoreMIDI

// MARK: - Codable Models

enum CodableActionType: String, Codable, CaseIterable, Identifiable {
    case unassigned
    case scroll
    case keyboard
    case media
    case midiCC
    case midiNote
    case osc
    case canvasRotate

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .unassigned: return "Unassigned"
        case .scroll:     return "Scroll"
        case .keyboard:   return "Keyboard Shortcut"
        case .media:      return "Media Control"
        case .midiCC:     return "MIDI CC (Continuous)"
        case .midiNote:   return "MIDI Note"
        case .osc:        return "OSC Message"
        case .canvasRotate: return "Canvas Rotate"
        }
    }
}

enum CodableHoldBehavior: String, Codable, CaseIterable, Identifiable {
    case longPress
    case extendedPress
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .longPress:     return "Long Press (Trigger after delay)"
        case .extendedPress: return "Extended Press (Hold to sustain)"
        }
    }
}

enum ScrollDirection: String, Codable, CaseIterable {
    case up, down, left, right
}

enum CanvasRotateMethod: String, Codable, CaseIterable, Identifiable {
    /// Wacom/Quartz native rotation gesture used by Wacom tablet drivers.
    case wacomNativeGesture
    /// Photoshop/Wacom-compatible undocumented keyboard command.
    case optionF13F14
    /// Cursor-free Shift + mouse wheel fallback.
    case continuousShiftWheel
    /// Discrete Shift + mouse wheel fallback.
    case shiftWheel

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wacomNativeGesture:
            return "Wacom Native Rotation Gesture"
        case .optionF13F14:
            return "Option + F13/F14 (Photoshop/Wacom)"
        case .continuousShiftWheel:
            return "Shift + Mouse Wheel (Continuous)"
        case .shiftWheel:
            return "Shift + Mouse Wheel (Discrete)"
        }
    }

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        switch rawValue {
        case "wacomNativeGesture": self = .wacomNativeGesture
        case "optionF13F14": self = .optionF13F14
        case "continuousShiftWheel", "wacomKeystroke", "cspShortcut", "rDrag": self = .continuousShiftWheel
        case "shiftWheel": self = .shiftWheel
        default: self = .wacomNativeGesture
        }
    }
}

enum MediaCommand: String, Codable, CaseIterable {
    case playPause = "Play/Pause"
    case nextTrack = "Next"
    case prevTrack = "Prev"
}

struct KeyboardShortcut: Codable, Equatable {
    var keyCode: UInt16 = 0
    var modifiers: UInt64 = 0  // CGEventFlags raw value
    var displayString: String = ""
}

struct MIDICCConfig: Codable, Equatable {
    var ccNumber: UInt8 = 1
    var channel: UInt8 = 0   // 0-indexed
}

struct MIDINoteConfig: Codable, Equatable {
    var noteNumber: UInt8 = 60
    var velocity: UInt8 = 127
    var channel: UInt8 = 0
}

struct OSCConfig: Codable, Equatable {
    var path: String = "/trigger"
    var host: String = "127.0.0.1"
    var port: UInt16 = 8000
}

struct CodableActionConfig: Codable, Equatable {
    var type: CodableActionType = .unassigned

    // Type-specific parameters (only the relevant one is used)
    var scrollDirection: ScrollDirection = .up
    var mediaCommand: MediaCommand = .playPause
    var keyboardShortcut: KeyboardShortcut = KeyboardShortcut()
    var midiCC: MIDICCConfig = MIDICCConfig()
    var midiNote: MIDINoteConfig = MIDINoteConfig()
    var osc: OSCConfig = OSCConfig()

    // Tunable amounts are persisted per Action so every Profile/App mapping
    // can have its own sensitivity without changing global device settings.
    var scrollAmount: Int = 3
    var canvasRotateMethod: CanvasRotateMethod = .wacomNativeGesture
    var canvasRotateAmount: Int = 1

    init(
        type: CodableActionType = .unassigned,
        scrollDirection: ScrollDirection = .up,
        mediaCommand: MediaCommand = .playPause,
        keyboardShortcut: KeyboardShortcut = KeyboardShortcut(),
        midiCC: MIDICCConfig = MIDICCConfig(),
        midiNote: MIDINoteConfig = MIDINoteConfig(),
        osc: OSCConfig = OSCConfig(),
        scrollAmount: Int = 3,
        canvasRotateMethod: CanvasRotateMethod = .wacomNativeGesture,
        canvasRotateAmount: Int = 1
    ) {
        self.type = type
        self.scrollDirection = scrollDirection
        self.mediaCommand = mediaCommand
        self.keyboardShortcut = keyboardShortcut
        self.midiCC = midiCC
        self.midiNote = midiNote
        self.osc = osc
        self.scrollAmount = scrollAmount
        self.canvasRotateMethod = canvasRotateMethod
        self.canvasRotateAmount = canvasRotateAmount
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case scrollDirection
        case mediaCommand
        case keyboardShortcut
        case midiCC
        case midiNote
        case osc
        case scrollAmount
        case canvasRotateMethod
        case canvasRotateAmount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        type = try container.decodeIfPresent(CodableActionType.self, forKey: .type) ?? .unassigned
        scrollDirection = try container.decodeIfPresent(ScrollDirection.self, forKey: .scrollDirection) ?? .up
        mediaCommand = try container.decodeIfPresent(MediaCommand.self, forKey: .mediaCommand) ?? .playPause
        keyboardShortcut = try container.decodeIfPresent(KeyboardShortcut.self, forKey: .keyboardShortcut) ?? KeyboardShortcut()
        midiCC = try container.decodeIfPresent(MIDICCConfig.self, forKey: .midiCC) ?? MIDICCConfig()
        midiNote = try container.decodeIfPresent(MIDINoteConfig.self, forKey: .midiNote) ?? MIDINoteConfig()
        osc = try container.decodeIfPresent(OSCConfig.self, forKey: .osc) ?? OSCConfig()
        scrollAmount = try container.decodeIfPresent(Int.self, forKey: .scrollAmount) ?? 3
        canvasRotateMethod = try container.decodeIfPresent(CanvasRotateMethod.self, forKey: .canvasRotateMethod) ?? .continuousShiftWheel
        canvasRotateAmount = try container.decodeIfPresent(Int.self, forKey: .canvasRotateAmount) ?? 1
    }
}

struct CodableAppProfile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var isGlobal: Bool = false
    var bundleIdentifier: String?
    var iconName: String = "app"

    var rotateLeft: CodableActionConfig = CodableActionConfig(type: .unassigned)
    var rotateRight: CodableActionConfig = CodableActionConfig(type: .unassigned)
    var singleClick: CodableActionConfig = CodableActionConfig(type: .unassigned)
    var doubleClick: CodableActionConfig = CodableActionConfig(type: .unassigned)

    var overrideLongPress: Bool = false
    var holdBehavior: CodableHoldBehavior = .longPress
    var longPressAction: CodableActionConfig = CodableActionConfig(type: .unassigned)
}

// MARK: - Custom Mode Engine

class CustomModeEngine: ObservableObject {
    static let shared = CustomModeEngine()

    @Published var profiles: [CodableAppProfile] = []
    @Published var activeProfileID: UUID?

    private var frontmostObserver: Any?
    private var currentBundleID: String?

    let oscController = OSCController()
    let midiController = MIDIController()

    // Extended press state (legacy single-profile mode)
    private(set) var extendedPressActive: Bool = false
    private var extendedPressAction: CodableActionConfig?

    // Extended press state for device-assigned profiles.
    private var deviceExtendedPressActions: [PowerMateHardwareIdentity: CodableActionConfig] = [:]

    // One shared cursor-free CSP rotation gesture across all physical PowerMates.
    // Multiple devices can feed the same continuous scroll stream safely.
    private var continuousCanvasRotateActive = false
    private var continuousCanvasRotateEndWorkItem: DispatchWorkItem?
    // 0.20 s was short enough to split slow single-device turns into separate
    // began/ended gestures. 0.50 s keeps the stream alive during deliberate turns.
    private let continuousCanvasRotateIdleTimeout: TimeInterval = 0.50

    // CC accumulator for continuous rotation actions
    private var ccAccumulators: [UInt8: Float] = [:]  // ccNumber -> current 0-127 float

    init() {
        loadProfiles()
        if profiles.isEmpty {
            profiles = [defaultGlobalProfile()]
            saveProfiles()
        }
        startAppObserver()
        resolveActiveProfile()
    }

    // MARK: - Profile Management

    private func defaultGlobalProfile() -> CodableAppProfile {
        var p = CodableAppProfile(name: "Global Default", isGlobal: true, iconName: "globe")
        p.rotateLeft = CodableActionConfig(type: .scroll, scrollDirection: .up)
        p.rotateRight = CodableActionConfig(type: .scroll, scrollDirection: .down)
        p.singleClick = CodableActionConfig(type: .media, mediaCommand: .playPause)
        return p
    }

    func addProfile(name: String, bundleIdentifier: String, iconName: String = "app") {
        let profile = CodableAppProfile(
            name: name,
            bundleIdentifier: bundleIdentifier,
            iconName: iconName
        )
        profiles.append(profile)
        saveProfiles()
    }

    func removeProfile(id: UUID) {
        profiles.removeAll { $0.id == id && !$0.isGlobal }
        saveProfiles()
    }

    func updateProfile(_ profile: CodableAppProfile) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
            saveProfiles()
        }
    }

    var globalProfile: CodableAppProfile? {
        profiles.first(where: { $0.isGlobal })
    }

    var activeProfile: CodableAppProfile? {
        if let id = activeProfileID {
            return profiles.first(where: { $0.id == id })
        }
        return globalProfile
    }

    // MARK: - App Observation

    private func startAppObserver() {
        frontmostObserver = NSWorkspace.shared.observe(
            \.frontmostApplication,
            options: [.new]
        ) { [weak self] workspace, change in
            DispatchQueue.main.async {
                self?.onFrontmostAppChanged()
            }
        }
        // Also observe via notification for reliability
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onFrontmostAppChanged()
        }
    }

    private func onFrontmostAppChanged() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let bundleID = app.bundleIdentifier ?? ""

        // PowerMateReborn's own settings window must not become the target
        // application for device profiles. Keep the last external app so
        // opening the Devices & Profiles window does not silently switch
        // Custom Mode back to the reusable Profile's Default mapping.
        if bundleID == Bundle.main.bundleIdentifier {
            return
        }

        guard bundleID != currentBundleID else { return }
        currentBundleID = bundleID
        resolveActiveProfile()
    }

    private func resolveActiveProfile() {
        let bundleID = currentBundleID ?? ""

        // Find a profile matching the frontmost app
        if let match = profiles.first(where: {
            !$0.isGlobal && $0.bundleIdentifier == bundleID
        }) {
            if activeProfileID != match.id {
                activeProfileID = match.id
                NSLog("Custom: activated profile '%@' for %@", match.name, bundleID)
            }
        } else {
            // Fall back to global
            if let global = globalProfile, activeProfileID != global.id {
                activeProfileID = global.id
                NSLog("Custom: using Global Default for %@", bundleID)
            }
        }
    }

    // MARK: - Gesture Dispatch

    /// Select the application profile inside a device-assigned reusable Profile.
    /// A non-global profile matching the frontmost application's bundle ID wins;
    /// otherwise the reusable profile's Global Default is used.
    func activeAppProfile(in profile: PowerMateProfile) -> CodableAppProfile? {
        // Resolve the frontmost application at the moment of input. The
        // cached observer value is only a fallback; otherwise a Profile
        // edited for CSP could accidentally execute its Default mapping.
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let bundleID: String

        if let frontmostBundleID,
           frontmostBundleID != Bundle.main.bundleIdentifier {
            bundleID = frontmostBundleID
        } else {
            bundleID = currentBundleID ?? ""
        }

        if let match = profile.appProfiles.first(where: {
            !$0.isGlobal && $0.bundleIdentifier == bundleID
        }) {
            return match
        }

        let fallback = profile.appProfiles.first(where: { $0.isGlobal })
            ?? profile.appProfiles.first

        return fallback
    }

    /// Device-aware rotation dispatch. The reusable device Profile supplies
    /// the actual Custom Mode mapping while the existing action executor remains shared.
    func handleRotation(
        delta: Int,
        stepSize: Float,
        profile: PowerMateProfile
    ) {
        guard let appProfile = activeAppProfile(in: profile) else { return }
        let action = delta > 0 ? appProfile.rotateRight : appProfile.rotateLeft
        let magnitude = abs(delta)

        for _ in 0..<magnitude {
            executeAction(
                action,
                rotationDelta: delta > 0 ? 1 : -1,
                stepSize: stepSize
            )
        }
    }

    func handleSingleTap(profile: PowerMateProfile) {
        guard let appProfile = activeAppProfile(in: profile) else { return }
        executeAction(appProfile.singleClick)
    }

    func handleDoubleTap(profile: PowerMateProfile) {
        guard let appProfile = activeAppProfile(in: profile) else { return }
        executeAction(appProfile.doubleClick)
    }

    /// Device-aware long-press override. Returns true when the assigned
    /// profile intentionally consumes the global mode-cycle gesture.
    func handleLongPress(
        profile: PowerMateProfile,
        identity: PowerMateHardwareIdentity
    ) -> Bool {
        guard let appProfile = activeAppProfile(in: profile) else {
            return false
        }

        guard appProfile.overrideLongPress,
              appProfile.longPressAction.type != .unassigned else {
            return false
        }

        let action = appProfile.longPressAction

        if appProfile.holdBehavior == .extendedPress {
            deviceExtendedPressActions[identity] = action
            executeExtendedPressStart(action)
        } else {
            executeAction(action)
        }

        return true
    }

    func handleButtonReleased(
        profile: PowerMateProfile,
        identity: PowerMateHardwareIdentity
    ) {
        guard let action = deviceExtendedPressActions.removeValue(forKey: identity) else {
            return
        }

        executeExtendedPressEnd(action)
    }

    /// Whether the reusable device profile overrides global mode cycling.
    func longPressOverridesModeCycle(profile: PowerMateProfile) -> Bool {
        guard let appProfile = activeAppProfile(in: profile) else {
            return false
        }

        return appProfile.overrideLongPress &&
            appProfile.longPressAction.type != .unassigned
    }

    func handleRotation(delta: Int, stepSize: Float) {
        guard let profile = activeProfile else { return }
        let action = delta > 0 ? profile.rotateRight : profile.rotateLeft
        let magnitude = abs(delta)

        for _ in 0..<magnitude {
            executeAction(action, rotationDelta: delta > 0 ? 1 : -1, stepSize: stepSize)
        }
    }

    func handleSingleTap() {
        guard let profile = activeProfile else { return }
        executeAction(profile.singleClick)
    }

    func handleDoubleTap() {
        guard let profile = activeProfile else { return }
        executeAction(profile.doubleClick)
    }

    /// Returns true if the long press was consumed by a custom override (caller should NOT cycle modes)
    func handleLongPress() -> Bool {
        guard let profile = activeProfile, profile.overrideLongPress else {
            return false
        }

        let action = profile.longPressAction
        guard action.type != .unassigned else { return false }

        if profile.holdBehavior == .extendedPress {
            // Extended press: start sustaining
            extendedPressActive = true
            extendedPressAction = action
            executeExtendedPressStart(action)
        } else {
            // Long press: fire once
            executeAction(action)
        }
        return true
    }

    func handleButtonReleased() {
        guard extendedPressActive, let action = extendedPressAction else { return }
        extendedPressActive = false
        extendedPressAction = nil
        executeExtendedPressEnd(action)
    }

    /// Whether the current profile overrides global mode cycling
    var longPressOverridesModeCycle: Bool {
        guard let profile = activeProfile else { return false }
        return profile.overrideLongPress && profile.longPressAction.type != .unassigned
    }

    // MARK: - Action Execution

    private func executeAction(_ action: CodableActionConfig, rotationDelta: Int = 0, stepSize: Float = 0.03) {
        switch action.type {
        case .unassigned:
            break

        case .scroll:
            executeScroll(
                action.scrollDirection,
                magnitude: action.scrollAmount
            )

        case .keyboard:
            executeKeyboardShortcut(action.keyboardShortcut)

        case .media:
            executeMediaCommand(action.mediaCommand)

        case .midiCC:
            executeMIDICC(action.midiCC, delta: stepSize * Float(rotationDelta != 0 ? rotationDelta : 1))

        case .midiNote:
            executeMIDINoteToggle(action.midiNote)

        case .osc:
            if rotationDelta != 0 {
                // For rotation: send float value based on accumulated CC
                let cc = action.midiCC.ccNumber
                let current = ccAccumulators[cc] ?? 64.0
                let newVal = max(0, min(127, current + Float(rotationDelta) * stepSize * 127.0))
                ccAccumulators[cc] = newVal
                oscController.sendFloat(action.osc.path, value: newVal / 127.0, host: action.osc.host, port: action.osc.port)
            } else {
                // For button press: send trigger
                oscController.sendTrigger(action.osc.path, host: action.osc.host, port: action.osc.port)
            }

        case .canvasRotate:
            guard rotationDelta != 0 else { return }
            executeCanvasRotate(
                method: action.canvasRotateMethod,
                rotationDelta: rotationDelta,
                amount: action.canvasRotateAmount,
                action: action
            )
        }
    }

    // MARK: - Scroll

    private func executeScroll(_ direction: ScrollDirection, magnitude: Int) {
        let normalizedMagnitude = max(1, min(20, magnitude))
        var dx: Int32 = 0
        var dy: Int32 = 0

        switch direction {
        case .up:
            dy = Int32(normalizedMagnitude)
        case .down:
            dy = Int32(-normalizedMagnitude)
        case .left:
            dx = Int32(normalizedMagnitude)
        case .right:
            dx = Int32(-normalizedMagnitude)
        }

        guard let event = CGEvent(
            scrollWheelEvent2Source: CGEventSource(stateID: .hidSystemState),
            units: .line,
            wheelCount: 2,
            wheel1: dy,
            wheel2: dx,
            wheel3: 0
        ) else {
            return
        }

        // The persisted per-action Scroll Amount is the final wheel delta.
        event.setIntegerValueField(
            .scrollWheelEventIsContinuous,
            value: 0
        )
        event.post(tap: .cgSessionEventTap)
    }

    // MARK: - Keyboard Shortcut

    private func executeKeyboardShortcut(_ shortcut: KeyboardShortcut) {
        guard shortcut.keyCode != 0 || shortcut.modifiers != 0 else { return }

        let flags = CGEventFlags(rawValue: shortcut.modifiers)

        // Key down
        if let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: true) {
            keyDown.flags = flags
            keyDown.post(tap: .cgSessionEventTap)
        }

        // Key up
        if let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: false) {
            keyUp.flags = flags
            keyUp.post(tap: .cgSessionEventTap)
        }
    }

    // MARK: - Canvas Rotation

    private func executeCanvasRotate(
        method: CanvasRotateMethod,
        rotationDelta: Int,
        amount: Int,
        action: CodableActionConfig
    ) {
        switch method {
        case .wacomNativeGesture:
            let steps = max(1, min(20, amount))
            WacomNativeGestureEmitter.shared.sendRotation(stepCount: Int32(steps * rotationDelta))

        case .optionF13F14:
            let steps = max(1, min(20, amount))
            let keyCode: CGKeyCode = rotationDelta > 0 ? 105 : 107
            executeOptionFunctionKeyRotation(keyCode: keyCode, steps: steps)

        case .continuousShiftWheel:
            let pixels = max(1, min(20, amount))
            executeCanvasRotateShiftWheel(
                delta: Int32(pixels * rotationDelta)
            )
        }
    }

    /// CSP officially documents Shift + mouse wheel as a canvas-rotation
    /// operation. The important part here is preserving the scroll gesture:
    /// one began event, followed by changed events, then one ended event.
    ///
    /// The previous implementation ended the gesture after only 0.20 s of
    /// inactivity. That could split a deliberate single-device turn into
    /// separate gestures. The old two-device test accidentally kept this
    /// shared stream alive because the second device kept resetting the
    /// timeout. Keep that useful behavior intentionally, without requiring
    /// two devices or moving the cursor.
    private func executeCanvasRotateContinuousShiftWheel(delta: Int32) {
        guard delta != 0 else { return }

        continuousCanvasRotateEndWorkItem?.cancel()

        let source = CGEventSource(stateID: .hidSystemState)
        let phase: CGScrollPhase = continuousCanvasRotateActive ? .changed : .began

        if !continuousCanvasRotateActive {
            guard let shiftDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: 56,
                keyDown: true
            ) else {
                return
            }

            shiftDown.flags = .maskShift
            shiftDown.post(tap: .cgSessionEventTap)
            continuousCanvasRotateActive = true
        }

        guard let wheel = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 1,
            wheel1: delta,
            wheel2: 0,
            wheel3: 0
        ) else {
            endCanvasRotateContinuousShiftWheel()
            return
        }

        wheel.flags = .maskShift
        wheel.setIntegerValueField(
            .scrollWheelEventIsContinuous,
            value: 1
        )
        wheel.setDoubleValueField(
            .scrollWheelEventFixedPtDeltaAxis1,
            value: Double(delta)
        )
        wheel.setIntegerValueField(
            .scrollWheelEventScrollPhase,
            value: Int64(phase.rawValue)
        )
        wheel.setIntegerValueField(
            .scrollWheelEventMomentumPhase,
            value: 0
        )
        wheel.post(tap: .cgSessionEventTap)

        let endWorkItem = DispatchWorkItem { [weak self] in
            self?.endCanvasRotateContinuousShiftWheel()
        }
        continuousCanvasRotateEndWorkItem = endWorkItem

        DispatchQueue.main.asyncAfter(
            deadline: .now() + continuousCanvasRotateIdleTimeout,
            execute: endWorkItem
        )
    }

    private func endCanvasRotateContinuousShiftWheel() {
        continuousCanvasRotateEndWorkItem?.cancel()
        continuousCanvasRotateEndWorkItem = nil

        guard continuousCanvasRotateActive else { return }

        let source = CGEventSource(stateID: .hidSystemState)

        if let wheelEnd = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 1,
            wheel1: 0,
            wheel2: 0,
            wheel3: 0
        ) {
            wheelEnd.flags = .maskShift
            wheelEnd.setIntegerValueField(
                .scrollWheelEventIsContinuous,
                value: 1
            )
            wheelEnd.setDoubleValueField(
                .scrollWheelEventFixedPtDeltaAxis1,
                value: 0
            )
            wheelEnd.setIntegerValueField(
                .scrollWheelEventScrollPhase,
                value: Int64(CGScrollPhase.ended.rawValue)
            )
            wheelEnd.setIntegerValueField(
                .scrollWheelEventMomentumPhase,
                value: 0
            )
            wheelEnd.post(tap: .cgSessionEventTap)
        }

        if let shiftUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: 56,
            keyDown: false
        ) {
            shiftUp.flags = []
            shiftUp.post(tap: .cgSessionEventTap)
        }

        continuousCanvasRotateActive = false
    }

    /// Known-good cursor-free fallback: CSP's Shift + mouse wheel.
    private func executeCanvasRotateShiftWheel(delta: Int32) {
        let source = CGEventSource(stateID: .hidSystemState)

        if let shiftDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: 56,
            keyDown: true
        ) {
            shiftDown.flags = .maskShift
            shiftDown.post(tap: .cgSessionEventTap)
        }

        if let wheel = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 1,
            wheel1: delta,
            wheel2: 0,
            wheel3: 0
        ) {
            wheel.flags = .maskShift
            wheel.post(tap: .cgSessionEventTap)
        }

        if let shiftUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: 56,
            keyDown: false
        ) {
            shiftUp.flags = []
            shiftUp.post(tap: .cgSessionEventTap)
        }
    }

    /// Emits Option + F13/F14 as one modifier-held burst.
    /// PowerMate delta determines how many F13/F14 pulses are generated.
    private func executeOptionFunctionKeyRotation(
        keyCode: CGKeyCode,
        steps: Int
    ) {
        let source = CGEventSource(stateID: .hidSystemState)

        // Hold Option across the whole burst so multiple PowerMate steps do
        // not produce a sequence of unrelated modifier transitions.
        if let optionDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: 58,
            keyDown: true
        ) {
            optionDown.flags = .maskAlternate
            optionDown.post(tap: .cgSessionEventTap)
        }

        for _ in 0..<steps {
            postKeyEvent(
                keyCode: keyCode,
                flags: .maskAlternate,
                keyDown: true
            )
            postKeyEvent(
                keyCode: keyCode,
                flags: .maskAlternate,
                keyDown: false
            )
        }

        if let optionUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: 58,
            keyDown: false
        ) {
            optionUp.flags = []
            optionUp.post(tap: .cgSessionEventTap)
        }

        NSLog(
            "Custom: Option+F13/F14 rotation keyCode=%d steps=%d",
            keyCode,
            steps
        )
    }

    private func postKeyEvent(
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        keyDown: Bool
    ) {
        guard let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: keyCode,
            keyDown: keyDown
        ) else {
            return
        }

        event.flags = flags
        event.post(tap: .cgSessionEventTap)
    }

    // MARK: - Media Keys

    private func executeMediaCommand(_ command: MediaCommand) {
        let keyCode: Int64
        switch command {
        case .playPause: keyCode = Int64(NX_KEYTYPE_PLAY)
        case .nextTrack: keyCode = Int64(NX_KEYTYPE_NEXT)
        case .prevTrack: keyCode = Int64(NX_KEYTYPE_PREVIOUS)
        }

        func postMediaKey(_ keyCode: Int64, down: Bool) {
            let flags: Int64 = down ? 0xa00 : 0xb00
            let data1 = (keyCode << 16) | (flags << 16)
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: Int(data1),
                data2: -1
            )
            event?.cgEvent?.post(tap: .cgSessionEventTap)
        }

        postMediaKey(keyCode, down: true)
        postMediaKey(keyCode, down: false)
    }

    // MARK: - MIDI

    private func executeMIDICC(_ config: MIDICCConfig, delta: Float) {
        let cc = config.ccNumber
        let current = ccAccumulators[cc] ?? 64.0
        let newVal = max(0, min(127, current + delta * 127.0))
        ccAccumulators[cc] = newVal

        let saved = (midiController.ccNumber, midiController.channel)
        midiController.ccNumber = cc
        midiController.channel = config.channel
        midiController.setCC(UInt8(newVal))
        midiController.ccNumber = saved.0
        midiController.channel = saved.1
    }

    private func executeMIDINoteToggle(_ config: MIDINoteConfig) {
        let saved = (midiController.noteNumber, midiController.noteVelocity, midiController.channel)
        midiController.noteNumber = config.noteNumber
        midiController.noteVelocity = config.velocity
        midiController.channel = config.channel
        midiController.toggleNote()
        midiController.noteNumber = saved.0
        midiController.noteVelocity = saved.1
        midiController.channel = saved.2
    }

    private func executeMIDINoteOn(_ config: MIDINoteConfig) {
        let saved = (midiController.noteNumber, midiController.noteVelocity, midiController.channel)
        midiController.noteNumber = config.noteNumber
        midiController.noteVelocity = config.velocity
        midiController.channel = config.channel
        midiController.sendNoteOn()
        midiController.noteNumber = saved.0
        midiController.noteVelocity = saved.1
        midiController.channel = saved.2
    }

    private func executeMIDINoteOff(_ config: MIDINoteConfig) {
        let saved = (midiController.noteNumber, midiController.noteVelocity, midiController.channel)
        midiController.noteNumber = config.noteNumber
        midiController.noteVelocity = config.velocity
        midiController.channel = config.channel
        midiController.sendNoteOff()
        midiController.noteNumber = saved.0
        midiController.noteVelocity = saved.1
        midiController.channel = saved.2
    }

    // MARK: - Extended Press (Sustain)

    private func executeExtendedPressStart(_ action: CodableActionConfig) {
        NSLog("Custom: extended press START — %@", action.type.rawValue)
        switch action.type {
        case .keyboard:
            // Hold key down
            let shortcut = action.keyboardShortcut
            let flags = CGEventFlags(rawValue: shortcut.modifiers)
            if let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: true) {
                keyDown.flags = flags
                keyDown.post(tap: .cgSessionEventTap)
            }
        case .midiNote:
            executeMIDINoteOn(action.midiNote)
        case .osc:
            oscController.sendFloat(action.osc.path, value: 1.0, host: action.osc.host, port: action.osc.port)
        default:
            executeAction(action)
        }
    }

    private func executeExtendedPressEnd(_ action: CodableActionConfig) {
        NSLog("Custom: extended press END — %@", action.type.rawValue)
        switch action.type {
        case .keyboard:
            // Release key
            let shortcut = action.keyboardShortcut
            let flags = CGEventFlags(rawValue: UInt64(shortcut.modifiers))
            if let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: false) {
                keyUp.flags = flags
                keyUp.post(tap: .cgSessionEventTap)
            }
        case .midiNote:
            executeMIDINoteOff(action.midiNote)
        case .osc:
            oscController.sendFloat(action.osc.path, value: 0.0, host: action.osc.host, port: action.osc.port)
        default:
            break
        }
    }

    // MARK: - Persistence

    private let profilesKey = "powermate.custom.profiles"

    func saveProfiles() {
        do {
            let data = try JSONEncoder().encode(profiles)
            UserDefaults.standard.set(data, forKey: profilesKey)
            NSLog("Custom: saved %d profiles", profiles.count)
        } catch {
            NSLog("Custom: failed to save profiles: %@", error.localizedDescription)
        }
    }

    private func loadProfiles() {
        guard let data = UserDefaults.standard.data(forKey: profilesKey) else { return }
        do {
            profiles = try JSONDecoder().decode([CodableAppProfile].self, from: data)
            NSLog("Custom: loaded %d profiles", profiles.count)
        } catch {
            NSLog("Custom: failed to load profiles: %@", error.localizedDescription)
        }
    }

    // MARK: - Cleanup

    func shutdown() {
        WacomNativeGestureEmitter.shared.endRotation()

        for (_, action) in deviceExtendedPressActions {
            executeExtendedPressEnd(action)
        }
        deviceExtendedPressActions.removeAll()

        oscController.shutdown()
        if extendedPressActive, let action = extendedPressAction {
            executeExtendedPressEnd(action)
        }
    }
}
