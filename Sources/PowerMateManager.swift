import Foundation

// MARK: - High-Level Delegate

protocol PowerMateDelegate: AnyObject {
    func powerMateDidConnect(identity: PowerMateHardwareIdentity)
    func powerMateDidDisconnect(identity: PowerMateHardwareIdentity)
    func powerMateDidRotate(identity: PowerMateHardwareIdentity, delta: Int)
    func powerMateButtonPressed(identity: PowerMateHardwareIdentity)
    func powerMateButtonDoubleTapped(identity: PowerMateHardwareIdentity)
    func powerMateButtonLongPressed(identity: PowerMateHardwareIdentity)
    func powerMateButtonReleased(identity: PowerMateHardwareIdentity)
}

// MARK: - Transport Protocol

protocol PowerMateTransportDelegate: AnyObject {
    func transportDidConnect(
        _ transport: PowerMateTransport,
        identity: PowerMateHardwareIdentity
    )

    func transportDidDisconnect(
        _ transport: PowerMateTransport,
        identity: PowerMateHardwareIdentity
    )

    func transport(
        _ transport: PowerMateTransport,
        identity: PowerMateHardwareIdentity,
        didRotate delta: Int
    )

    func transport(
        _ transport: PowerMateTransport,
        identity: PowerMateHardwareIdentity,
        buttonStateChanged pressed: Bool
    )
}

protocol PowerMateTransport: AnyObject {
    var transportDelegate: PowerMateTransportDelegate? { get set }
    var isConnected: Bool { get }
    var ledBrightness: UInt8 { get }

    func start()
    func stop()
    func setLEDBrightness(_ brightness: UInt8)
    func setLEDBrightness(
        _ brightness: UInt8,
        for identity: PowerMateHardwareIdentity
    )
}

// MARK: - Per-device Gesture State

private final class GestureState {
    var buttonDownTime: Date?
    var longPressTimer: Timer?
    var longPressFired = false

    var tapCount = 0
    var singleTapTimer: Timer?

    var rotatedWhilePressed = false
    var lastButtonState = false

    func reset() {
        singleTapTimer?.invalidate()
        singleTapTimer = nil

        longPressTimer?.invalidate()
        longPressTimer = nil

        buttonDownTime = nil
        longPressFired = false
        tapCount = 0
        rotatedWhilePressed = false
        lastButtonState = false
    }

    deinit {
        reset()
    }
}

// MARK: - Manager

/// Central manager for all PowerMate hardware transports.
///
/// Gesture state is deliberately keyed by hardware identity so multiple
/// physical PowerMates can be used simultaneously without their button
/// sequences interfering with one another.
class PowerMateManager: PowerMateTransportDelegate {
    weak var delegate: PowerMateDelegate?

    private var transports: [PowerMateTransport] = []
    private var gestureStates: [PowerMateHardwareIdentity: GestureState] = [:]

    var longPressThreshold: TimeInterval = 0.5
    var doubleTapInterval: TimeInterval = 0.3

    private(set) var ledBrightness: UInt8 = 0

    init() {}

    // MARK: - Transport Management

    func addTransport(_ transport: PowerMateTransport) {
        transport.transportDelegate = self
        transports.append(transport)
    }

    func start() {
        transports.forEach { $0.start() }
    }

    func stop() {
        transports.forEach { $0.stop() }
        gestureStates.values.forEach { $0.reset() }
        gestureStates.removeAll()
    }

    var isConnected: Bool {
        transports.contains { $0.isConnected }
    }

    // MARK: - LED Control

    /// Broadcast LED brightness to every connected physical PowerMate.
    func setLEDBrightness(_ brightness: UInt8) {
        ledBrightness = brightness

        for transport in transports where transport.isConnected {
            transport.setLEDBrightness(brightness)
        }
    }

    /// Set LED brightness for exactly one physical PowerMate.
    func setLEDBrightness(
        _ brightness: UInt8,
        for identity: PowerMateHardwareIdentity
    ) {
        for transport in transports {
            transport.setLEDBrightness(brightness, for: identity)
        }
    }

