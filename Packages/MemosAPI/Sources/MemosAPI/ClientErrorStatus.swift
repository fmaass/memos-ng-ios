import HTTPTypes
import OpenAPIRuntime

extension ClientError {
    /// The status of the response the failed call had already received, or nil when none arrived.
    ///
    /// Here rather than at the caller because this layer links HTTPTypes and the layers above do
    /// not: reading `response?.status` from MemosCore compiles and then fails to link. A thrown
    /// error that still carries a status is one where the server answered and something after the
    /// status line went wrong — the body did not decode, or the connection dropped mid-body.
    public var receivedStatusCode: Int? { response?.status.code }
}
