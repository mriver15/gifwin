# gifwin

Capture a macOS application window as a small GIF, MP4 or WebM from the command line, or from an AI agent over MCP. Built to show a fix working, reproduce a bug, or prove a change, so the output is small enough to paste into a pull request and specific enough to cite.

One 0.9 MB binary, no dependencies outside macOS itself, no network code, nothing resident when idle.

## What makes it agent-native

An agent cannot watch a GIF. So every capture also writes what it needs to check and cite the clip:

| File | What it is |
| --- | --- |
| `name.gif` | The clip. `--format mp4` or `webm` for video. |
| `name.contact.png` | Up to six keyframes, picked where the picture changes, each timestamped. One image a model can read. |
| `name.gifwin.json` | App, version, window, OS build, UTC start, settings, SHA-256 of the output, per-frame delays, the text read at each keyframe, a caption and alt text. |

`gifwin mcp` returns the contact sheet as an image in the same response as the capture, so the model sees it immediately.

## Requirements

- macOS 15 or later. The caption model needs macOS 26 with Apple Intelligence; without it captions come from metadata and OCR text.
- Swift 6 toolchain (Command Line Tools are enough).
- `ffmpeg` only for `--format webm`.

## Install

```sh
scripts/dev-cert.sh            # once: a stable local signing identity (see below)
scripts/bundle.sh --install    # builds Gifwin.app into ~/Applications and links ~/.local/bin/gifwin
gifwin doctor                  # shows what is and is not set up
```

macOS asks for Screen Recording permission on first use. Grant it to **Gifwin** in System Settings > Privacy & Security > Screen & System Audio Recording. `gifwin doctor` prints the exact link.

**Why `dev-cert.sh`:** an ad-hoc signature changes with every build, so macOS forgets the grant on each rebuild. The script makes a self-signed identity in its own keychain file (`~/.config/gifwin/dev.keychain-db`, not your login keychain) and `bundle.sh` uses it automatically. It is for local development only. A release build needs a Developer ID (`SIGN_IDENTITY=... scripts/bundle.sh`).

## Use

```sh
gifwin --list                                   # windows that can be captured
gifwin 5 -w Safari                              # 5 seconds of Safari -> ./Safari-<time>.gif
gifwin 8 -w "text:Build succeeded" -q crisp     # find the window by what it shows
gifwin 30 -w Terminal --until "text:PASSED"     # stop when it happens (30 s is the longest)
gifwin 5 -w Xcode --max-bytes 2m                # degrade colours, then rate, then size, until it fits
gifwin 5 -w Safari --redact auto                # blank tokens, emails, card numbers out of the pixels
gifwin 5 -w Safari --format webm                # needs ffmpeg
gifwin describe clip.gif                        # contact sheet + manifest for any existing GIF
```

Quality presets: `draft`, `balanced` (default), `crisp`, `max`. Selectors: app name, bundle id, `id:<n>`, `title~<text>`, `text:<words>`, `ask:<words>`. An ambiguous selector is an error that lists the candidates, never a guess.

### Catch something you could not time

```sh
gifwin watch -w MyApp --rolling 30    # keep the last 30 s in memory (the recording indicator stays on)
# ...the bug happens...
gifwin save-last 8                    # write the last 8 s
gifwin watch --stop
```

### Menu bar and hotkey (opt-in)

`gifwin menubar --install` adds a login item with a status item showing time and size while recording, and the hotkey **⌃⌥⌘G** to record the front window. It keeps the helper resident (about 19 MB more), which is why it is opt-in. `--uninstall` removes it.

## Use from an agent

```json
{ "mcpServers": { "gifwin": { "command": "gifwin", "args": ["mcp"] } } }
```

Tools: `list_windows`, `capture_gif`, `describe_capture`, `watch`, `save_last`. Agent captures default to `redact: auto`, write to `~/Pictures/Gifwin`, and are limited to 60 seconds.

### What agents are and are not allowed

A tool that lets a model record any window is an exfiltration risk, so agents start restricted:

