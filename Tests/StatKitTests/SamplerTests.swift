import Darwin
import XCTest
@testable import StatKit

/// Smoke tests against the live machine: they check the readings are sane,
/// not specific values.
final class SamplerTests: XCTestCase {
    func testCPU() {
        var sampler = CPUSampler()
        XCTAssertNil(sampler.sample(), "first call only records a baseline")
        usleep(200_000)
        let usage = try? XCTUnwrap(sampler.sample())
        XCTAssertEqual(usage?.cores.count, ProcessInfo.processInfo.activeProcessorCount)
        XCTAssert((0...1).contains(usage?.total ?? -1))
    }

    func testMemory() throws {
        let memory = try XCTUnwrap(MemorySampler.sample())
        XCTAssertEqual(memory.total, ProcessInfo.processInfo.physicalMemory)
        XCTAssertGreaterThan(memory.used, 0)
        XCTAssertLessThanOrEqual(memory.used, memory.total)
    }

    func testNetworkCounters() throws {
        let counters = try XCTUnwrap(NetworkSampler.readCounters())
        XCTAssertGreaterThan(counters.bytesIn + counters.bytesOut, 0)
    }

    func testDisk() throws {
        var sampler = DiskSampler()
        let disk = sampler.sample(now: 0)
        let startup = try XCTUnwrap(disk.startup)
        XCTAssertGreaterThan(startup.total, 0)
        XCTAssertEqual(startup.path, "/")
        XCTAssertGreaterThan(DiskSampler.readIO().read, 0)
    }

    func testGPU() throws {
        let gpu = try XCTUnwrap(GPUSampler.sample())
        XCTAssert((0...1).contains(gpu.device))
    }

    func testCoreKindsMatchCoreCount() throws {
        let kinds = try XCTUnwrap(SystemInfo.coreKinds)
        XCTAssertEqual(kinds.count, ProcessInfo.processInfo.activeProcessorCount)
        XCTAssertEqual(kinds.filter { $0 == .performance }.count, SystemInfo.performanceCores)
    }

    /// Burns ~300 ms of CPU and checks the sampler reports roughly one core
    /// busy -- this is what catches a wrong Mach-tick conversion.
    func testProcessCPUOfThisProcess() throws {
        var sampler = ProcessSampler()
        let pid = getpid()
        _ = sampler.sample(now: ProcessInfo.processInfo.systemUptime)
        let start = ProcessInfo.processInfo.systemUptime
        var x = 0.0
        while ProcessInfo.processInfo.systemUptime - start < 0.3 { x += sin(x) + 1 }
        XCTAssertGreaterThan(x, 0)
        let me = try XCTUnwrap(sampler.sample(now: ProcessInfo.processInfo.systemUptime).first { $0.pid == pid })
        XCTAssert((0.6...1.4).contains(me.cpu), "cpu = \(me.cpu)")
        XCTAssertGreaterThan(me.memory, 1_000_000)
    }
}

final class SensorTests: XCTestCase {
    func testKeyDataMatchesKernelLayout() {
        XCTAssertEqual(MemoryLayout<SMC.KeyData>.size, 80)
    }

    func testDecodesSMCTypes() {
        XCTAssertEqual(SMC.decode([0x28, 0x80], type: SMC.fourCC("sp78")), 40.5)
        XCTAssertEqual(SMC.decode([0x17, 0x70], type: SMC.fourCC("fpe2")), 1500)
        var float: Float32 = 51.25
        let bytes = withUnsafeBytes(of: &float) { Array($0) }
        XCTAssertEqual(SMC.decode(bytes, type: SMC.fourCC("flt ")), 51.25)
    }

    /// Live: every Mac this runs on has a CPU temperature sensor.
    func testReadsCPUTemperature() throws {
        var sampler = SensorSampler()
        let readings = sampler.sample()
        print("sensors:", readings)
        let cpu = try XCTUnwrap(readings.cpu)
        XCTAssert((10...110).contains(cpu), "cpu \(cpu)")
    }
}
