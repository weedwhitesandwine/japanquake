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
    tmp=$(mktemp)
    strip_block > "$tmp"
    {
      echo ""
      echo "$MARK_IN"
      printf 'o.bind("%s", "Japan Quake Monitor (earthquake map)", "omarchy-shell shell toggle %s")\n' "$key" "$ID"
      echo "$MARK_OUT"
    } >> "$tmp"
    mv "$tmp" "$BIND_FILE"
    hyprctl reload >/dev/null 2>&1 || true
    ;;
  unbind)
    [[ -f $BIND_FILE ]] || exit 0
    tmp=$(mktemp)
    strip_block > "$tmp"
    mv "$tmp" "$BIND_FILE"
    hyprctl reload >/dev/null 2>&1 || true
    ;;
  bar)
    # bar on [left|center|right] | bar off
    # The icon is visible when Japan Quake Monitor's entry lives in the bar layout of
    # shell.json; hidden (but the plugin still enabled) when the entry lives
    # in the plugins list instead. The shell hot-reloads the file.
    python3 - "$2" "${3:-right}" <<'PY'
import json, os, sys
state = sys.argv[1]
sec = sys.argv[2] if sys.argv[2] in ("left", "center", "right") else "right"
ID = "io.github.weedwhitesandwine.japanquake"
p = os.path.expanduser("~/.config/omarchy/shell.json")
try:
    with open(p) as f:
        cfg = json.load(f)
except Exception:
    sys.exit(0)

bar = cfg.setdefault("bar", {})
layout = bar.setdefault("layout", {})
plugins = cfg.setdefault("plugins", [])

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

tmp = p + ".japanquake.tmp"
with open(tmp, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
os.replace(tmp, p)
PY
    ;;
  *)
    echo "usage: japanquake-ctl.sh bind <keys> | unbind | bar on|off [section]" >&2
    exit 2
    ;;
esac
