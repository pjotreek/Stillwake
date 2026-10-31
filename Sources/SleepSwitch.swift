import Foundation
import IOKit

enum SleepSwitch {
    static let rulePath = "/etc/sudoers.d/stillwake"
    private static let queue = DispatchQueue(label: "Stillwake.sleepSwitch", qos: .userInitiated)

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: rulePath)
    }

    static var isSleepDisabled: Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (value as? Bool) ?? false
    }

    static func set(_ disabled: Bool, completion: ((Bool) -> Void)? = nil) {
        queue.async {
            let ok = setNow(disabled)
            if let completion { DispatchQueue.main.async { completion(ok) } }
        }
    }

    @discardableResult
    static func setNow(_ disabled: Bool) -> Bool {
        guard isInstalled else { return false }
        let ok = run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", disabled ? "1" : "0"]) == 0
        UserDefaults.standard.set(disabled && ok, forKey: "ownsSleepDisabled")
        return ok
    }

    static func sleepNow() {
        queue.async { _ = run("/usr/bin/pmset", ["sleepnow"]) }
    }

    static func restoreAfterCrash() {
        guard UserDefaults.standard.bool(forKey: "ownsSleepDisabled"), isSleepDisabled else { return }
        setNow(false)
    }

    static func install() -> Bool {
        let user = NSUserName()
        guard !user.isEmpty, user.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) }) else { return false }
        let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"
        let script = "set -e; t=$(/usr/bin/mktemp /private/tmp/stillwake.XXXXXX); /usr/bin/printf '%s\\n' '\(rule)' > \"$t\"; /usr/sbin/visudo -cf \"$t\" >/dev/null; /usr/sbin/chown root:wheel \"$t\"; /bin/chmod 440 \"$t\"; /bin/mv -f \"$t\" \(rulePath)"
        return runAsAdmin(script)
    }

    static func uninstall() -> Bool {
        setNow(false)
        return runAsAdmin("/bin/rm -f \(rulePath)")
    }

    private static func runAsAdmin(_ command: String) -> Bool {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges with prompt \"Stillwake needs your password once to keep the Mac awake with the lid closed.\""
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { log.error("admin step failed: \(String(describing: error), privacy: .public)") }
        return error == nil
    }

    private static func run(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
