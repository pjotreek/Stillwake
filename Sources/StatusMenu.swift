import AppKit
import ServiceManagement

final class StatusMenu: NSObject, NSMenuDelegate {
    private let keeper: Keeper
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var header: NSMenuItem?
    private var ticker: Timer?

    private static let durations: [(String, TimeInterval)] = [
        ("15 Minutes", 900), ("30 Minutes", 1800), ("1 Hour", 3600), ("2 Hours", 7200), ("4 Hours", 14400), ("8 Hours", 28800),
    ]
    private static let batteryFloors = [0, 5, 10, 20, 30]

    init(keeper: Keeper) {
        self.keeper = keeper
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        keeper.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    private func refresh() {
        let symbol = keeper.isActive ? "sun.max.fill" : "moon.fill"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Stillwake")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "Stillwake · \(statusLine())"
        header?.title = statusLine()
    }

    private func statusLine() -> String {
        var parts: [String] = []
        switch keeper.session {
        case .off:
            break
        case .indefinite:
            parts.append("On indefinitely")
        case .until(let end):
            parts.append("On · \(Self.remaining(until: end)) left")
        }
        if keeper.agentsHolding {
            switch keeper.agentsWorking {
            case 0: parts.append("Agents finishing")
            case 1: parts.append("1 agent working")
            default: parts.append("\(keeper.agentsWorking) agents working")
            }
        }
        if keeper.lidHold != .none {
            parts.append("Lid close armed")
        }
        if parts.isEmpty {
            return keeper.stopNotice ?? "Off · Mac sleeps normally"
        }
        return parts.joined(separator: " · ")
    }

    private static func remaining(until end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSinceNow.rounded(.up)))
        let hours = seconds / 3600
        let minutes = seconds % 3600 / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds % 60)s" }
        return "\(seconds)s"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        self.header = header
        if !SleepSwitch.isInstalled {
            menu.addItem(action(keeper.holdFailed ? "Mac Slept With Lid Closed · Set Up Lid Mode…" : "Set Up Lid-Closed Mode…", #selector(setUpLidMode)))
        }
        menu.addItem(.separator())

        if keeper.session == .off {
            menu.addItem(action("Turn On Indefinitely", #selector(startIndefinitely)))
        } else {
            menu.addItem(action("Turn Off", #selector(stopSession)))
        }
        let durations = NSMenu()
        for (index, entry) in Self.durations.enumerated() {
            let duration = action(entry.0, #selector(startTimed(_:)))
            duration.tag = index
            durations.addItem(duration)
        }
        menu.addItem(submenu("Turn On For", durations))
        menu.addItem(.separator())

        menu.addItem(toggle("Stay On While AI Agents Work", Settings.agentsEnabled, #selector(toggleAgents)))
        let connections = NSMenu()
        for integration in AgentIntegration.allCases where integration.isAvailable {
            let entry = toggle(integration.title, integration.isConnected, #selector(toggleIntegration(_:)))
            entry.representedObject = integration.rawValue
            connections.addItem(entry)
        }
        if connections.items.isEmpty {
            let none = NSMenuItem(title: "No Supported Agents Found", action: nil, keyEquivalent: "")
            none.isEnabled = false
            connections.addItem(none)
        }
        menu.addItem(submenu("Connected Agents", connections))
        menu.addItem(.separator())

        if RootDomain.shared.hasLid {
            menu.addItem(toggle("Hold fn While Closing the Lid", Settings.gestureEnabled, #selector(toggleGesture)))
        }
        menu.addItem(toggle("Lock When the Lid Closes", Settings.lockOnClose, #selector(toggleLock)))
        menu.addItem(toggle("Keep Screen On During Sessions", Settings.keepDisplayOn, #selector(toggleDisplay)))
        let floors = NSMenu()
        for floor in Self.batteryFloors {
            let entry = toggle(floor == 0 ? "Never" : "\(floor)%", Settings.batteryFloor == floor, #selector(setBatteryFloor(_:)))
            entry.tag = floor
            floors.addItem(entry)
        }
        menu.addItem(submenu("Stop on Battery Below", floors))
        menu.addItem(toggle("Stop If the Mac Gets Too Hot", Settings.thermalGuard, #selector(toggleThermal)))

        var permissions: [NSMenuItem] = []
        if Settings.gestureEnabled, RootDomain.shared.hasLid, !keeper.refreshFnMonitor() || !FnMonitor.hasAccess {
            permissions.append(action("Allow fn Detection…", #selector(requestInputMonitoring)))
        }
        if Settings.gestureEnabled, keeper.gesture.hasSensor, !ScreenSnapshot.canCaptureScreen {
            permissions.append(action("Show Live Screen in Lid Animation…", #selector(requestScreenCapture)))
        }
        if !permissions.isEmpty {
            menu.addItem(.separator())
            permissions.forEach(menu.addItem)
        }

        menu.addItem(.separator())
        if SleepSwitch.isInstalled {
            menu.addItem(toggle("Lid-Closed Mode (Admin Rule)", true, #selector(removeLidMode)))
        }
        menu.addItem(toggle("Launch at Login", SMAppService.mainApp.status == .enabled, #selector(toggleLaunchAtLogin)))
        let quit = action("Quit Stillwake", #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    func menuWillOpen(_ menu: NSMenu) {
        let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    func menuDidClose(_ menu: NSMenu) {
        ticker?.invalidate()
        ticker = nil
        header = nil
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        entry.target = self
        return entry
    }

    private func toggle(_ title: String, _ on: Bool, _ selector: Selector) -> NSMenuItem {
        let entry = action(title, selector)
        entry.state = on ? .on : .off
        return entry
    }

    private func submenu(_ title: String, _ submenu: NSMenu) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.submenu = submenu
        return entry
    }

    @objc private func startIndefinitely() {
        keeper.startSession(nil)
    }

    @objc private func startTimed(_ sender: NSMenuItem) {
        keeper.startSession(Self.durations[sender.tag].1)
    }

    @objc private func stopSession() {
        keeper.stopSession()
    }

    @objc private func toggleAgents() {
        keeper.setAgentsEnabled(!Settings.agentsEnabled)
    }

    @objc private func toggleIntegration(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let integration = AgentIntegration(rawValue: raw) else { return }
        do {
            try integration.isConnected ? integration.disconnect() : integration.connect()
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Couldn’t update \(integration.title)"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func toggleGesture() {
        keeper.setGestureEnabled(!Settings.gestureEnabled)
    }

    @objc private func toggleLock() {
        Settings.lockOnClose.toggle()
    }

    @objc private func toggleDisplay() {
        keeper.setKeepDisplayOn(!Settings.keepDisplayOn)
    }

    @objc private func setBatteryFloor(_ sender: NSMenuItem) {
        Settings.batteryFloor = sender.tag
    }

    @objc private func toggleThermal() {
        Settings.thermalGuard.toggle()
    }

    @objc private func requestInputMonitoring() {
        FnMonitor.requestAccess()
        if !FnMonitor.hasAccess {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
        }
        keeper.waitForFnAccess()
    }

    @objc private func requestScreenCapture() {
        if !ScreenSnapshot.canCaptureScreen {
            ScreenSnapshot.requestAccess()
        }
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Couldn’t change Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func setUpLidMode() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Set up lid-closed mode"
        alert.informativeText = "Stillwake will add one rule to /etc/sudoers.d that lets it run exactly “pmset -a disablesleep 1” and “pmset -a disablesleep 0” without a password. Nothing else gets admin rights. Stillwake turns sleep back on whenever it stops holding the Mac, including after a crash.\n\nmacOS asks for your password once."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if SleepSwitch.install() {
            keeper.clearHoldFailure()
            keeper.reapplySleepSwitch()
        }
    }

    @objc private func removeLidMode() {
        _ = SleepSwitch.uninstall()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
