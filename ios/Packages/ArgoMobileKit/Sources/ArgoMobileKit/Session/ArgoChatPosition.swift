import Foundation

/// Boundary immediately before a projected chat block. Record offsets alone
/// cannot address the many blocks that may share one native JSONL record.
public struct ArgoChatPosition: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let recordOffset: Int64
    public let blockIndex: Int

    public init(recordOffset: Int64, blockIndex: Int = 0) {
        self.recordOffset = recordOffset
        self.blockIndex = blockIndex
    }

    public static let zero = ArgoChatPosition(recordOffset: 0)
    public var isValid: Bool { recordOffset >= 0 && blockIndex >= 0 }
    public var description: String { "\(recordOffset):\(blockIndex)" }

    public init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && ($0 == "0" || $0.first != "0") && $0.utf8.allSatisfy({ (48...57).contains($0) }) }),
              let offset = Int64(parts[0]), let index = Int(parts[1]) else { return nil }
        self.init(recordOffset: offset, blockIndex: index)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.recordOffset == rhs.recordOffset ? lhs.blockIndex < rhs.blockIndex : lhs.recordOffset < rhs.recordOffset
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = Self(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid bounded chat block cursor")
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
