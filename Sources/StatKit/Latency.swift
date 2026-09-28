import Foundation
import Network

/// Round-trip time to a host, measured as a TCP handshake on port 443.
/// ICMP ping needs a raw socket (root); a handshake is one round trip too,
/// and it works for any host that serves HTTPS.
public enum LatencyProbe {
    public static func measure(host: String, timeout: TimeInterval = 3) async -> TimeInterval? {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: 443, using: .tcp)
        let start = DispatchTime.now()
        let state = ProbeState()

        return await withCheckedContinuation { continuation in
            @Sendable func finish(_ result: TimeInterval?) {
                guard state.claim() else { return }
                connection.cancel()
                continuation.resume(returning: result)
            }
            connection.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    finish(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9)
                case .failed, .cancelled:
                    finish(nil)
                case .waiting:
                    // No route (offline); don't wait out the timeout.
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }
}

/// Makes sure the continuation resumes exactly once, whichever of the
/// state handler and the timeout gets there first.
private final class ProbeState: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
