import AppKit
import IOKit.ps

/// Immediate system notifications: mounts, sleep and wake, and power source changes. Callbacks only forward to
/// `Handlers`, so the recorder actor owns ordering and persistence. Installed once at launch and removed on
/// termination; between notifications it does no work.
@MainActor
final class ActivitySystemObservers {
    struct Handlers: Sendable {
        var volumeMounted: @Sendable (_ path: String, _ name: String) -> Void
        var volumeUnmounted: @Sendable (_ path: String) -> Void
        var sleep: @Sendable () -> Void
        var wake: @Sendable () -> Void
        var powerSource: @Sendable (_ charging: Bool, _ chargePercent: Double?) -> Void
    }

    struct PowerState: Equatable {
        var onExternalPower: Bool
        var chargePercent: Double?
    }

    private let handlers: Handlers
    private let notificationCenter: NotificationCenter
    private let readPowerState: () -> PowerState?
    private var tokens: [NSObjectProtocol] = []
    private var powerSource: CFRunLoopSource?
    private var lastExternalPower: Bool?

    init(
        handlers: Handlers,
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        readPowerState: @escaping () -> PowerState? = ActivitySystemObservers.currentPowerState
    ) {
        self.handlers = handlers
        self.notificationCenter = notificationCenter
        self.readPowerState = readPowerState
    }

    func install() {
        guard tokens.isEmpty else { return }
        let handlers = handlers
        tokens = [
            notificationCenter.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { notification in
                guard let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
                let name = notification.userInfo?[NSWorkspace.localizedVolumeNameUserInfoKey] as? String ?? url.lastPathComponent
                handlers.volumeMounted(url.path, name)
            },
            notificationCenter.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { notification in
                guard let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
                handlers.volumeUnmounted(url.path)
            },
            notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in handlers.sleep() },
            notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in handlers.wake() },
        ]
        // `NSProcessInfoPowerStateDidChange` reports Low Power Mode, not the power source, so IOKit is used.
        lastExternalPower = readPowerState()?.onExternalPower
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let observers = Unmanaged<ActivitySystemObservers>.fromOpaque(context).takeUnretainedValue()
            // The source is attached to the main run loop, so this already runs on the main thread.
            MainActor.assumeIsolated { observers.powerSourceChanged() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
    }

    func remove() {
        tokens.forEach(notificationCenter.removeObserver)
        tokens = []
        if let powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .defaultMode)
            self.powerSource = nil
        }
    }

    /// The IOKit source also fires for charge percentage updates, so only a change of source is reported.
    func powerSourceChanged() {
        guard let state = readPowerState() else { return }
        defer { lastExternalPower = state.onExternalPower }
        guard let previous = lastExternalPower, previous != state.onExternalPower else { return }
        handlers.powerSource(state.onExternalPower, state.chargePercent)
    }

    nonisolated static func currentPowerState() -> PowerState? {
        guard let infoHandle = IOPSCopyPowerSourcesInfo() else { return nil }
        let info = infoHandle.takeRetainedValue()
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        var percent: Double?
        if let sourcesHandle = IOPSCopyPowerSourcesList(info) {
            for source in sourcesHandle.takeRetainedValue() as NSArray {
                guard let description = IOPSGetPowerSourceDescription(info, source as CFTypeRef)?.takeUnretainedValue() as? [String: Any],
                      description[kIOPSTypeKey as String] as? String == "InternalBattery",
                      let current = (description[kIOPSCurrentCapacityKey as String] as? NSNumber)?.doubleValue,
                      let maximum = (description[kIOPSMaxCapacityKey as String] as? NSNumber)?.doubleValue, maximum > 0 else { continue }
                percent = min(100, max(0, current * 100 / maximum))
                break
            }
        }
        return PowerState(onExternalPower: providing == kIOPSACPowerValue, chargePercent: percent)
    }
}
