import AppKit

final class LidGesture: NSObject {
    enum Phase {
        case idle, watching, closing, committed
    }

    static let beginDrop = 4.0
    static let commitAngle = 40.0

    var onBegin: (() -> Void)?
    var onCancel: (() -> Void)?
    var onClosed: (() -> Void)?

    private(set) var phase: Phase = .idle
    private let sensor = LidAngleSensor()
    private let overlay = LidOverlay()
    private var timer: Timer?
    private var displayLink: CADisplayLink?
    private var usesSensor = false
    private var baseline = 0.0
    private var beginAngle = 0.0
    private var rawAngle = 0.0
    private var visual = CriticallyDampedSpring(value: 0)
    private var lastFrame = CACurrentMediaTime()
    private var motionAngle = 0.0
    private var lastMotion = Date()
    private var watchStarted = Date()
    private var releaseGrace: DispatchWorkItem?

    var hasSensor: Bool { sensor.isAvailable }
    var isArming: Bool { phase == .closing || phase == .committed }

    func fnChanged(_ down: Bool, lidClosed: Bool) {
        if down {
            releaseGrace?.cancel()
            guard phase == .idle, !lidClosed else { return }
            if sensor.open(), let angle = sensor.read() {
                log.debug("watching lid from \(angle, privacy: .public)°")
                usesSensor = true
                overlay.warmUp()
                baseline = angle
                rawAngle = angle
                motionAngle = angle
                watchStarted = Date()
                phase = .watching
                startTimer()
            } else {
                log.notice("no lid sensor, arming while fn is held")
                usesSensor = false
                phase = .closing
                onBegin?()
            }
            return
        }

        switch phase {
        case .watching:
            finish(animated: false)
        case .closing where usesSensor:
            log.notice("fn released at \(self.rawAngle, privacy: .public)° before commit")
            cancel()
        case .closing:
            let work = DispatchWorkItem { [weak self] in self?.cancel() }
            releaseGrace = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        default:
            break
        }
    }

    func lidDidClose() -> Bool {
        let armed = isArming
        finish(animated: false)
        return armed
    }

    func reset() {
        finish(animated: false)
    }

    private func begin(at angle: Double) {
        log.notice("gesture began at \(angle, privacy: .public)° from \(self.baseline, privacy: .public)°")
        phase = .closing
        beginAngle = baseline
        motionAngle = angle
        lastMotion = Date()
        visual.reset(to: angle)
        onBegin?()
        overlay.show(startAngle: beginAngle, commitAngle: Self.commitAngle)
        startDisplayLink()
    }

    private func commit() {
        log.notice("gesture committed")
        phase = .committed
        overlay.setCommitted()
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }

    private func cancel() {
        log.notice("gesture cancel requested in phase \(String(describing: self.phase), privacy: .public)")
        if isArming, RootDomain.shared.isLidClosed {
            onClosed?()
            return
        }
        let wasArming = isArming
        finish(animated: true)
        if wasArming { onCancel?() }
    }

    private func finish(animated: Bool) {
        releaseGrace?.cancel()
        releaseGrace = nil
        stopTimer()
        displayLink?.invalidate()
        displayLink = nil
        sensor.close()
        overlay.dismiss(animated: animated)
        phase = .idle
    }

    private func startTimer() {
        let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func startDisplayLink() {
        guard displayLink == nil, let screen = NSScreen.builtIn else { return }
        lastFrame = CACurrentMediaTime()
        let link = screen.displayLink(target: self, selector: #selector(frame))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func frame() {
        let now = CACurrentMediaTime()
        let dt = min(max(now - lastFrame, 1.0 / 240), 1.0 / 20)
        lastFrame = now
        visual.advance(to: rawAngle, dt: dt)
        overlay.update(angle: visual.value)
    }

    private func tick() {
        guard let angle = sensor.read() else {
            log.error("lid sensor read failed")
            cancel()
            return
        }
        let now = Date()
        rawAngle = angle
        if abs(angle - motionAngle) >= 1 {
            motionAngle = angle
            lastMotion = now
        }

        switch phase {
        case .watching:
            baseline = max(baseline, angle)
            if baseline - angle >= Self.beginDrop {
                begin(at: angle)
            } else if now.timeIntervalSince(watchStarted) > 30 {
                finish(animated: false)
            }
        case .closing:
            if angle > beginAngle + 2 || now.timeIntervalSince(lastMotion) > 8 {
                log.notice("closing abandoned at \(angle, privacy: .public)°, idle \(now.timeIntervalSince(self.lastMotion), privacy: .public)s")
                cancel()
                return
            }
            if angle <= Self.commitAngle { commit() }
        case .committed:
            if angle > Self.commitAngle + 30 || now.timeIntervalSince(lastMotion) > 20 {
                cancel()
                return
            }
        case .idle:
            finish(animated: false)
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    static var builtIn: NSScreen? {
        screens.first { $0.displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false }
    }
}
