/// Fixed-length series of the most recent samples, oldest first.
public struct History: Sendable, Equatable {
    public let capacity: Int
    public private(set) var values: [Double] = []

    public init(capacity: Int = 60) {
        self.capacity = capacity
    }

    public mutating func append(_ value: Double) {
        values.append(value)
        if values.count > capacity {
            values.removeFirst(values.count - capacity)
        }
    }

    public var last: Double? { values.last }
    public var peak: Double { values.max() ?? 0 }
}
