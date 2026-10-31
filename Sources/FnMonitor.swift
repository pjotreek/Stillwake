import CoreGraphics
import Foundation

final class FnMonitor {
    var onChange: ((Bool) -> Void)?
    private(set) var isDown = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool { tap != nil }

    static var hasAccess: Bool { CGPreflightListenEventAccess() }

    static func requestAccess() {
        CGRequestListenEventAccess()
    }

    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let mask = CGEventMask(1) << CGEventType.flagsChanged.rawValue
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, context in
            if let context {
                Unmanaged<FnMonitor>.fromOpaque(context).takeUnretainedValue().handle(type, event)
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: context) else {
            log.error("fn tap unavailable, input monitoring access \(Self.hasAccess, privacy: .public)")
            return false
        }
        log.notice("fn tap running")
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFMachPortInvalidate(tap)
        self.tap = nil
        source = nil
        if isDown {
            isDown = false
            onChange?(false)
        }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        let down = event.flags.contains(.maskSecondaryFn)
        guard down != isDown else { return }
        isDown = down
        log.notice("fn \(down ? "down" : "up", privacy: .public) flags \(String(event.flags.rawValue, radix: 16), privacy: .public)")
        onChange?(down)
    }
}
