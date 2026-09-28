import Darwin
import IOKit

/// Reads a fixed-size sysctl value by name, e.g. `vm.swapusage`.
func sysctlValue<T>(_ name: String, initial: T) -> T? {
    var value = initial
    var size = MemoryLayout<T>.size
    let status = withUnsafeMutableBytes(of: &value) { sysctlbyname(name, $0.baseAddress, &size, nil, 0) }
    return status == 0 ? value : nil
}

func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(cString: buffer)
}

let machHost = mach_host_self()

/// Calls `body` for every IOKit service of the given class.
func forEachService(_ className: String, _ body: (io_object_t) -> Void) {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else {
        return
    }
    defer { IOObjectRelease(iterator) }
    var service = IOIteratorNext(iterator)
    while service != 0 {
        body(service)
        IOObjectRelease(service)
        service = IOIteratorNext(iterator)
    }
}

func registryProperty(_ entry: io_registry_entry_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}
