import Foundation

// Mirrors the Wacom driver's OIOManagerClient -> IOManager XPC path.
// The privileged Wacom service ultimately turns these dictionaries into
// the same type-29 gesture events consumed by native tablet gestures.
@objc private protocol WacomIOManagerRemote: NSObjectProtocol {
    func postEvent(_ event: NSDictionary)
}

final class WacomIOManagerBridge {
    static let shared = WacomIOManagerBridge()

    private let serviceName = "com.wacom.IOManager"
    private let driverBundleID: String = {
        let path = "/Applications/Wacom Tablet.localized/.Tablet/WacomTabletDriver.app"
        return Bundle(path: path)?.bundleIdentifier ?? "com.wacom.wacomtablet"
    }()

    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var remote: WacomIOManagerRemote?
    private var gestureActive = false
    private var endWorkItem: DispatchWorkItem?
    private let idleTimeout: TimeInterval = 0.50

    private init() {}

    func sendRotation(stepCount: Int32) {
        guard stepCount != 0 else { return }

        lock.lock()
        endWorkItem?.cancel()
        endWorkItem = nil

        guard let remote = makeRemoteLocked() else {
            lock.unlock()
            return
        }

        if !gestureActive {
            postStartLocked(remote)
            gestureActive = true
        }

        let amount = Float(stepCount) * 1.925
        postAmountLocked(remote, amount: amount)

        let workItem = DispatchWorkItem { [weak self] in
            self?.endRotation()
        }
        endWorkItem = workItem
        lock.unlock()

        DispatchQueue.main.asyncAfter(
            deadline: .now() + idleTimeout,
            execute: workItem
        )
    }

    func endRotation() {
        lock.lock()
        endWorkItem?.cancel()
        endWorkItem = nil

        guard gestureActive else {
            lock.unlock()
            return
        }

        if let remote = makeRemoteLocked() {
            postEndLocked(remote)
        }

        gestureActive = false
        lock.unlock()
    }

    private func makeRemoteLocked() -> WacomIOManagerRemote? {
        if let remote {
            return remote
        }

        let connection = NSXPCConnection(
            machServiceName: serviceName,
            options: []
        )

        let remoteInterface = NSXPCInterface(
            with: WacomIOManagerRemote.self
        )

        remoteInterface.setClasses(
            [NSDictionary.self, NSString.self, NSNumber.self],
            for: #selector(WacomIOManagerRemote.postEvent(_:)),
            argumentIndex: 0,
            ofReply: false
        )

        connection.remoteObjectInterface = remoteInterface

        connection.interruptionHandler = {
            NSLog("Wacom IOManager XPC interrupted")
        }

        connection.invalidationHandler = { [weak self] in
            self?.lock.lock()
            let remoteWasPresent = self?.remote != nil
            self?.connection = nil
            self?.remote = nil
            self?.gestureActive = false
            self?.lock.unlock()

            NSLog(
                "Wacom IOManager XPC invalidated (remote=%@)",
                remoteWasPresent ? "yes" : "no"
            )
        }

        connection.resume()

        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            NSLog(
                "Wacom IOManager XPC postEvent error domain=%@ code=%ld userInfo=%@",
                error.domain,
                error.code,
                error.userInfo
            )
        } as! WacomIOManagerRemote

        self.connection = connection
        self.remote = proxy
        return proxy
    }

    private func postStartLocked(_ remote: WacomIOManagerRemote) {
        remote.postEvent([
            "BundleID": driverBundleID,
            "EventClass": NSNumber(value: 4),
            "GestureType": NSNumber(value: UInt8(61)),
            "MainGstrType": NSNumber(value: UInt8(5))
        ] as NSDictionary)
    }

    private func postAmountLocked(
        _ remote: WacomIOManagerRemote,
        amount: Float
    ) {
        remote.postEvent([
            "BundleID": driverBundleID,
            "EventClass": NSNumber(value: 5),
            "GestureType": NSNumber(value: UInt8(5)),
            "GstrAmount": NSNumber(value: amount)
        ] as NSDictionary)
    }

    private func postEndLocked(_ remote: WacomIOManagerRemote) {
        remote.postEvent([
            "BundleID": driverBundleID,
            "EventClass": NSNumber(value: 4),
            "GestureType": NSNumber(value: UInt8(62)),
            "MainGstrType": NSNumber(value: UInt8(5))
        ] as NSDictionary)
    }
}
