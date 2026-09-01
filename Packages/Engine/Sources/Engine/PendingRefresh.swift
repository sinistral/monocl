/// What the menu says in place of its refresh command.  One value
/// rather than a flag plus a reason: the menu has one row to fill, and
/// a pair of booleans admits a state where it is both.
public enum PendingRefresh {
    /// A requested refresh has yet to land — waiting out the minimum
    /// spacing, or in flight.
    case refreshing
    /// Waiting out a `Retry-After` the endpoint supplied.  Distinguished
    /// because it can last an hour, and an hour of "Refreshing…" is a
    /// claim the app cannot support.
    case rateLimited
}

extension PendingRefresh {
    /// Derived from the rate limit FIRST, because that limit outlives
    /// any one request: the endpoint's `Retry-After` can run for an
    /// hour, and for that hour no refresh of usage can succeed whether
    /// or not anyone has clicked.  Keying the row on an outstanding
    /// request instead would leave a live command through most of the
    /// window, offering an action that cannot move the rows above it.
    public static func forMenu(
        rateLimited: Bool,
        refreshesOutstanding: [Bool]
    ) -> PendingRefresh? {
        if rateLimited { return .rateLimited }
        return refreshesOutstanding.contains(true) ? .refreshing : nil
    }
}
