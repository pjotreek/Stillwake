import AppKit
import IOKit.ps
import IOKit.pwr_mgt
import notify

final class Keeper {
    enum Session: Equatable {
        case off
        case indefinite
        case until(Date)
    }

    enum LidHold {
        case none, pending, armed
    }

    var onChange: (() -> Void)?

    private(set) var session: Session = .off
    private(set) var lidHold: LidHold = .none
    private(set) var agentsWorking = 0
    private(set) var agentsHolding = false
    private(set) var lidClosed = false
    private(set) var stopNotice: String?
    private(set) var holdFailed = false

    let fnMonitor = FnMonitor()
    let gesture = LidGesture()
    private let agents = AgentMonitor()
    private let systemSleep = PowerAssertion(type: kIOPMAssertionTypePreventUserIdleSystemSleep, name: "Stillwake is keeping this Mac awake")
    private let displaySleep = PowerAssertion(type: kIOPMAssertionTypePreventUserIdleDisplaySleep, name: "Stillwake is keeping the screen on")
    private var lidSleepDisabled = false
    private var safeguardHold = false
    private var sessionTimer: DispatchSourceTimer?
    private var heatTimer: DispatchSourceTimer?
    private var agentGrace: DispatchWorkItem?
    private var powerSource: CFRunLoopSource?
    private var assertionToken: Int32 = -1
    private var observers: [NSObjectProtocol] = []
    private var accessRetry: Timer?

    var isActive: Bool { session != .off || lidHold != .none || agentsHolding }

