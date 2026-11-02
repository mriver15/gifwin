#!/usr/bin/env python3
"""Drives `gifwin mcp` the way an agent host would, over stdio, and checks what comes back.

    scripts/mcp-smoke.py [path/to/Gifwin.app]

Needs no Screen Recording permission: describe_capture works on any GIF. If Gifwin.app is granted,
a real capture_gif is attempted as well and checked the same way.
"""
import base64, json, os, subprocess, sys, tempfile, time
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

root = Path(__file__).resolve().parent.parent
app = Path(sys.argv[1] if len(sys.argv) > 1 else root / "build/Gifwin.app").resolve()
binary = app / "Contents/MacOS/gifwin"
# Policy and the audit log go to a scratch directory so the test never touches the real ones.
scratch = Path(tempfile.mkdtemp(prefix="gifwin-mcp-state-"))
env = {**os.environ, "GIFWIN_APP": str(app), "GIFWIN_CONFIG_DIR": str(scratch / "config"), "GIFWIN_STATE_DIR": str(scratch / "state")}

passed = failed = 0
def check(ok, what):
    global passed, failed
    if ok: passed += 1; print(f"  ok    {what}")
    else:  failed += 1; print(f"  FAIL  {what}")

class Server:
    def __init__(self, extra_env=None):
        self.p = subprocess.Popen([str(binary), "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True, env={**env, **(extra_env or {})})
        self.n = 0
        self.raw = []
    def send(self, method, params=None, notify=False):
        msg = {"jsonrpc": "2.0", "method": method}
        if params is not None: msg["params"] = params
        if not notify:
            self.n += 1; msg["id"] = self.n
        self.p.stdin.write(json.dumps(msg) + "\n"); self.p.stdin.flush()
        if notify: return None
        line = self.p.stdout.readline()
        self.raw.append(line)
        return json.loads(line)
    def call(self, name, arguments):
        return self.send("tools/call", {"name": name, "arguments": arguments})
    def close(self):
        self.p.stdin.close()
        try: self.p.wait(timeout=5)
        except subprocess.TimeoutExpired: self.p.kill()

# A GIF with text on it, made independently of gifwin's own encoder.
work = Path(tempfile.mkdtemp(prefix="gifwin-mcp-"))
font = ImageFont.load_default(size=56)
frames = []
for words, bg in [("COMPILING SOURCES", (200, 220, 255)), ("RUNNING TESTS", (255, 245, 200)), ("BUILD PASSED", (200, 255, 210))]:
    im = Image.new("RGB", (640, 360), bg); ImageDraw.Draw(im).text((30, 140), words, fill=(0, 0, 0), font=font); frames.append(im)
gif = work / "demo.gif"
frames[0].save(gif, save_all=True, append_images=frames[1:], duration=700, loop=0)

print("handshake")
s = Server()
r = s.send("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "smoke", "version": "1"}})
check(r["result"]["protocolVersion"] == "2025-06-18" and r["result"]["serverInfo"]["name"] == "gifwin", "initialize negotiates the version")
check("tools" in r["result"]["capabilities"] and "contact sheet" in r["result"]["instructions"], "capabilities and usage instructions present")
s.send("notifications/initialized", notify=True)
old = Server().send("initialize", {"protocolVersion": "1999-01-01"})
check(old["result"]["protocolVersion"] in ("2025-06-18", "2025-03-26", "2024-11-05"), "unknown version falls back to one we speak")
check(s.send("ping")["result"] == {}, "ping")

print("tools/list")
tools = {t["name"]: t for t in s.send("tools/list")["result"]["tools"]}
check(set(tools) == {"list_windows", "capture_gif", "describe_capture", "watch", "save_last"}, f"five tools: {sorted(tools)}")
props = tools["capture_gif"]["inputSchema"]["properties"]
check({"until", "after", "redact"} <= set(props) and props["redact"]["enum"] == ["auto", "none"], "capture_gif offers until, after and redact")
check(tools["watch"]["inputSchema"]["properties"]["action"]["enum"] == ["start", "stop", "status"], "watch has start, stop and status")
check(tools["capture_gif"]["inputSchema"]["required"] == ["window"], "capture_gif requires only a window")
check(tools["capture_gif"]["inputSchema"]["properties"]["seconds"]["maximum"] == 60, "duration is bounded in the schema")

print("describe_capture on a GIF made elsewhere")
r = s.call("describe_capture", {"path": str(gif)})["result"]
check(r["isError"] is False, "not an error")
kinds = [c["type"] for c in r["content"]]
check(kinds == ["text", "image"], f"text then image: {kinds}")
img = r["content"][1]
png = base64.b64decode(img["data"])
check(img["mimeType"] == "image/png" and png[:8] == b"\x89PNG\r\n\x1a\n", "the contact sheet arrives as a real PNG")
check(len(png) < 1_000_000, f"sheet is a sensible size ({len(png) // 1024} KB)")
sc = r["structuredContent"]
import hashlib
check(sc["sha256"] == hashlib.sha256(gif.read_bytes()).hexdigest(), "sha256 matches the file")
words = " ".join(" ".join(k["text"]) for k in sc["keyframes"]).upper()
check(all(w in words for w in ("COMPILING", "TESTS", "PASSED")), f"OCR read all three scenes: {words[:80]!r}")
check(Path(sc["contact_sheet"]).exists() and Path(sc["manifest"]).exists(), "sheet and manifest were written beside the GIF")
manifest = json.loads(Path(sc["manifest"]).read_text())
check(manifest["schema"] == "gifwin.manifest/1" and manifest["output"]["sha256"] == sc["sha256"], "manifest agrees with the result")
check(json.loads(r["content"][0]["text"])["caption"] == sc["caption"], "text content and structuredContent agree")

print("errors an agent can act on")
r = s.call("capture_gif", {})["result"]
check(r["isError"] is True and "window" in r["content"][0]["text"], "missing window is a tool error")
r = s.call("describe_capture", {"path": "relative.gif"})["result"]
check(r["isError"] is True, "relative path rejected")
r = s.call("describe_capture", {"path": str(work / "nope.gif")})["result"]
check(r["isError"] is True and r["structuredContent"]["exit_code"] == 64, "missing file is a usage error (64)")
r = s.call("capture_gif", {"window": "x", "name": "../escape.gif"})["result"]
check(r["isError"] is True, "a name containing a path is refused")
r = s.call("watch", {"action": "start"})["result"]
check(r["isError"] is True, "watch start without a window is a tool error")
r = s.call("watch", {"action": "explode"})["result"]
check(r["isError"] is True, "an unknown watch action is a tool error")
r = s.call("save_last", {"name": "../x.gif"})["result"]
check(r["isError"] is True, "save_last refuses a name containing a path")
check(s.send("no/such/method").get("error", {}).get("code") == -32601, "unknown method is -32601")
check(s.send("tools/call", {"name": "format_disk", "arguments": {}}).get("error", {}).get("code") == -32602, "unknown tool is -32602")

faulty = Server({"GIFWIN_FAULT": "tcc"})
faulty.send("initialize", {"protocolVersion": "2025-06-18"})
r = faulty.call("capture_gif", {"window": "Safari"})["result"]
sc = r["structuredContent"]
check(r["isError"] is True and sc["error"] == "tcc_denied" and sc["exit_code"] == 69, "permission failure is structured: tcc_denied / 69")
check("Grant Screen Recording" in sc["remediation"] and sc["settings_url"].startswith("x-apple"), "it says exactly what to click")
faulty.close()

print("policy: an agent is held to it")
blocked = Server({"GIFWIN_FAULT": "fake-window:com.1password.1password:Vault"})
blocked.send("initialize", {"protocolVersion": "2025-06-18"})
r = blocked.call("capture_gif", {"window": "1Password", "redact": "none"})["result"]
sc = r["structuredContent"]
check(r["isError"] is True and sc["error"] == "policy_denied" and sc["exit_code"] == 77, "a password manager is refused: policy_denied / 77")
blocked.close()
needs = Server({"GIFWIN_FAULT": "fake-window:com.apple.Terminal:zsh"})
needs.send("initialize", {"protocolVersion": "2025-06-18"})
r = needs.call("capture_gif", {"window": "Terminal"})["result"]
sc = r["structuredContent"]
check(r["isError"] is True and sc["error"] == "consent_required" and sc["grant_command"] == "gifwin consent grant com.apple.Terminal", "an unconsented app asks for consent and names the command")
needs.close()
subprocess.run([str(binary), "consent", "grant", "com.apple.Terminal"], env=env, capture_output=True)
ok = Server({"GIFWIN_FAULT": "fake-window:com.apple.Terminal:zsh"})
ok.send("initialize", {"protocolVersion": "2025-06-18"})
r = ok.call("capture_gif", {"window": "Terminal"})["result"]
check(r["structuredContent"]["error"] != "consent_required", "after the person grants consent it is let through the policy")
ok.close()
log = [json.loads(l) for l in (scratch / "state" / "log.jsonl").read_text().splitlines()]
check(any(e["phase"] == "refused" and e["caller"] == "mcp" for e in log), f"refusals by agents are in the audit log ({len(log)} lines)")
check(all(e["caller"] == "mcp" for e in log if e["op"] == "capture"), "and are attributed to the agent")
subprocess.run(["chflags", "nouappnd", str(scratch / "state" / "log.jsonl")])

print("protocol hygiene")
check(all(json.loads(l) for l in s.raw), "every stdout line is a JSON message")
s.close()
check(s.p.returncode == 0, "exits cleanly when the host closes stdin")

print("live capture (only if Gifwin.app is granted)")
granted = subprocess.run([str(binary), "doctor"], capture_output=True, env=env).returncode == 0
if granted:
    live = Server(); live.send("initialize", {"protocolVersion": "2025-06-18"})
    r = live.call("capture_gif", {"window": "Terminal", "seconds": 2, "quality": "draft", "out_dir": str(work)})["result"]
    check(r["isError"] is False and [c["type"] for c in r["content"]] == ["text", "image"], "capture returns the facts and the sheet together")
    live.close()
else:
    print("  skip  Gifwin.app has no Screen Recording grant")

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
