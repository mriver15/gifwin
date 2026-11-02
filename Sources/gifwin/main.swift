import CoreGraphics
import Foundation
import GifwinCore

// A bare process never connects to the window server, and ScreenCaptureKit then trips
// CGS_REQUIRE_INIT. Touching CoreGraphics once up front initialises it without needing AppKit.
_ = CGMainDisplayID()

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--serve" {
    Server.run(menubar: arguments.contains("--menubar"))
} else if arguments.first == "menubar" {
    Task {
        let rest = Array(arguments.dropFirst())
        let r = MenuBarAgent.run(rest, bundle: Client.bundlePath())
        // Removing the login item must also stop the helper it started; LaunchServices owns that process.
        if rest.first == "--uninstall" { _ = await Client.dispatch(Request(op: "quit")) }
        FileHandle.standardOutput.write(Data(r.text.utf8))
        exit(r.code)
    }
    dispatchMain()
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
