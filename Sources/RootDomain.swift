import Foundation
import IOKit

final class RootDomain {
    static let shared = RootDomain()

    var onClamshellChange: ((Bool) -> Void)?

    private let service: io_service_t
    private var connection: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    private init() {
        service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        IOServiceOpen(service, mach_task_self_, 0, &connection)
    }

    var hasLid: Bool {
        IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0) != nil
    }

    var isLidClosed: Bool {
        let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (value as? Bool) ?? false
    }

    @discardableResult
    func setClamshellSleepDisabled(_ disabled: Bool) -> Bool {
        var value: UInt64 = disabled ? 1 : 0
        return IOConnectCallScalarMethod(connection, 12, &value, 1, nil, nil) == KERN_SUCCESS
    }

    func observeClamshell() {
        guard notifyPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddInterestNotification(port, service, kIOGeneralInterest, { context, _, messageType, argument in
            guard messageType == 0xE003_4100, let context else { return }
            let domain = Unmanaged<RootDomain>.fromOpaque(context).takeUnretainedValue()
            domain.onClamshellChange?(UInt(bitPattern: argument) & 1 != 0)
        }, context, &notifier)
    }
}

enum LidGuard {
    private static var pipeWrite: Int32 = -1

    static func launch() {
        guard let path = Bundle.main.executablePath else { return }
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, fds[0], 0)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), strdup("guard"), nil]
        var pid: pid_t = 0
        let result = posix_spawn(&pid, path, &actions, &attributes, argv, environ)
        argv.forEach { free($0) }
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attributes)
        close(fds[0])

        if result == 0 {
            pipeWrite = fds[1]
            _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        } else {
            close(fds[1])
        }
    }

    static func report(_ disabled: Bool) {
        guard pipeWrite >= 0 else { return }
        var byte: UInt8 = disabled ? 1 : 0
        _ = write(pipeWrite, &byte, 1)
    }

    static func runChild() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        var last: UInt8 = 0
        var byte: UInt8 = 0
        while read(0, &byte, 1) == 1 {
            last = byte
        }
        if last == 1 {
            RootDomain.shared.setClamshellSleepDisabled(false)
            if SleepSwitch.isSleepDisabled { SleepSwitch.setNow(false) }
        }
    }
}