    // MARK: - PowerMateTransportDelegate

    func transportDidConnect(
        _ transport: PowerMateTransport,
        identity: PowerMateHardwareIdentity
    ) {
        gestureStates[identity] = GestureState()

        // Sync the manager's current LED level only to the new device.
        transport.setLEDBrightness(ledBrightness, for: identity)

        delegate?.powerMateDidConnect(identity: identity)
    }

    func transportDidDisconnect(
        _ transport: PowerMateTransport,
        identity: PowerMateHardwareIdentity
    ) {
        gestureStates[identity]?.reset()
        gestureStates.removeValue(forKey: identity)

        delegate?.powerMateDidDisconnect(identity: identity)
    }

    func transport(
        _ transport: PowerMateTransport,
        identity: PowerMateHardwareIdentity,
        didRotate delta: Int
    ) {
        guard delta != 0 else { return }

        let state = state(for: identity)
        if state.buttonDownTime != nil {
            state.rotatedWhilePressed = true
        }

        delegate?.powerMateDidRotate(identity: identity, delta: delta)
    }

    func transport(
        _ transport: PowerMateTransport,
        identity: PowerMateHardwareIdentity,
        buttonStateChanged pressed: Bool
    ) {
        let state = state(for: identity)
        guard pressed != state.lastButtonState else { return }

        state.lastButtonState = pressed

        if pressed {
            onButtonDown(identity: identity, state: state)
        } else {
            onButtonUp(identity: identity, state: state)
        }
    }

    // MARK: - Gesture Detection

    private func state(for identity: PowerMateHardwareIdentity) -> GestureState {
        if let existing = gestureStates[identity] {
            return existing
        }

        let created = GestureState()
        gestureStates[identity] = created
        return created
    }

    private func onButtonDown(
        identity: PowerMateHardwareIdentity,
        state: GestureState
    ) {
        state.buttonDownTime = Date()
        state.longPressFired = false
        state.rotatedWhilePressed = false

        state.singleTapTimer?.invalidate()
        state.singleTapTimer = nil

        state.longPressTimer?.invalidate()
        state.longPressTimer = Timer.scheduledTimer(
            withTimeInterval: longPressThreshold,
            repeats: false
        ) { [weak self, weak state] _ in
            guard
                let self,
                let state,
                state.buttonDownTime != nil,
                !state.longPressFired
            else {
                return
            }

            state.longPressFired = true
            state.tapCount = 0
            state.singleTapTimer?.invalidate()
            state.singleTapTimer = nil

            self.delegate?.powerMateButtonLongPressed(identity: identity)
        }
    }

    private func onButtonUp(
        identity: PowerMateHardwareIdentity,
        state: GestureState
    ) {
        state.longPressTimer?.invalidate()
        state.longPressTimer = nil

        // Always expose the raw release for extended-press actions.
        delegate?.powerMateButtonReleased(identity: identity)

        guard !state.longPressFired else {
            state.buttonDownTime = nil
            state.longPressFired = false
            state.rotatedWhilePressed = false
            return
        }

        guard !state.rotatedWhilePressed else {
            state.buttonDownTime = nil
            state.rotatedWhilePressed = false
            return
        }

        state.tapCount += 1

        if state.tapCount >= 2 {
            state.tapCount = 0
            state.singleTapTimer?.invalidate()
            state.singleTapTimer = nil
            delegate?.powerMateButtonDoubleTapped(identity: identity)
        } else {
            state.singleTapTimer?.invalidate()
            state.singleTapTimer = Timer.scheduledTimer(
                withTimeInterval: doubleTapInterval,
                repeats: false
            ) { [weak self, weak state] _ in
                guard let self, let state else { return }
                state.tapCount = 0
                self.delegate?.powerMateButtonPressed(identity: identity)
            }
        }

        state.buttonDownTime = nil
        state.longPressFired = false
    }
}
