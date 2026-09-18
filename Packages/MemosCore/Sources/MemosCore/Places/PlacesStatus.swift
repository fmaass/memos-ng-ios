import Foundation

/// Which of the map's four states the markers read is actually in.
///
/// Ported from the SPA's `frontend/src/lib/places/state.ts`, and it exists for the defect it was
/// written to end: "no photo here knows where it was taken yet" is a statement of FACT about the
/// library, and rendering it from the absence of markers alone also claims it while the request
/// is still in flight and after the request has failed. Three different situations told to the
/// reader as one, because the only thing the view could see is the one thing they share.
nonisolated public enum PlacesStatus: String, Sendable, Equatable, CaseIterable {
    /// No answer yet — the read has never resolved.
    case pending
    /// The last attempt failed.
    case error
    /// The read settled with nothing.
    case empty
    case ready

    /// Markers already in hand win over every other signal: a refresh in the background, and a
    /// refresh that FAILED, both leave the map showing the pins it has rather than replacing them
    /// with a spinner or an apology. Beyond that the order is the order of what the reader is
    /// owed — we are still asking, we could not ask, there is genuinely nothing to show.
    public static func of(isPending: Bool, isError: Bool, markerCount: Int) -> PlacesStatus {
        if markerCount > 0 { return .ready }
        if isPending { return .pending }
        if isError { return .error }
        return .empty
    }
}
