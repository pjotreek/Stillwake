import Foundation

enum Settings {
    private static let defaults = UserDefaults.standard

    static func register() {
        defaults.register(defaults: [
            "gestureEnabled": true,
            "agentsEnabled": true,
            "lockOnClose": true,
            "keepDisplayOn": false,
            "batteryFloor": 10,
            "thermalGuard": true,
        ])
    }

    static var gestureEnabled: Bool {
        get { defaults.bool(forKey: "gestureEnabled") }
        set { defaults.set(newValue, forKey: "gestureEnabled") }
    }

    static var agentsEnabled: Bool {
        get { defaults.bool(forKey: "agentsEnabled") }
        set { defaults.set(newValue, forKey: "agentsEnabled") }
    }

    static var lockOnClose: Bool {
        get { defaults.bool(forKey: "lockOnClose") }
        set { defaults.set(newValue, forKey: "lockOnClose") }
    }

    static var keepDisplayOn: Bool {
        get { defaults.bool(forKey: "keepDisplayOn") }
        set { defaults.set(newValue, forKey: "keepDisplayOn") }
    }

    static var batteryFloor: Int {
        get { defaults.integer(forKey: "batteryFloor") }
        set { defaults.set(newValue, forKey: "batteryFloor") }
    }

    static var thermalGuard: Bool {
        get { defaults.bool(forKey: "thermalGuard") }
        set { defaults.set(newValue, forKey: "thermalGuard") }
    }
}
