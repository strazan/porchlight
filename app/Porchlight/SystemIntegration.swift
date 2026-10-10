import AppKit
import IOKit.pwr_mgt
import Network
import ServiceManagement

/// Keeps the Mac from idle-sleeping while held. A closed lid still sleeps it (unless it's
/// connected to power and a display).
@MainActor
final class PowerAssertion {
    private var id: IOPMAssertionID?

    var isHeld: Bool { id != nil }

    func hold(_ hold: Bool) {
        if hold, id == nil {
            var newID = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Porchlight is serving MCP servers" as CFString,
                &newID
            )
            if result == kIOReturnSuccess { id = newID }
        } else if !hold, let id {
            IOPMAssertionRelease(id)
            self.id = nil
        }
    }
}

/// Launch at login, through the system's Login Items.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// The user turned it on but has to allow it in System Settings → Login Items.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

/// Calls `onChange` when the Mac wakes or the network comes back: moments when the relay
/// connection is probably dead and worth re-establishing right away.
@MainActor
final class ConnectivityWatcher {
    private let monitor = NWPathMonitor()
    // Set once in init and only read again in deinit.
    nonisolated(unsafe) private var wakeObserver: NSObjectProtocol?
    /// The last path seen, as (online, interface names); nil until the first update.
    private var lastPath: (satisfied: Bool, interfaces: [String])?

    init(onChange: @escaping @MainActor () -> Void) {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { onChange() }
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let current = (satisfied: path.status == .satisfied, interfaces: path.availableInterfaces.map(\.name))
            Task { @MainActor in
                guard let self else { return }
                defer { self.lastPath = current }
                // The first update only reports the starting state.
                guard let last = self.lastPath, current.satisfied else { return }
                // Back online, or moved to a different network (Wi-Fi ↔ Ethernet, VPN up or down).
                if !last.satisfied || last.interfaces != current.interfaces { onChange() }
            }
        }
        monitor.start(queue: .main)
    }

    deinit {
        monitor.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }
}
