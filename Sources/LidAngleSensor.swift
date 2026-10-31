import Foundation
import IOKit.hid

final class LidAngleSensor {
    private enum Resolution: Int {
        case hundredths = 7
        case wholeDegrees = 1
    }

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var device: IOHIDDevice?
    private var resolution: Resolution?
    private var buffer = [UInt8](repeating: 0, count: 32)
    private(set) var isAvailable = false

    init() {
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: 0x05AC,
            kIOHIDDeviceUsagePageKey: 0x20,
            kIOHIDDeviceUsageKey: 0x8A,
        ] as CFDictionary)
        isAvailable = open()
        close()
    }

    func open() -> Bool {
        if device != nil { return true }
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return false }
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        for candidate in devices where (IOHIDDeviceGetProperty(candidate, kIOHIDBuiltInKey as CFString) as? NSNumber)?.boolValue == true {
            device = candidate
            for format in [resolution].compactMap({ $0 }) + [.hundredths, .wholeDegrees] {
                resolution = format
                if read() != nil { return true }
            }
        }
        device = nil
        resolution = nil
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        return false
    }

    func close() {
        guard device != nil else { return }
        device = nil
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func read() -> Double? {
        guard let device, let resolution else { return nil }
        var length = CFIndex(buffer.count)
        let status = buffer.withUnsafeMutableBufferPointer { pointer -> IOReturn in
            guard let base = pointer.baseAddress else { return kIOReturnBadArgument }
            return IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(resolution.rawValue), base, &length)
        }
        guard status == kIOReturnSuccess, length > 0, buffer[0] == UInt8(resolution.rawValue) else { return nil }

        let degrees: Double
        switch resolution {
        case .hundredths:
            guard length >= 5 else { return nil }
            let raw = UInt32(buffer[1]) | UInt32(buffer[2]) << 8 | UInt32(buffer[3]) << 16 | UInt32(buffer[4]) << 24
            degrees = Double(raw) / 100
        case .wholeDegrees:
            guard length >= 3 else { return nil }
            degrees = Double(UInt16(buffer[1]) | UInt16(buffer[2]) << 8)
        }
        return (0...360).contains(degrees) ? degrees : nil
    }
}
