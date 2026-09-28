import Foundation
import StatKit

/// Samples every metric group on its own interval and keeps a short
/// history of each for the graphs.
///
/// Polling starts at app launch, not from a dropdown: MenuBarExtra tears
/// the dropdown's views down when it closes, and the menu bar figures must
/// keep moving regardless.
@MainActor
final class Monitor: ObservableObject {
    nonisolated static let historyLength = 60

    @Published private(set) var cpu: CPUUsage?
    @Published private(set) var gpu: GPUUsage?
    @Published private(set) var memory: MemoryUsage?
    @Published private(set) var network: NetworkUsage?
    @Published private(set) var disk: DiskUsage?
    @Published private(set) var battery: BatteryInfo?
    @Published private(set) var sensors: SensorReadings?
    @Published private(set) var loadAverage: [Double] = []
    @Published private(set) var processes: [ProcessUsage] = []
    @Published private(set) var publicIP: PublicIPInfo?
    @Published private(set) var publicIPFailed = false
    @Published private(set) var isFetchingPublicIP = false
    /// Seconds; nil until measured or while the host is unreachable.
    @Published private(set) var latency: TimeInterval?
    @Published private(set) var latencyFailed = false

    @Published private(set) var userHistory = History(capacity: historyLength)
    @Published private(set) var systemHistory = History(capacity: historyLength)
    @Published private(set) var networkInHistory = History(capacity: historyLength)
    @Published private(set) var networkOutHistory = History(capacity: historyLength)
    @Published private(set) var diskReadHistory = History(capacity: historyLength)
    @Published private(set) var diskWriteHistory = History(capacity: historyLength)

    let bootTime = SystemInfo.bootTime()

    private var cpuSampler = CPUSampler()
    private var networkSampler = NetworkSampler()
    private var diskSampler = DiskSampler()
    private var processSampler = ProcessSampler()
    private var sensorSampler = SensorSampler()
    private var loop: Task<Void, Never>?
    /// When each group last sampled, in system uptime seconds.
    private var lastSampled: [SampleGroup: Double] = [:]
    private var processesSampledAt: Double?
    private var intervals: [SampleGroup: Double] = [:]
    private var defaultsObserver: NSObjectProtocol?

    private var publicIPFetchedAt: Date?
    /// The local address the public IP was looked up for; a change means a
    /// different network, and likely a different public address.
    private var publicIPLocalAddress: String??
    private var pingedAt: Date?
    private var pingHost: String?
    private var isPinging = false

    /// Dropdowns (and the settings preview) currently on screen. The
    /// per-process scan is the one costly sampler, so it only runs while
    /// something that shows it is open.
    private var viewers = 0

