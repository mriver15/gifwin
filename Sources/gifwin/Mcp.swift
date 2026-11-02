import Foundation
import GifwinCore

/// `gifwin mcp`: a Model Context Protocol server on stdio.
///
/// It records nothing itself. Each tool call becomes the same request the CLI would send, handled by
/// the Gifwin.app helper, so an agent host launching this process does not become the thing that has to
/// hold the Screen Recording grant. stdout carries protocol messages only; anything else goes to stderr.
enum Mcp {
    static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    private static let outputLock = NSLock()

    static let instructions = """
    Gifwin records a window of a macOS application as a small GIF and returns evidence you can check. \
    You cannot watch a GIF, so every capture also returns a contact sheet: one image of up to six keyframes, \
    each stamped with its time in the clip. Look at it before you claim the capture shows what you intended, \
    and cite the manifest path and sha256 when you refer to the capture. Use list_windows first if you are \
    not sure how to name the window.
    """

    // MARK: - Loop

    static func run() async {
        // Blocking reads belong off the cooperative pool.
        let lines = AsyncStream<String> { continuation in
            Thread.detachNewThread {
                while let line = readLine(strippingNewline: true) { continuation.yield(line) }
                continuation.finish()
            }
        }
        await withTaskGroup(of: Void.self) { group in
            for await line in lines {
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                // A capture takes seconds; do not hold up pings and later requests behind it.
                group.addTask { await handle(line) }
            }
        }
    }

    private static func handle(_ line: String) async {
        guard let data = line.data(using: .utf8), let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
            return
        }
        guard let method = message["method"] as? String else { return } // a response to us; we send no requests
        let id = message["id"] // absent for notifications, which never get an answer
        let params = message["params"] as? [String: Any] ?? [:]

        func reply(_ result: Any) { if let id { send(["jsonrpc": "2.0", "id": id, "result": result]) } }
        func fail(_ code: Int, _ text: String) { if let id { send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": text]]) } }

        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            reply(["protocolVersion": supportedVersions.contains(asked) ? asked : supportedVersions[0],
                   "capabilities": ["tools": ["listChanged": false]],
                   "serverInfo": ["name": "gifwin", "version": Command.version],
                   "instructions": instructions])
        case "ping":
            reply([String: Any]())
        case "tools/list":
            reply(["tools": tools])
        case "tools/call":
            guard let name = params["name"] as? String else { return fail(-32602, "tools/call needs a tool name") }
            guard tools.contains(where: { $0["name"] as? String == name }) else { return fail(-32602, "Unknown tool: \(name)") }
            reply(await call(name, params["arguments"] as? [String: Any] ?? [:]))
        default:
            if id != nil { fail(-32601, "Method not found: \(method)") }
        }
    }

