import Foundation
import IOKit

/// Reads keys from the System Management Controller, which holds the
/// temperature and fan sensors. Reading needs no privileges; only writing
/// (fan control) would.
final class SMC {
    static let shared = SMC()

    private var connection: io_connect_t = 0

    private init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        if IOServiceOpen(service, mach_task_self_, 0, &connection) != kIOReturnSuccess {
            connection = 0
        }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    /// The key's value as a number, or nil when this Mac doesn't have it.
    func read(_ key: String) -> Double? {
        guard connection != 0 else { return nil }
        var input = KeyData()
        input.key = Self.fourCC(key)
        input.data8 = Self.getKeyInfo
        guard let info = call(&input) else { return nil }

        input.keyInfo.dataSize = info.keyInfo.dataSize
        input.data8 = Self.readBytes
        guard let output = call(&input) else { return nil }

        var raw = output.bytes
        let bytes = withUnsafeBytes(of: &raw) { Array($0.prefix(Int(info.keyInfo.dataSize))) }
        return Self.decode(bytes, type: info.keyInfo.dataType)
    }

    private func call(_ input: inout KeyData) -> KeyData? {
        var output = KeyData()
        var size = MemoryLayout<KeyData>.stride
        let status = IOConnectCallStructMethod(connection, Self.handleEvent, &input, MemoryLayout<KeyData>.stride, &output, &size)
        return status == kIOReturnSuccess && output.result == 0 ? output : nil
    }

    // MARK: - Protocol

    private static let handleEvent: UInt32 = 2
    private static let readBytes: UInt8 = 5
    private static let getKeyInfo: UInt8 = 9

    static func fourCC(_ string: String) -> UInt32 {
        string.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// Apple silicon reports floats; Intel Macs use fixed-point types.
    static func decode(_ bytes: [UInt8], type: UInt32) -> Double? {
        func bigEndian16() -> UInt16 { UInt16(bytes[0]) << 8 | UInt16(bytes[1]) }
        switch type {
        case fourCC("flt ") where bytes.count >= 4:
            return Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) })
        case fourCC("sp78") where bytes.count >= 2:
            return Double(Int16(bitPattern: bigEndian16())) / 256
        case fourCC("fpe2") where bytes.count >= 2:
            return Double(bigEndian16()) / 4
        case fourCC("ui8 ") where bytes.count >= 1:
            return Double(bytes[0])
        case fourCC("ui16") where bytes.count >= 2:
            return Double(bigEndian16())
        default:
            return nil
        }
    }

    /// Mirrors the kernel's SMCKeyData_t (80 bytes). The explicit padding
    /// stands in for the C struct's alignment after keyInfo.
    struct KeyData {
        typealias Bytes = (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        )

        struct Version {
            var major: UInt8 = 0
            var minor: UInt8 = 0
            var build: UInt8 = 0
            var reserved: UInt8 = 0
            var release: UInt16 = 0
        }

        struct LimitData {
            var version: UInt16 = 0
            var length: UInt16 = 0
            var cpuPLimit: UInt32 = 0
            var gpuPLimit: UInt32 = 0
            var memPLimit: UInt32 = 0
        }

        struct KeyInfo {
            var dataSize: UInt32 = 0
            var dataType: UInt32 = 0
            var dataAttributes: UInt8 = 0
        }

        var key: UInt32 = 0
        var version = Version()
        var limitData = LimitData()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: Bytes = (
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        )
    }
}