    init() {
        intervals = Self.currentIntervals()
        start()
        // A new interval should apply now, not after the old one runs out.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let current = Self.currentIntervals()
                guard current != self.intervals else { return }
                self.intervals = current
                self.start()
            }
        }
    }

    private static func currentIntervals() -> [SampleGroup: Double] {
        Dictionary(uniqueKeysWithValues: SampleGroup.allCases.map { ($0, $0.interval) })
    }

    func viewerAppeared() {
        viewers += 1
        guard viewers == 1 else { return }
        sampleProcesses()
        // The first scan after a pause averages over the whole pause; a
        // quick second one shows what is busy right now.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            self?.sampleProcesses()
        }
    }

    func viewerDisappeared() {
        viewers = max(0, viewers - 1)
    }

    /// Sleeps until the next group is due, samples every group that is,
    /// and repeats.
    private func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let wait = self?.tick() else { return }
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    /// Returns the seconds until the next group is due.
    private func tick() -> Double {
        let now = ProcessInfo.processInfo.systemUptime
        var nextDue = Double.infinity
        for group in SampleGroup.allCases {
            let interval = intervals[group] ?? 1
            // A little slack so a wake-up a hair early still counts.
            if let last = lastSampled[group], now - last < interval - 0.05 {
                nextDue = min(nextDue, last + interval)
                continue
            }
            lastSampled[group] = now
            sample(group, now: now)
            nextDue = min(nextDue, now + interval)
        }

        // Processes appear in the CPU, Memory and Disks dropdowns; scan as
        // often as the fastest of those, and only while one is open.
        if viewers > 0 {
            let interval = [SampleGroup.cpu, .memory, .disk].map { intervals[$0] ?? 1 }.min() ?? 1
            if processesSampledAt.map({ now - $0 >= interval - 0.05 }) ?? true {
                sampleProcesses()
            }
            nextDue = min(nextDue, (processesSampledAt ?? now) + interval)
        }
        return max(nextDue - ProcessInfo.processInfo.systemUptime, 0.05)
    }

    private func sample(_ group: SampleGroup, now: Double) {
        switch group {
        case .cpu:
            if let cpu = cpuSampler.sample() {
                self.cpu = cpu
                userHistory.append(cpu.user)
                systemHistory.append(cpu.system)
            }
            gpu = GPUSampler.sample()
            loadAverage = SystemInfo.loadAverage()
            sensors = sensorSampler.sample()
        case .memory:
            memory = MemorySampler.sample()
        case .network:
            let chosenInterface = UserDefaults.standard.string(forKey: SettingsKey.networkInterface) ?? ""
            networkSampler.interface = chosenInterface.isEmpty ? nil : chosenInterface
            network = networkSampler.sample(now: now)
            if let network {
                networkInHistory.append(network.bytesInPerSecond)
                networkOutHistory.append(network.bytesOutPerSecond)
            }
            updatePublicIPIfNeeded()
            pingIfNeeded()
        case .disk:
            let disk = diskSampler.sample(now: now)
            self.disk = disk
            diskReadHistory.append(disk.readPerSecond)
            diskWriteHistory.append(disk.writePerSecond)
        case .battery:
            var battery = BatterySampler.sample()
            // macOS 27 dropped the battery's temperature from the power
            // source info; the SMC still has it.
            if battery?.temperature == nil { battery?.temperature = sensors?.battery }
            self.battery = battery
        }
    }

    private func sampleProcesses() {
        let now = ProcessInfo.processInfo.systemUptime
        processesSampledAt = now
        processes = processSampler.sample(now: now)
    }

    // MARK: - Public IP and latency

    private func updatePublicIPIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: SettingsKey.publicIP) else {
            publicIP = nil
            publicIPFetchedAt = nil
            publicIPLocalAddress = nil
            return
        }
        let address = network?.address
        let refresh = PublicIPRefresh(rawValue: defaults.string(forKey: SettingsKey.publicIPRefresh) ?? "") ?? .onChange
        let age = publicIPFetchedAt.map { Date().timeIntervalSince($0) } ?? .infinity

        let due = publicIPLocalAddress == nil                      // never looked up
            || publicIPLocalAddress != .some(address)              // network changed
            || (publicIPFailed && age >= 60)                       // retry a failure
            || refresh.interval.map { age >= $0 } == true          // periodic refresh
        guard due, address != nil else {
            if address == nil { publicIP = nil }
            return
        }
        refreshPublicIP()
    }

    func refreshPublicIP() {
        guard !isFetchingPublicIP else { return }
        isFetchingPublicIP = true
        publicIPLocalAddress = .some(network?.address)
        publicIPFetchedAt = Date()
        Task { [weak self] in
            do {
                let info = try await PublicIPLookup.fetch()
                self?.publicIP = info
                self?.publicIPFailed = false
            } catch {
                self?.publicIPFailed = true
            }
            self?.isFetchingPublicIP = false
        }
    }

    /// One handshake every 5 seconds at most, whatever the update interval.
    private func pingIfNeeded() {
        let defaults = UserDefaults.standard
        let host = (defaults.string(forKey: SettingsKey.pingHost) ?? "").trimmingCharacters(in: .whitespaces)
        guard defaults.bool(forKey: SettingsKey.ping), !host.isEmpty else {
            latency = nil
            latencyFailed = false
            return
        }
        if host != pingHost {
            pingHost = host
            latency = nil
            latencyFailed = false
            pingedAt = nil
        }
        guard !isPinging, pingedAt.map({ Date().timeIntervalSince($0) >= 5 }) ?? true else { return }
        isPinging = true
        pingedAt = Date()
        Task { [weak self] in
            let result = await LatencyProbe.measure(host: host)
            guard let self else { return }
            self.isPinging = false
            // The host may have been changed in Settings meanwhile.
            guard self.pingHost == host else { return }
            self.latency = result
            self.latencyFailed = result == nil
        }
    }

    func top(_ list: ProcessList, by metric: (ProcessUsage) -> Double) -> [ProcessUsage] {
        let count = UserDefaults.standard.integer(forKey: SettingsKey.processCount(for: list))
        return Array(processes.sorted { metric($0) > metric($1) }.prefix(max(count, 1)))
    }

    var uptime: TimeInterval? {
        bootTime.map { Date().timeIntervalSince($0) }
    }
}
