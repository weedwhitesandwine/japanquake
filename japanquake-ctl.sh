#!/bin/bash
# Japan Quake Monitor settings helper. Runs ONLY when the user applies a choice in Japan Quake Monitor's
# settings card — never on its own.
#
#   japanquake-ctl.sh bind "SUPER + ALT + J"   manage Japan Quake Monitor's hotkey as a marked
#                                          block in ~/.config/hypr/bindings.lua
#                                          (replaces only its own block, never
#                                          other lines)
#   japanquake-ctl.sh unbind                   remove that block
#   japanquake-ctl.sh bar on|off [section]     add/remove the Japan Quake Monitor icon in the
#                                          bar layout (~/.config/omarchy/shell.json)
set -e

ID="io.github.weedwhitesandwine.japanquake"
BIND_FILE="$HOME/.config/hypr/bindings.lua"
MARK_IN="-- >>> japanquake hotkey (managed by Japan Quake Monitor settings — change it there)"
MARK_OUT="-- <<< japanquake hotkey"

strip_block() {
  # print bindings.lua without Japan Quake Monitor's marked block
  awk '
    index($0, ">>> japanquake hotkey") { skip = 1; next }
    index($0, "<<< japanquake hotkey") { skip = 0; next }
    !skip { print }
  ' "$BIND_FILE"
}

case "$1" in
  bind)
    key="$2"
    [[ -n $key && -f $BIND_FILE ]] || exit 1
    # This value ends up inside a Lua string in bindings.lua, so it is checked
    # here as well as in the settings card. A hotkey is modifiers plus one key
    # and nothing else; anything that does not match that shape is refused
    # rather than escaped, because there is no reason for it to exist.
    if ! [[ $key =~ ^(SUPER|CTRL|ALT|SHIFT)([[:space:]]\+[[:space:]](SUPER|CTRL|ALT|SHIFT))*[[:space:]]\+[[:space:]]([A-Z0-9]|F([1-9]|1[0-2])|SPACE|RETURN|ENTER|TAB|ESCAPE|BACKSPACE|DELETE|INSERT|HOME|END|PAGE_UP|PAGE_DOWN|UP|DOWN|LEFT|RIGHT|COMMA|PERIOD|SLASH|MINUS|EQUAL|SEMICOLON|APOSTROPHE|GRAVE|BRACKETLEFT|BRACKETRIGHT|BACKSLASH)$ ]]; then
      echo "japanquake-ctl: refusing hotkey that is not modifiers plus one key: $key" >&2
      exit 1
    fi
    # The replacement is staged in the same directory as bindings.lua and
    # renamed over it, so the swap is a single atomic step — staging it in
    # /tmp and mv-ing across filesystems degrades to a copy, which can leave
    # a half-written config if interrupted. mktemp creates the stage file
    # exclusively under a random name, so nothing can have been planted at it.
    tmp=$(mktemp "$BIND_FILE.XXXXXXXX")
    trap 'rm -f "$tmp"' EXIT
    strip_block > "$tmp"
    {
      echo ""
      echo "$MARK_IN"
      printf 'o.bind("%s", "Japan Quake Monitor (earthquake map)", "omarchy-shell shell toggle %s")\n' "$key" "$ID"
      echo "$MARK_OUT"
    } >> "$tmp"
    chmod --reference="$BIND_FILE" "$tmp" 2>/dev/null || chmod 644 "$tmp"
    mv -f "$tmp" "$BIND_FILE"
    trap - EXIT
    hyprctl reload >/dev/null 2>&1 || true
    ;;
  unbind)
    [[ -f $BIND_FILE ]] || exit 0
    tmp=$(mktemp "$BIND_FILE.XXXXXXXX")
    trap 'rm -f "$tmp"' EXIT
    strip_block > "$tmp"
    chmod --reference="$BIND_FILE" "$tmp" 2>/dev/null || chmod 644 "$tmp"
    mv -f "$tmp" "$BIND_FILE"
    trap - EXIT
    hyprctl reload >/dev/null 2>&1 || true
    ;;
  bar)
    # bar on [left|center|right] | bar off
    # The icon is visible when Japan Quake Monitor's entry lives in the bar layout of
    # shell.json; hidden (but the plugin still enabled) when the entry lives
    # in the plugins list instead. The shell hot-reloads the file.
    python3 - "$2" "${3:-right}" <<'PY'
