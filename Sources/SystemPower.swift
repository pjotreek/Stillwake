import AppKit
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

final class PowerAssertion {
    private let type: String
    private let name: String
    private var id: IOPMAssertionID = 0

    init(type: String, name: String) {
        self.type = type
        self.name = name
    }

    func set(_ held: Bool) {
        if held, id == 0 {
            IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), name as CFString, &id)
        } else if !held, id != 0 {
            IOPMAssertionRelease(id)
            id = 0
        }
    }
}

struct BatteryStatus {
    let percent: Int
    let onBattery: Bool
    let temperature: Double?

    static func current() -> BatteryStatus? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            let onBattery = description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            return BatteryStatus(percent: current * 100 / maximum, onBattery: onBattery, temperature: batteryTemperature())
        }
        return nil
    }

    private static func batteryTemperature() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "Temperature" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        guard let raw = value as? Int, raw > 0 else { return nil }
        return Double(raw) / 100
    }
}

enum SystemActions {
    static func sleepDisplay() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        try? process.run()
    }

    static func lockScreen() {
        typealias LockFunction = @convention(c) () -> Int32
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
              let symbol = dlsym(handle, "SACLockScreenImmediate") else { return }
        _ = unsafeBitCast(symbol, to: LockFunction.self)()
    }
}
