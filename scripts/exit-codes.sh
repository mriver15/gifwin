#!/bin/zsh
# Drives the real binary and checks every exit code in the CLI contract.
#
#   scripts/exit-codes.sh [path/to/Gifwin.app]
#
# Cases that need no Screen Recording permission always run. The rest need Gifwin.app to be
# granted and a window to point at, and are skipped (not failed) when permission is missing.
set -uo pipefail
cd "${0:A:h}/.."

APP="${1:-build/Gifwin.app}"
export GIFWIN_APP="${APP:A}"
BIN="$GIFWIN_APP/Contents/MacOS/gifwin"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"; "$BIN" quit >/dev/null 2>&1' EXIT

pass=0; fail=0; skip=0
expect() { # expect <code> <label> <command...>
    local want=$1 label=$2; shift 2
    "$@" >"$OUT/stdout" 2>"$OUT/stderr"; local got=$?
    if [[ $got == $want ]]; then printf '  ok    %-3s %s\n' "$want" "$label"; ((pass++))
    else printf '  FAIL  want %s got %s: %s\n        %s\n' "$want" "$got" "$label" "$(head -c 300 "$OUT/stderr")"; ((fail++)); fi
}

echo "no permission needed"
expect 0  "--version"                        "$BIN" --version
expect 0  "--help"                           "$BIN" --help
expect 64 "unknown flag"                     "$BIN" --bogus
expect 64 "bad quality"                      "$BIN" 1 -w x -q ultra
expect 64 "bad fps"                          "$BIN" 1 -w x --fps 11
expect 64 "missing --window"                 "$BIN" 1
expect 64 "flag without value"               "$BIN" --seconds
expect 69 "permission (simulated)"           env GIFWIN_FAULT=tcc "$BIN" 1 -w x
expect 70 "internal (simulated)"             env GIFWIN_FAULT=internal "$BIN" 1 -w x
expect 74 "window closed (simulated)"        env GIFWIN_FAULT=window-closed "$BIN" 1 -w x
expect 64 "describe without a path"          "$BIN" describe
expect 64 "describe a missing file"          "$BIN" describe /no/such/file.gif
expect 64 "bad --trim value"                 "$BIN" 1 -w x --trim sideways
expect 73 "output path unwritable"           "$BIN" 1 -w x --out /dev/null/nope

"$BIN" 1 -w x --json --out /dev/null/nope >"$OUT/j" 2>/dev/null
if python3 -c "import json,sys; d=json.load(open('$OUT/j')); assert d['error']=='output_unwritable' and d['code']==73"; then
    echo "  ok    --json error is one parseable object"; ((pass++)); else echo "  FAIL  --json error not parseable"; ((fail++)); fi
GIFWIN_FAULT=tcc "$BIN" 1 -w x --json >"$OUT/j" 2>/dev/null
if python3 -c "import json; d=json.load(open('$OUT/j')); assert d['error']=='tcc_denied' and d['settings_url'].startswith('x-apple') and d['remediation']"; then
    echo "  ok    --json permission error carries remediation and settings_url"; ((pass++)); else echo "  FAIL  permission JSON incomplete"; ((fail++)); fi

echo "needs Screen Recording for Gifwin.app"
if "$BIN" doctor >"$OUT/doctor" 2>&1; then
    WIN="$("$BIN" --list --json | python3 -c "import json,sys; w=json.load(sys.stdin); print(w[0]['app'] if w else '')")"
    expect 0  "dry run resolves a window"        "$BIN" 1 -w "$WIN" --dry-run --out "$OUT"
    expect 65 "no window matches"                "$BIN" 1 -w zzz-no-such-app --dry-run
    expect 65 "ambiguous id selector"            "$BIN" 1 -w "id:0" --dry-run
    expect 0  "capture writes a file"            "$BIN" 1 -w "$WIN" -q draft --out "$OUT" --name smoke
    [[ -s "$OUT/smoke.gif" && "$(head -c 6 "$OUT/smoke.gif")" == "GIF89a" ]] && { echo "  ok    output is a GIF89a"; ((pass++)); } || { echo "  FAIL  no GIF at $OUT/smoke.gif"; ((fail++)); }
    expect 75 "byte budget unreachable"          "$BIN" 1 -w "$WIN" --max-bytes 1 --out "$OUT" --name tiny
else
    echo "  skip  Gifwin.app has no Screen Recording grant (run: $BIN doctor)"; ((skip++))
fi

printf '\n%s passed, %s failed, %s skipped\n' $pass $fail $skip
exit $(( fail > 0 ? 1 : 0 ))
