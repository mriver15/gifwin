import Foundation

/// Exit codes from the spec's CLI contract.
public enum ExitCode: Int32 {
    case ok = 0
    case usage = 64
    case noWindow = 65
    case permissionDenied = 69
    case internalFailure = 70
    case outputUnwritable = 73
    case windowClosed = 74
}

public struct GifwinError: Error {
    public let code: ExitCode
    public let message: String
    public init(_ code: ExitCode, _ message: String) {
        self.code = code
        self.message = message
    }
}