import json, os, stat, sys, tempfile
state = sys.argv[1]
sec = sys.argv[2] if sys.argv[2] in ("left", "center", "right") else "right"
ID = "io.github.weedwhitesandwine.japanquake"
p = os.path.expanduser("~/.config/omarchy/shell.json")
# This is somebody else's file and it is read back before being rewritten, so
# it gets the same treatment as everything else the plugin reads: the ceiling
# goes at the read, and the extra byte is what identifies an over-sized file.
# Refusing means leaving shell.json exactly as it was, which is the right
# answer anyway — a file this process cannot make sense of is not one it
# should be rewriting. The open refuses symlinks and non-regular files, so a
# planted link cannot redirect the read and a FIFO cannot block it forever.
MAX_SHELL_JSON = 4 * 1024 * 1024
try:
    fd = os.open(p, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            sys.exit(0)
        with os.fdopen(fd, "rb") as f:
            fd = None
            raw = f.read(MAX_SHELL_JSON + 1)
    finally:
        if fd is not None:
            os.close(fd)
    if len(raw) > MAX_SHELL_JSON:
        sys.exit(0)
    cfg = json.loads(raw.decode("utf-8", "replace"))
except SystemExit:
    raise
except Exception:
    sys.exit(0)
# Valid JSON of the wrong shape is not a config file. Each level is checked
# before it is used, because setdefault happily hands back a string.
if not isinstance(cfg, dict):
    sys.exit(0)

if not isinstance(cfg.get("bar"), dict):
    cfg["bar"] = {}
bar = cfg["bar"]
if not isinstance(bar.get("layout"), dict):
    bar["layout"] = {}
layout = bar["layout"]
if not isinstance(cfg.get("plugins"), list):
    cfg["plugins"] = []
plugins = cfg["plugins"]

def drop(seq):
    return [e for e in seq if not (isinstance(e, dict) and e.get("id") == ID)]

entry = None
for key in ("left", "center", "right"):
    section = layout.get(key)
    if not isinstance(section, list):
        continue
    for e in section:
        if isinstance(e, dict) and e.get("id") == ID:
            entry = e
    layout[key] = drop(section)
for e in plugins:
    if isinstance(e, dict) and e.get("id") == ID:
        entry = e
cfg["plugins"] = drop(plugins)

if entry is None:
    entry = {"id": ID}

if state == "on":
    layout.setdefault(sec, [])
    layout[sec].append(entry)
else:
    cfg["plugins"].append(entry)

# The replacement is staged under an unpredictable name created exclusively
# by mkstemp — which never follows a symlink — in a directory verified to be
# owned by us and writable by nobody else, then renamed over the destination
# in one step. A predictable name here would let a pre-planted symlink turn
# this write into the truncation of whatever the link pointed at.
d = os.path.dirname(p)
try:
    st = os.stat(d)
    if st.st_uid != os.getuid() or (st.st_mode & 0o022):
        sys.exit(0)
except OSError:
    sys.exit(0)
fd, tmp = tempfile.mkstemp(prefix=".shell.json.", suffix=".tmp", dir=d)
try:
    with os.fdopen(fd, "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
    try:
        os.chmod(tmp, os.stat(p).st_mode & 0o777)
    except OSError:
        pass
    os.replace(tmp, p)
except BaseException:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
PY
    ;;
  *)
    echo "usage: japanquake-ctl.sh bind <keys> | unbind | bar on|off [section]" >&2
    exit 2
    ;;
esac
