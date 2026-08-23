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

# An opening marker whose terminator is missing used to swallow every line
# after it: `skip` is only cleared by the closing marker, so an unbalanced
# block ran to the end of the file and the rest of the user's keybindings were
# deleted without a word. A block that is not a matched, ordered pair is not a
# block this script understands.
# Where bindings.lua really lives. A dotfiles manager (stow, chezmoi) puts a
# symlink at ~/.config/hypr/bindings.lua pointing into its own repository;
# staging beside the LINK and renaming over it replaces the link with a plain
# file, orphaning the repo so every later apply stops reaching Hyprland — and a
# stage file on another filesystem turns the rename into a non-atomic copy.
# Resolving first means the write lands on the real file, in its own directory,
# and the link survives. Target and directory must both be the user's and
# writable by nobody else.
resolve_bind_file() {
  local real dir mode
  real=$(realpath -- "$BIND_FILE" 2>/dev/null) || return 1
  [[ -f $real ]] || return 1
  dir=$(dirname -- "$real")
  if [[ ! -O $real || ! -O $dir ]]; then
    echo "refusing to write $real — it is not yours" >&2
    return 1
  fi
  mode=$(stat -c %a -- "$dir" 2>/dev/null) || return 1
  if (( 8#$mode & 8#022 )); then
    echo "refusing to write into $dir — it is writable by others" >&2
    return 1
  fi
  printf '%s' "$real"
}

check_markers() {
  local opens closes o c
  opens=$(grep -c -- ">>> japanquake hotkey" "$BIND_FILE" || true)
  closes=$(grep -c -- "<<< japanquake hotkey" "$BIND_FILE" || true)
  if (( opens != closes )); then
    echo "japanquake-ctl: refusing to edit $BIND_FILE — its hotkey block is not a matched pair ($opens opening, $closes closing)" >&2
    return 1
  fi
  if (( opens > 1 )); then
    echo "japanquake-ctl: refusing to edit $BIND_FILE — $opens hotkey blocks, expected at most one" >&2
    return 1
  fi
  if (( opens == 1 )); then
    o=$(grep -n -- ">>> japanquake hotkey" "$BIND_FILE" | head -1 | cut -d: -f1)
    c=$(grep -n -- "<<< japanquake hotkey" "$BIND_FILE" | head -1 | cut -d: -f1)
    if (( c < o )); then
      echo "japanquake-ctl: refusing to edit $BIND_FILE — its hotkey block closes before it opens" >&2
      return 1
    fi
  fi
  return 0
}

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
    # The shape a hotkey may have, held in a variable because it contains
# spaces — and it must contain literal spaces, not [[:space:]], which
# also matches a newline and a tab. The settings card checks a literal
# space, so anything looser here is a gap between the two guards: a
# newline passed this check, was refused by that one, and reached
# bindings.lua as an unterminated Lua string that cost the user every
# keybinding in the file on the next reload.
KEY_SHAPE='^(SUPER|CTRL|ALT|SHIFT)( \+ (SUPER|CTRL|ALT|SHIFT))* \+ ([A-Z0-9]|F([1-9]|1[0-2])|SPACE|RETURN|ENTER|TAB|ESCAPE|BACKSPACE|DELETE|INSERT|HOME|END|PAGE_UP|PAGE_DOWN|UP|DOWN|LEFT|RIGHT|COMMA|PERIOD|SLASH|MINUS|EQUAL|SEMICOLON|APOSTROPHE|GRAVE|BRACKETLEFT|BRACKETRIGHT|BACKSLASH)$'
if ! [[ $key =~ $KEY_SHAPE ]]; then
      echo "japanquake-ctl: refusing hotkey that is not modifiers plus one key: $key" >&2
      exit 1
    fi
    # The replacement is staged in the same directory as bindings.lua and
    # renamed over it, so the swap is a single atomic step — staging it in
    # /tmp and mv-ing across filesystems degrades to a copy, which can leave
    # a half-written config if interrupted. mktemp creates the stage file
    # exclusively under a random name, so nothing can have been planted at it.
    REAL_BIND=$(resolve_bind_file) || exit 1
    tmp=$(mktemp "$REAL_BIND.XXXXXXXX")
    trap 'rm -f "$tmp"' EXIT
    check_markers || exit 1
    strip_block > "$tmp"
    {
      echo ""
      echo "$MARK_IN"
      printf 'o.bind("%s", "Japan Quake Monitor (earthquake map)", "omarchy-shell shell toggle %s")\n' "$key" "$ID"
      echo "$MARK_OUT"
    } >> "$tmp"
    chmod --reference="$REAL_BIND" "$tmp" 2>/dev/null || chmod 644 "$tmp"
    mv -f "$tmp" "$REAL_BIND"
    trap - EXIT
    hyprctl reload >/dev/null 2>&1 || true
    ;;
  unbind)
    [[ -f $BIND_FILE ]] || exit 0
    REAL_BIND=$(resolve_bind_file) || exit 1
    tmp=$(mktemp "$REAL_BIND.XXXXXXXX")
    trap 'rm -f "$tmp"' EXIT
    check_markers || exit 1
    strip_block > "$tmp"
    chmod --reference="$REAL_BIND" "$tmp" 2>/dev/null || chmod 644 "$tmp"
    mv -f "$tmp" "$REAL_BIND"
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
    # Every other level of this file is shape-checked before use; this was the
    # one that took whatever was there and appended to it. A section that is
    # not a list raises, the script dies under `set -e`, and because it runs
    # detached with stderr discarded the bar choice simply never happens —
    # while every other malformed shape is handled by leaving the file alone.
    if not isinstance(layout.get(sec), list):
        layout[sec] = []
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
