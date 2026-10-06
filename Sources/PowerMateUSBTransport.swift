import Foundation
import IOKit
import IOKit.hid

let kPowerMateVendorID: Int = 0x077d
let kPowerMateProductID: Int = 0x0410

private final class USBDeviceState {
    weak var owner: PowerMateUSBTransport?

    let hidDevice: IOHIDDevice
    let identity: PowerMateHardwareIdentity
    let locationID: String

    var lastButtonState = false
    var ledBrightness: UInt8 = 0
    var reportBuffer: UnsafeMutablePointer<UInt8>?

    init(
        owner: PowerMateUSBTransport,
        hidDevice: IOHIDDevice,
        identity: PowerMateHardwareIdentity,
        locationID: String
    ) {
        self.owner = owner
        self.hidDevice = hidDevice
        self.identity = identity
        self.locationID = locationID
    }

    deinit {
        reportBuffer?.deallocate()
    }
}

/// USB HID transport capable of owning multiple physical USB PowerMates.
class PowerMateUSBTransport: PowerMateTransport {
    weak var transportDelegate: PowerMateTransportDelegate?

    private var manager: IOHIDManager?
    private var devices: [String: USBDeviceState] = [:]

    private(set) var ledBrightness: UInt8 = 0

    init() {}

    func start() {
        guard manager == nil else { return }

        let manager = IOHIDManagerCreate(
            kCFAllocatorDefault,
            IOOptionBits(kIOHIDOptionsTypeNone)
        )
        self.manager = manager

        let matchDict: [String: Any] = [
            kIOHIDVendorIDKey as String: kPowerMateVendorID,
            kIOHIDProductIDKey as String: kPowerMateProductID
        ]

        IOHIDManagerSetDeviceMatching(manager, matchDict as CFDictionary)

        let matchCallback: IOHIDDeviceCallback = {
            context, _, _, device in

            guard let context else { return }

            let transport = Unmanaged<PowerMateUSBTransport>
                .fromOpaque(context)
                .takeUnretainedValue()

            transport.onDeviceMatched(device)
        }

        let removeCallback: IOHIDDeviceCallback = {
            context, _, _, device in

            guard let context else { return }

            let transport = Unmanaged<PowerMateUSBTransport>
                .fromOpaque(context)
                .takeUnretainedValue()

            transport.onDeviceRemoved(device)
        }

        let context = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(
            manager,
            matchCallback,
            context
        )

        IOHIDManagerRegisterDeviceRemovalCallback(
            manager,
            removeCallback,
            context
        )

        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )

        let result = IOHIDManagerOpen(
            manager,
            IOOptionBits(kIOHIDOptionsTypeNone)
        )

        if result != kIOReturnSuccess {
            NSLog(
                "PowerMate USB: failed to open HID manager: 0x%08X",
                result
            )
        }
    }

    func stop() {
        if let manager {
            IOHIDManagerClose(
                manager,
                IOOptionBits(kIOHIDOptionsTypeNone)
            )

            IOHIDManagerUnscheduleFromRunLoop(
                manager,
                CFRunLoopGetMain(),
                CFRunLoopMode.commonModes.rawValue
            )
        }

        devices.removeAll()
        manager = nil
    }

    var isConnected: Bool {
        !devices.isEmpty
    }

    // MARK: - LED Control

    func setLEDBrightness(_ brightness: UInt8) {
        ledBrightness = brightness

        for state in devices.values {
            state.ledBrightness = brightness
            _ = sendOutputReport(brightness, to: state.hidDevice)
        }
    }

    func setLEDBrightness(
        _ brightness: UInt8,
        for identity: PowerMateHardwareIdentity
    ) {
        guard
            case .usb(let locationID) = identity,
            let state = devices[locationID]
        else {
            return
        }

        state.ledBrightness = brightness
        _ = sendOutputReport(brightness, to: state.hidDevice)
    }

    @discardableResult
    private func sendOutputReport(
        _ value: UInt8,
        to device: IOHIDDevice
    ) -> Bool {
        var report = [value]

        let result = IOHIDDeviceSetReport(
            device,
            kIOHIDReportTypeOutput,
            0,
            &report,
            report.count
        )

        return result == kIOReturnSuccess
    }

    // MARK: - Device Matching

    private func locationID(for device: IOHIDDevice) -> String? {
        guard
            let value = IOHIDDeviceGetProperty(
                device,
                kIOHIDLocationIDKey as CFString
            )
        else {
            return nil
        }

        if let number = value as? NSNumber {
            return String(
                format: "0x%08X",
                number.uint32Value
            )
        }

        if let string = value as? NSString {
            return string as String
        }

        return nil
    }

    private func state(
        matching device: IOHIDDevice
    ) -> USBDeviceState? {
        devices.values.first { $0.hidDevice === device }
    }

    private func onDeviceMatched(_ hidDevice: IOHIDDevice) {
        guard let locationID = locationID(for: hidDevice) else {
            NSLog("PowerMate USB: matched device has no Location ID")
            return
        }

        guard devices[locationID] == nil else {
            return
        }

        let identity = PowerMateHardwareIdentity.usb(
            locationID: locationID
        )

        let state = USBDeviceState(
            owner: self,
            hidDevice: hidDevice,
            identity: identity,
            locationID: locationID
        )

        state.ledBrightness = ledBrightness
        devices[locationID] = state

        let reportSize = 6
        let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(
            capacity: reportSize
        )
        state.reportBuffer = reportBuffer

        let context = Unmanaged.passUnretained(state).toOpaque()

        let inputCallback: IOHIDReportCallback = {
            context, _, _, _, _, report, reportLength in

            guard
                let context,
                reportLength >= 2
            else {
                return
            }

            let state = Unmanaged<USBDeviceState>
                .fromOpaque(context)
                .takeUnretainedValue()

            state.owner?.onInputReport(
                report,
                length: reportLength,
                state: state
            )
        }

        IOHIDDeviceRegisterInputReportCallback(
            hidDevice,
            reportBuffer,
            reportSize,
            inputCallback,
            context
        )

        NSLog(
            "PowerMate USB connected: %@",
            locationID
        )

        DispatchQueue.main.async {
            self.transportDelegate?.transportDidConnect(
                self,
                identity: identity
            )
        }
    }

    private func onDeviceRemoved(_ hidDevice: IOHIDDevice) {
        guard let state = state(matching: hidDevice) else {
            return
        }

        let identity = state.identity
        devices.removeValue(forKey: state.locationID)

        DispatchQueue.main.async {
            self.transportDelegate?.transportDidDisconnect(
                self,
                identity: identity
            )
        }
    }

    private func onInputReport(
        _ report: UnsafeMutablePointer<UInt8>,
        length: CFIndex,
        state: USBDeviceState
    ) {
        guard length >= 2 else { return }

        let buttonPressed = (report[0] & 0x01) != 0
        let rotation = Int(Int8(bitPattern: report[1]))

        DispatchQueue.main.async {
            if buttonPressed != state.lastButtonState {
                state.lastButtonState = buttonPressed
                self.transportDelegate?.transport(
                    self,
                    identity: state.identity,
                    buttonStateChanged: buttonPressed
                )
            }

            if rotation != 0 {
                self.transportDelegate?.transport(
                    self,
                    identity: state.identity,
                    didRotate: rotation
                )
            }
        }
    }
}
