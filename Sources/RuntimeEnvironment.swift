import Darwin
import Foundation

enum RuntimeEnvironment {
    static var shouldDisableExportPreview: Bool {
        if ProcessInfo.processInfo.environment["VIDEODATASETBROWSER_DISABLE_EXPORT_PREVIEW"] == "1" {
            return true
        }

        if let model = sysctlString("hw.model"),
           model.localizedCaseInsensitiveContains("virtual") {
            return true
        }

        if let machine = sysctlString("hw.machine"),
           machine.localizedCaseInsensitiveContains("virtual") {
            return true
        }

        var isVirtualMachine: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.hv_vmm_present", &isVirtualMachine, &size, nil, 0) == 0,
           isVirtualMachine == 1 {
            return true
        }

        return false
    }

    private static func sysctlString(_ key: String) -> String? {
        var size: size_t = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0,
              size > 1 else {
            return nil
        }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else {
            return nil
        }

        return String(cString: buffer)
    }
}