- **Never recorded**, by anyone without `--force` and never by an agent: password managers, Keychain, Messages, Mail, authenticator apps, and browser windows that say they are private.
- **Consent first.** An agent's first capture of any other app fails with `consent_required` and the exact command to run. `gifwin consent grant <bundle-id>` lasts 24 hours. `~/.config/gifwin/policy.toml` can allow or deny apps permanently:

  ```toml
  [agent]
  allow = ["com.apple.Terminal"]
  deny  = ["com.example.secret"]
  consent_hours = 8
  ```

  An invalid policy file refuses agents; it never means "allow everything".
- **Everything is logged** to `~/.local/state/gifwin/log.jsonl`, append-only (`gifwin log`), including refusals.

**Limits.** This guards the MCP channel. An agent with a shell can run `gifwin consent grant` itself. Redaction is best effort: it reads text with OCR, so it can miss small or stylised text, and the manifest's `redaction.residual_in_output` says what it could still read. Manifest and caption text is always masked, whether or not pixels were.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Done |
| 64 | Usage error |
| 65 | No window matched, or the match was ambiguous |
| 69 | Screen Recording not granted |
| 70 | Internal failure |
| 73 | Output not writable |
| 74 | Window closed mid-capture; partial file kept |
| 75 | Byte budget unreachable; smallest file kept |
| 77 | Refused by policy |

With `--json`, stdout carries one result or error object and nothing else. Errors include a stable `error` name and, where useful, `remediation`.

## How it works

`gifwin` is a thin client. It never captures. It finds `Gifwin.app`, starts its helper through LaunchServices and sends the request over a private socket, so macOS attributes the Screen Recording grant to the app and not to whichever shell or agent asked. The helper exits 30 seconds after its last request.

```
gifwin / gifwin mcp / menu bar -> policy gate -> Gifwin.app helper
    resolve window -> ScreenCaptureKit -> [redact] -> encode -> GIF | MP4 (-> WebM)
                                                       -> contact sheet + manifest
```

GIF encoding is its own: per-frame Wu palettes built from only the pixels that changed, ordered dithering only where the match is poor, transparent-pixel diff rectangles, and idle frames written as one long delay. The rolling buffer keeps compressed frames with a full frame every 2 s so a clip cut from the middle is a valid GIF.

```
Sources/GifwinCore    capture, encoder, policy, analysis: everything that is not a process
Sources/gifwin        the executable: client, helper, MCP server, menu bar
Sources/encoder-checks  dev-only checks (XCTest and Swift Testing need full Xcode)
scripts/              bundle, dev-cert, exit-codes, mcp-smoke, perf
```

## Verify

```sh
swift run -c release encoder-checks   # encoder, policy, redaction, ring buffer, video (run in release, not debug)
scripts/exit-codes.sh                 # every exit code through the real binary
scripts/mcp-smoke.py                  # the MCP protocol, through the real helper
scripts/perf.sh --slow                # every performance budget
```

Cases that need Screen Recording are skipped, not failed, until Gifwin.app is granted.

## Performance

Measured by `scripts/perf.sh` on an M-series Mac; 1024x640 window, `balanced`.

| | Measured | Budget |
| --- | --- | --- |
| Binary, stripped | 0.9 MB | < 3 MB |
| Peak memory, 10 s capture | 45 MB | < 60 MB |
| CPU, typical window | 3.7 % of a core | < 15 % |
| Encode tail after capture stops (p95) | 2 ms | < 150 ms |
| Resident while watching | 43 MB | < 45 MB |
| Resident when idle | none | none |
| Typical 5 s window | 100-250 KB | |

A window where every pixel changes every frame costs about 15 % of a core, which no real window sustains.

## Not built

Model-judged `--until` conditions, APNG and WebP output, notarized releases (a Developer ID build works with `SIGN_IDENTITY`, but nothing here signs or notarizes for distribution). Live capture, `--until`, `--redact` and the menu bar are verified against synthetic sources and unit checks; see the status in the spec before relying on them.
