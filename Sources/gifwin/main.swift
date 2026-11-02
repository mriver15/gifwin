import CoreGraphics
import Foundation

// A bare process never connects to the window server, and ScreenCaptureKit then trips
// CGS_REQUIRE_INIT. Touching CoreGraphics once up front initialises it without needing AppKit.
_ = CGMainDisplayID()

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--serve" {
    Server.run()
} else if arguments == ["mcp"] {
    Task {
        await Mcp.run()
        exit(0)
    }
    dispatchMain()
} else {
    Task { exit(await Client.run(arguments)) }
    dispatchMain()
}
