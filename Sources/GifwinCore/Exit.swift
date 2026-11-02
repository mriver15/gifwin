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
    case budgetUnreachable = 75
    case policyDenied = 77

    /// Stable machine-readable name, used as the `error` field in JSON output.
    public var slug: String {
        switch self {
        case .ok: return "ok"
        case .usage: return "usage"
        case .noWindow: return "no_window"
        case .permissionDenied: return "tcc_denied"
        case .internalFailure: return "internal"
        case .outputUnwritable: return "output_unwritable"
        case .windowClosed: return "window_closed"
        case .budgetUnreachable: return "budget_unreachable"
        case .policyDenied: return "policy_denied"
        }
    }
}

public struct GifwinError: Error {
    public let code: ExitCode
    public let message: String
    /// What a caller (or the human behind it) should do about it, when there is something to do.
    public let remediation: String?
    /// Overrides the code's own slug, for failures that share an exit code but need different handling.
    public let slug: String?
    /// Extra machine-readable fields, such as the command that would grant consent.
    public let details: [String: String]
    public init(_ code: ExitCode, _ message: String, remediation: String? = nil, slug: String? = nil, details: [String: String] = [:]) {
        self.code = code
        self.message = message
        self.remediation = remediation
        self.slug = slug
        self.details = details
    }

    public static let settingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"

    public static func permission(_ message: String) -> GifwinError {
        GifwinError(.permissionDenied, message,
                    remediation: "Grant Screen Recording to Gifwin in System Settings > Privacy & Security > Screen & System Audio Recording, then run the command again.")
    }
}