    func start() {
        let root = RootDomain.shared
        lidClosed = root.isLidClosed
        root.onClamshellChange = { [weak self] closed in self?.lidChanged(closed) }
        root.observeClamshell()

        fnMonitor.onChange = { [weak self] down in self?.fnChanged(down) }
        gesture.onBegin = { [weak self] in self?.gestureBegan() }
        gesture.onCancel = { [weak self] in self?.gestureCancelled() }
        gesture.onClosed = { [weak self] in self?.lidChanged(true) }
        if !refreshFnMonitor() { waitForFnAccess() }

        agents.onChange = { [weak self] count in self?.agentsChanged(count) }
        if Settings.agentsEnabled { agents.start() }

        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<Keeper>.fromOpaque(context).takeUnretainedValue().powerSourceChanged()
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemDidWake()
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemWillSleep()
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensDidWake()
        })
        observers.append(NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.checkSafeguards()
        })

        apply()
    }

    func shutdown() {
        gesture.reset()
        if lidSleepDisabled {
            RootDomain.shared.setClamshellSleepDisabled(false)
            LidGuard.report(false)
            lidSleepDisabled = false
        }
        systemSleep.set(false)
        displaySleep.set(false)
    }

    func startSession(_ duration: TimeInterval?) {
        session = duration.map { .until(Date().addingTimeInterval($0)) } ?? .indefinite
        stopNotice = nil
        safeguardHold = false
        scheduleSessionEnd()
        apply()
        checkSafeguards()
    }

    func stopSession() {
        session = .off
        sessionTimer?.cancel()
        sessionTimer = nil
        apply()
    }

    func setAgentsEnabled(_ enabled: Bool) {
        Settings.agentsEnabled = enabled
        if enabled {
            agents.start()
        } else {
            agents.stop()
            agentGrace?.cancel()
            agentsHolding = false
            apply()
        }
    }

    func setGestureEnabled(_ enabled: Bool) {
        Settings.gestureEnabled = enabled
        refreshFnMonitor()
    }

    func setKeepDisplayOn(_ enabled: Bool) {
        Settings.keepDisplayOn = enabled
        apply()
    }

    @discardableResult
    func refreshFnMonitor() -> Bool {
        if Settings.gestureEnabled && RootDomain.shared.hasLid {
            return fnMonitor.start()
        }
        gesture.reset()
        fnMonitor.stop()
        return false
    }

    func waitForFnAccess() {
        accessRetry?.invalidate()
        var attempts = 0
        let retry = Timer(timeInterval: 3, repeats: true) { [weak self] timer in
            attempts += 1
            guard let self, Settings.gestureEnabled, !self.refreshFnMonitor(), attempts < 200 else {
                timer.invalidate()
                return
            }
        }
        retry.tolerance = 1
        RunLoop.main.add(retry, forMode: .common)
        accessRetry = retry
    }

    var sessionEnd: Date? {
        if case .until(let date) = session { return date }
        return nil
    }

    private func fnChanged(_ down: Bool) {
        guard Settings.gestureEnabled else { return }
        gesture.fnChanged(down, lidClosed: lidClosed)
    }

    private func gestureBegan() {
        guard lidHold == .none else { return }
        lidHold = .pending
        stopNotice = nil
        apply()
    }

    private func gestureCancelled() {
        guard lidHold == .pending else { return }
        lidHold = .none
        apply()
    }

    private func lidChanged(_ closed: Bool) {
        guard closed != lidClosed else {
            reassert()
            return
        }
        lidClosed = closed
        log.notice("lid \(closed ? "closed" : "opened", privacy: .public), active \(self.isActive, privacy: .public), hold \(String(describing: self.lidHold), privacy: .public)")
        if closed {
            if gesture.lidDidClose() || lidHold == .pending {
                lidHold = .armed
            }
            apply()
            guard isActive else { return }
            if Settings.lockOnClose { SystemActions.lockScreen() }
            SystemActions.sleepDisplay()
            startHeatWatch()
            checkSafeguards()
        } else {
            gesture.reset()
            lidHold = .none
            stopHeatWatch()
            apply()
        }
    }

    private func agentsChanged(_ count: Int) {
        agentsWorking = count
        agentGrace?.cancel()
        agentGrace = nil
        if count > 0 {
            if !safeguardHold && Settings.agentsEnabled { agentsHolding = true }
            apply()
            checkSafeguards()
        } else if agentsHolding {
            let work = DispatchWorkItem { [weak self] in
                self?.agentsHolding = false
                self?.apply()
            }
            agentGrace = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
            onChange?()
        } else {
            onChange?()
        }
    }

    private func apply() {
        let active = isActive
        if active != lidSleepDisabled {
            let applied = RootDomain.shared.setClamshellSleepDisabled(active)
            log.notice("lid sleep \(active ? "disabled" : "enabled", privacy: .public), call ok \(applied, privacy: .public)")
            LidGuard.report(active)
            lidSleepDisabled = active
            let closed = lidClosed
            SleepSwitch.set(active) { ok in
                log.notice("disablesleep \(active ? 1 : 0, privacy: .public) via sudo ok \(ok, privacy: .public)")
                if !active, closed, RootDomain.shared.isLidClosed { SleepSwitch.sleepNow() }
            }
        }
        systemSleep.set(active)
        displaySleep.set(session != .off && Settings.keepDisplayOn && !lidClosed)
        watchAssertionChanges(active)
        onChange?()
    }

    private func reassert() {
        guard lidSleepDisabled else { return }
        RootDomain.shared.setClamshellSleepDisabled(true)
    }

    private func watchAssertionChanges(_ watching: Bool) {
        if watching, assertionToken == -1 {
            notify_register_dispatch("com.apple.system.powermanagement.assertions", &assertionToken, .main) { [weak self] _ in
                self?.reassert()
            }
        } else if !watching, assertionToken != -1 {
            notify_cancel(assertionToken)
            assertionToken = -1
        }
    }

    private func scheduleSessionEnd() {
        sessionTimer?.cancel()
        sessionTimer = nil
        guard let end = sessionEnd else { return }
        guard end.timeIntervalSinceNow > 0 else {
            stopSession()
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(wallDeadline: .now() + end.timeIntervalSinceNow, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.scheduleSessionEnd() }
        timer.resume()
        sessionTimer = timer
    }

    private func powerSourceChanged() {
        reassert()
        checkSafeguards()
    }

    private func systemWillSleep() {
        guard isActive, RootDomain.shared.isLidClosed else { return }
        holdFailed = true
        log.error("mac is sleeping with the lid closed while Stillwake should hold it, reliable mode \(SleepSwitch.isInstalled, privacy: .public)")
        onChange?()
    }

    func reapplySleepSwitch() {
        guard lidSleepDisabled else { return }
        SleepSwitch.set(true)
    }

    func clearHoldFailure() {
        holdFailed = false
    }

    private func systemDidWake() {
        let closed = RootDomain.shared.isLidClosed
        if closed != lidClosed {
            lidChanged(closed)
        } else {
            reassert()
        }
        scheduleSessionEnd()
        checkSafeguards()
    }

    private func screensDidWake() {
        guard lidClosed, isActive else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.isActive, RootDomain.shared.isLidClosed else { return }
            SystemActions.sleepDisplay()
        }
    }

    private func startHeatWatch() {
        guard heatTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(wallDeadline: .now() + 120, repeating: 120, leeway: .seconds(30))
        timer.setEventHandler { [weak self] in self?.checkSafeguards() }
        timer.resume()
        heatTimer = timer
    }

    private func stopHeatWatch() {
        heatTimer?.cancel()
        heatTimer = nil
    }

    private func checkSafeguards() {
        let battery = BatteryStatus.current()
        let floor = Settings.batteryFloor
        let lowBattery = battery.map { $0.onBattery && floor > 0 && $0.percent <= floor } ?? false
        let thermal = ProcessInfo.processInfo.thermalState
        let hot = Settings.thermalGuard && lidClosed && (thermal == .serious || thermal == .critical || (battery?.temperature ?? 0) >= 47)

        if safeguardHold, !hot, battery.map({ !$0.onBattery || floor == 0 || $0.percent > floor + 3 }) ?? true {
            safeguardHold = false
            if agentsWorking > 0 && Settings.agentsEnabled {
                agentsHolding = true
                apply()
            }
        }

        guard isActive else { return }
        if lowBattery, let battery {
            trip("Stopped at \(battery.percent)% battery")
        } else if hot {
            trip("Stopped because the Mac got too hot")
        }
    }

    private func trip(_ notice: String) {
        log.notice("safeguard tripped: \(notice, privacy: .public)")
        safeguardHold = true
        stopNotice = notice
        session = .off
        sessionTimer?.cancel()
        sessionTimer = nil
        lidHold = .none
        gesture.reset()
        agentGrace?.cancel()
        agentsHolding = false
        apply()
    }
}
