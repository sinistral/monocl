import Foundation

/// The engine's only access to time.
///
/// Not `Swift.Clock`
/// ---
///
/// The engine needs wall-clock `Date` for `asOf` stamps, staleness
/// budgets, `Retry-After` deadlines and window resets.  `Swift.Clock`
/// deliberately supplies none of those, so a protocol of our own is
/// simpler than adapting one that measures a different thing.  The name
/// also avoids shadowing `Swift.Clock` at every use site.
@MainActor
public protocol TimeSource: AnyObject {
    var now: Date { get }

    /// Returns early — without throwing — when the calling task is
    /// cancelled, so callers guard on `Task.isCancelled` afterwards
    /// rather than catching.
    func sleep(for duration: TimeInterval, tolerance: TimeInterval) async
}

/// The real clock.
public final class SystemTimeSource: TimeSource {
    public init() {}

    public var now: Date { .now }

    public func sleep(for duration: TimeInterval, tolerance: TimeInterval) async {
        try? await Task.sleep(for: .seconds(duration), tolerance: .seconds(tolerance))
    }
}
