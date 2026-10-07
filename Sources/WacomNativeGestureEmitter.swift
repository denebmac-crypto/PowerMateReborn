import Foundation
import CoreGraphics

/// Emits the low-level gesture event that Wacom IOManager produces for
/// native tablet rotation.
///
/// This intentionally does not generate a scroll-wheel event and does not
/// synthesize Shift/Space/R+drag shortcuts. The event layout mirrors the
/// Wacom driver's PostGesture:withAmount: output:
///
///   CGEvent type      = 29 (kCGSEventGesture)
///   field 110         = 5  (gesture HID type)
///   field 115         = Float32 bit pattern of the gesture amount
///   field 132         = gesture phase (1 began, 2 changed, 4 ended)
///
/// Wacom posts these events at the HID event tap location (location 0).
final class WacomNativeGestureEmitter {
    static let shared = WacomNativeGestureEmitter()

    private let lock = NSLock()
    private var active = false
    private var endWorkItem: DispatchWorkItem?
    private var zoomActive = false
    private var zoomEndWorkItem: DispatchWorkItem?
    private let zoomEventQueue = DispatchQueue(label: "PowerMateReborn.WacomZoom", qos: .userInteractive)
    private let zoomInterpolationSteps: Int = 8
    private let zoomInterpolationInterval: TimeInterval = 0.002
    private let idleTimeout: TimeInterval = 0.50

    private init() {}

    func sendRotation(stepCount: Int32, amountPerStep: Float = 1.925) {
        guard stepCount != 0 else { return }

        lock.lock()
        endWorkItem?.cancel()
        endWorkItem = nil

        let amount = Float(stepCount) * amountPerStep

        // Match Wacom's verified start sequence:
        // phase=1/amount=0, followed immediately by phase=2/actual amount.
        if !active {
            guard postGestureEvent(amount: 0, phase: 1) else {
                lock.unlock()
                return
            }
            guard postGestureEvent(amount: amount, phase: 2) else {
                lock.unlock()
                return
            }
            active = true
        } else {
            guard postGestureEvent(amount: amount, phase: 2) else {
                lock.unlock()
                return
            }
        }

        let posted = true

        let workItem = DispatchWorkItem { [weak self] in
            self?.endRotation()
        }
        endWorkItem = workItem
        lock.unlock()

        guard posted else { return }

        DispatchQueue.main.asyncAfter(
            deadline: .now() + idleTimeout,
            execute: workItem
        )
    }


    func sendZoom(stepCount: Int32, amountPerStep: Float = 0.1) {
        guard stepCount != 0 else { return }

        lock.lock()
        zoomEndWorkItem?.cancel()
        zoomEndWorkItem = nil

        let amount = Float(stepCount) * amountPerStep

        if !zoomActive {
            guard postZoomGestureEvent(amount: 0, phase: 1) else {
                lock.unlock()
                return
            }
            zoomActive = true
        }

        // PowerMate reports rotation continuously, but a single large
        // magnification delta makes CSP visibly "jump". Preserve the exact
        // total zoom amount while distributing it into several tiny changed
        // events over only a few milliseconds. The first event is immediate,
        // so this does not introduce the kind of perceptible latency caused
        // by shortcut bursts.
        let microAmount = amount / Float(zoomInterpolationSteps)
        for index in 0..<zoomInterpolationSteps {
            let delay = zoomInterpolationInterval * Double(index)
            zoomEventQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.postZoomGestureEvent(amount: microAmount, phase: 2)
            }
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.endZoom()
        }
        zoomEndWorkItem = workItem
        lock.unlock()

        DispatchQueue.main.asyncAfter(
            deadline: .now() + idleTimeout,
            execute: workItem
        )
    }

    private func endZoom() {
        lock.lock()
        zoomEndWorkItem?.cancel()
        zoomEndWorkItem = nil

        guard zoomActive else {
            lock.unlock()
            return
        }

        _ = postZoomGestureEvent(amount: 0, phase: 4)
        zoomActive = false
        lock.unlock()
    }

    private func postZoomGestureEvent(amount: Float, phase: Int64) -> Bool {
        guard
            let event = CGEvent(source: nil),
            let gestureType = CGEventType(rawValue: 29),
            let gestureField = CGEventField(rawValue: 110),
            let zoomField = CGEventField(rawValue: 113),
            let phaseField = CGEventField(rawValue: 132)
        else {
            NSLog("Wacom Native Zoom: failed to allocate event")
            return false
        }

        event.type = gestureType

        // kIOHIDEventTypeZoom = 8
        event.setIntegerValueField(gestureField, value: 8)

        // kCGEventGestureZoomValue = 113
        event.setDoubleValueField(zoomField, value: Double(amount))

        // kCGSGesturePhaseBegan = 1
        // kCGSGesturePhaseChanged = 2
        // kCGSGesturePhaseEnded = 4
        event.setIntegerValueField(phaseField, value: phase)

        event.post(tap: .cghidEventTap)

        NSLog(
            "Wacom Native Zoom: type=29 field110=8 field113=%.3f field132=%lld",
            amount,
            phase
        )
        return true
    }

    func endRotation() {
        lock.lock()
        endWorkItem?.cancel()
        endWorkItem = nil

        guard active else {
            lock.unlock()
            return
        }

        _ = postGestureEvent(amount: 0, phase: 4)
        active = false
        lock.unlock()
    }

    private func postGestureEvent(amount: Float, phase: Int64) -> Bool {
        guard
            let event = CGEvent(source: nil),
            let gestureType = CGEventType(rawValue: 29),
            let gestureField = CGEventField(rawValue: 110),
            let amountField = CGEventField(rawValue: 115),
            let phaseField = CGEventField(rawValue: 132)
        else {
            NSLog("Wacom Native Gesture: failed to allocate event")
            return false
        }

        event.type = gestureType

        // kCGEventGestureHIDType = 5
        event.setIntegerValueField(gestureField, value: 5)

        // Wacom stores the Float32 payload as its raw IEEE-754 bits.
        let bits = amount.bitPattern
        event.setIntegerValueField(
            amountField,
            value: Int64(Int32(bitPattern: bits))
        )

        // kCGSGesturePhaseBegan = 1
        // kCGSGesturePhaseChanged = 2
        // kCGSGesturePhaseEnded = 4
        event.setIntegerValueField(phaseField, value: phase)

        // Wacom IOManager calls CGEventPost(0, event), i.e. the HID tap.
        event.post(tap: .cghidEventTap)

        NSLog(
            "Wacom Native Gesture: type=29 field110=5 field115=%u field132=%lld amount=%.3f",
            bits,
            phase,
            amount
        )
        return true
    }
}
