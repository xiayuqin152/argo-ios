import Foundation

/// A contiguous bounded window of one terminal's native session. Backward
/// reads evict the newer end; forward reads evict the older end. The retained
/// boundary cursors always let the UI read an evicted block again.
public struct ChatTranscript: Equatable, Sendable {
    public enum Change: Equatable, Sendable {
        case updated
        case waiting(String)
        /// The native session changed; the cleared window needs `.latest`.
        case sessionChanged
        /// Another read moved this edge before the response arrived. Nothing
        /// was merged: request again from the current window's cursor.
        case stalePage
    }

    public static let defaultLimit = 600
    public static let defaultByteLimit = 4 * 1_048_576

    public private(set) var items: [ArgoChatItem] = []
    public private(set) var identity: ArgoAgentIdentity?
    public private(set) var start: ArgoChatPosition = .zero
    public private(set) var end: ArgoChatPosition = .zero
    public private(set) var size: Int64 = 0
    public private(set) var retainedBytes = 0
    public private(set) var skipped = 0
    public private(set) var waiting: String?
    public let limit: Int
    /// Retained UTF-8 content plus value/array element storage. At least one
    /// response budget so any individually bounded block can be retained.
    public let byteLimit: Int

    public init(limit: Int = ChatTranscript.defaultLimit, byteLimit: Int = ChatTranscript.defaultByteLimit) {
        self.limit = max(1, limit)
        self.byteLimit = max(ArgoChatPage.responseByteLimit, byteLimit)
    }

    public var hasOlder: Bool { start > .zero }
    public var newer: Bool { end < ArgoChatPosition(recordOffset: size) }
    public var isEmpty: Bool { items.isEmpty }
    public var nextCursor: ArgoChatCursor { identity == nil ? .latest : .after(end) }
    public var olderCursor: ArgoChatCursor? { identity != nil && hasOlder ? .before(start) : nil }

    public mutating func reset() {
        items = []; identity = nil
        start = .zero; end = .zero; size = 0
        retainedBytes = 0; skipped = 0; waiting = nil
    }

    @discardableResult
    public mutating func apply(_ page: ArgoChatPage, cursor: ArgoChatCursor) -> Change {
        switch cursor {
        case .before(let requested):
            guard identity != nil, requested == start else { return .stalePage }
        case .after(let requested):
            guard identity != nil, requested == end else { return .stalePage }
        case .latest, .around: break
        }
        if let note = page.waiting {
            reset(); waiting = note
            return .waiting(note)
        }
        switch cursor {
        case .before, .after:
            if page.identity != identity {
                reset()
                return .sessionChanged
            }
        case .latest, .around: break
        }
        waiting = nil
        switch cursor {
        case .latest, .around:
            identity = page.identity
            items = Self.merge([], page.items)
            start = page.start; end = page.end; size = page.size
            skipped = page.skipped
        case .before:
            // Preserve adjacency when a source rejects or normalizes a cursor.
            guard page.end == start else { return .stalePage }
            items = Self.merge(items, page.items)
            start = page.start
            size = max(size, page.size)
            skipped += page.skipped
        case .after:
            guard page.start == end else { return .stalePage }
            items = Self.merge(items, page.items)
            end = page.end
            size = max(size, page.size)
            skipped += page.skipped
        }
        retainedBytes = items.reduce(0) { $0 + $1.retainedByteCount }
        switch cursor {
        case .before: trimBack()
        case .latest, .after, .around: trimFront()
        }
        return .updated
    }

    private mutating func trimFront() {
        var cut = 0
        while items.count - cut > limit || retainedBytes > byteLimit {
            retainedBytes -= items[cut].retainedByteCount
            cut += 1
        }
        guard cut > 0 else { return }
        // Cursors name blocks, so splitting one large native record is safe.
        start = cut < items.count ? items[cut].cursor : end
        items.removeFirst(cut)
    }

    private mutating func trimBack() {
        var keep = items.count
        while keep > limit || retainedBytes > byteLimit {
            keep -= 1
            retainedBytes -= items[keep].retainedByteCount
        }
        guard keep < items.count else { return }
        // The first removed block is the exact exclusive end of the window.
        end = items[keep].cursor
        items.removeSubrange(keep...)
    }

    private static func merge(_ old: [ArgoChatItem], _ incoming: [ArgoChatItem]) -> [ArgoChatItem] {
        var byCursor = [ArgoChatPosition: ArgoChatItem]()
        for item in old { byCursor[item.cursor] = item }
        for item in incoming { byCursor[item.cursor] = item }
        return byCursor.values.sorted { $0.cursor < $1.cursor }
    }
}
