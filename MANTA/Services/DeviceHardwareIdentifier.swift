import Foundation

#if canImport(UIKit)
import UIKit
#endif

#if canImport(Darwin)
import Darwin
#endif

enum DeviceHardwareIdentifier {
    static var current: String {
        #if targetEnvironment(simulator)
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"],
           !simulated.isEmpty {
            return simulated
        }
        #endif

        #if canImport(Darwin)
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 1 else {
            return fallback
        }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &bytes, &size, nil, 0) == 0 else {
            return fallback
        }
        return String(cString: bytes)
        #else
        return fallback
        #endif
    }

    private static var fallback: String {
        #if canImport(UIKit)
        UIDevice.current.model
        #else
        "unknown"
        #endif
    }
}