    private static func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        outputLock.lock()
        FileHandle.standardOutput.write(data + Data([10]))
        outputLock.unlock()
    }

    // MARK: - Tools

    static let tools: [[String: Any]] = [
        [
            "name": "list_windows",
            "description": "List the application windows that can be captured, with app name, bundle id, title and size. Set ocr to also read a short excerpt of the text each window is showing, which helps pick between windows of the same app. Slower with ocr.",
            "inputSchema": ["type": "object", "properties": [
                "ocr": ["type": "boolean", "description": "Include an excerpt of the on-screen text of each window. Default false."],
            ], "additionalProperties": false],
            "annotations": ["readOnlyHint": true, "openWorldHint": false],
        ],
        [
            "name": "capture_gif",
            "description": "Record one application window to a GIF for a fixed number of seconds. Returns the file path plus a contact sheet image of six keyframes with timestamps (look at it to verify what was recorded), a manifest path with the app version, window, hash and OCR text, and a caption. Still footage at the start and end is trimmed automatically. The macOS recording indicator is shown while it runs.",
            "inputSchema": ["type": "object", "properties": [
                "window": ["type": "string", "description": "Which window. An app name (\"Safari\"), a bundle id, \"id:<n>\" from list_windows, \"title~<text>\" for a title substring, \"text:<words>\" for a window showing that text, or \"ask:<words>\" for the window that best matches several words. Ambiguity is an error that lists the candidates."],
                "seconds": ["type": "number", "minimum": 0.2, "maximum": 60, "description": "How long to record. Default 5."],
                "quality": ["type": "string", "enum": ["draft", "balanced", "crisp", "max"], "description": "Default balanced, about 100-250 KB for 5 seconds of an app window."],
                "max_bytes": ["type": "integer", "minimum": 10000, "description": "Reduce colours, then frame rate, then size until the file fits. Reports whether it did."],
                "out_dir": ["type": "string", "description": "Directory for the output. Default $GIFWIN_OUT or ~/Pictures/Gifwin."],
                "name": ["type": "string", "description": "File name, without a directory. Default <app>-<timestamp>.gif."],
                "read_text": ["type": "boolean", "description": "Run OCR and write a caption. Default true; false skips both and still writes the sheet and manifest."],
            ], "required": ["window"], "additionalProperties": false],
            "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false],
        ],
        [
            "name": "describe_capture",
            "description": "Analyse an existing GIF: writes its contact sheet and manifest beside it and returns them, with a caption, alt text and the text read at each keyframe. Use it to check a GIF you did not just capture.",
            "inputSchema": ["type": "object", "properties": [
                "path": ["type": "string", "description": "Absolute path to a GIF."],
                "read_text": ["type": "boolean", "description": "Run OCR and write a caption. Default true."],
            ], "required": ["path"], "additionalProperties": false],
            "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false],
        ],
    ]

    static func call(_ name: String, _ arguments: [String: Any]) async -> [String: Any] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var args: [String]
        switch name {
        case "list_windows":
            args = ["--list", "--json"] + ((arguments["ocr"] as? Bool) == true ? ["--ocr"] : [])
        case "capture_gif":
            guard let window = arguments["window"] as? String, !window.isEmpty else { return failure("capture_gif needs a window") }
            let seconds = min(60, max(0.2, (arguments["seconds"] as? Double) ?? 5))
            args = ["--json", "--window", window, "--seconds", String(seconds)]
            if let q = arguments["quality"] as? String { args += ["--quality", q] }
            if let b = arguments["max_bytes"] as? Int { args += ["--max-bytes", String(max(10_000, b))] }
            if let n = arguments["name"] as? String {
                guard !n.contains("/"), !n.hasPrefix(".") else { return failure("name must be a plain file name, not a path") }
                args += ["--name", n]
            }
            if (arguments["read_text"] as? Bool) == false { args.append("--no-ai") }
            let out = (arguments["out_dir"] as? String) ?? ProcessInfo.processInfo.environment["GIFWIN_OUT"] ?? "\(home)/Pictures/Gifwin"
            args += ["--out", out]
        case "describe_capture":
            guard let path = arguments["path"] as? String, path.hasPrefix("/") else { return failure("describe_capture needs an absolute path") }
            args = ["describe", path, "--json"] + ((arguments["read_text"] as? Bool) == false ? ["--no-ai"] : [])
        default:
            return failure("Unknown tool: \(name)")
        }

        let outcome = await Client.dispatch(Request(args: args, cwd: home, env: Client.forwardedEnvironment()))
        return result(from: outcome, tool: name)
    }

    /// Turns what the CLI printed into a tool result: the facts as JSON, plus the contact sheet as an image
    /// so the model sees it in the same response.
    static func result(from outcome: Outcome, tool: String) -> [String: Any] {
        let parsed = try? JSONSerialization.jsonObject(with: Data(outcome.stdout.utf8))
        // 74 (window closed) and 75 (budget unreachable) leave a usable file; the JSON says what fell short.
        let usable = outcome.code == 0 || outcome.code == 74 || outcome.code == 75

        guard usable, var object = parsed as? [String: Any] ?? (parsed as? [Any]).map({ ["windows": $0] }) else {
            var error = parsed as? [String: Any] ?? ["error": "internal", "message": outcome.stderr.isEmpty ? "No output from gifwin" : outcome.stderr]
            error["exit_code"] = Int(outcome.code)
            return failure(error)
        }
        object["exit_code"] = Int(outcome.code)
        if outcome.code != 0 && !outcome.stderr.isEmpty { object["warning"] = outcome.stderr.trimmingCharacters(in: .whitespacesAndNewlines) }

        var content: [[String: Any]] = [["type": "text", "text": pretty(object)]]
        if let sheet = object["contact_sheet"] as? String, let png = FileManager.default.contents(atPath: sheet) {
            content.append(["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"])
        }
        return ["content": content, "structuredContent": object, "isError": false]
    }

    private static func failure(_ text: String) -> [String: Any] { failure(["error": "usage", "message": text]) }

    private static func failure(_ error: [String: Any]) -> [String: Any] {
        ["content": [["type": "text", "text": pretty(error)]], "structuredContent": error, "isError": true]
    }

    private static func pretty(_ object: Any) -> String {
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
