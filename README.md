# Namazu 鯰

**Japanese earthquakes, on a map of Japan, with a pop-up when one happens.**

![Namazu](preview.png)

Named for the giant catfish of Edo folklore that thrashes underground and shakes
the islands whenever the god meant to be pinning it down looks away.

Japan records around a dozen earthquakes a day and most of them nobody feels, so
the interesting question is never "did one happen" but "was that one worth
knowing about". Namazu answers it: every quake lands on the map and in the list,
and only the ones above a threshold you choose take over the screen.

## What it shows

The map plots each epicentre as a disc, sized by magnitude and coloured by
**shindo** — Japan's seismic intensity scale. Shindo is not magnitude. Magnitude
describes the earthquake; shindo describes what it did to a particular place,
and it is the number people in Japan actually react to. It runs from 1 to 7,
with 5 and 6 each split into a weak and a strong band, and Namazu uses the same
colours for it that Japanese broadcasters do.

The most recent quake pulses. Selecting any quake — by clicking it or with the
arrow keys — shows the epicentre in both Japanese and English, the magnitude,
the depth, the tsunami status, and how far it was from Tokyo and in which
direction.

The bar icon shows the intensity of the latest quake as a coloured number, so
one glance is enough.

## Early warnings

Optional, and off is a perfectly reasonable choice.

**Confirmed reports** are JMA's 震源・震度情報. They arrive a couple of minutes
after a quake and they are never wrong.

**Early warnings** are 緊急地震速報. They arrive *seconds before* the shaking
does, which is the entire point of them, and they are forecasts: sometimes
overstated, occasionally cancelled outright a moment later. Namazu draws them as
a cross rather than a disc so they are never mistaken for something confirmed,
and labels them as forecasts.

Because a warning that arrives after the shaking is worthless, early warnings
need a connection held open rather than a feed checked periodically. Switching
them off in the settings closes that connection, and Namazu then only polls for
confirmed reports.

## Install

```
omarchy plugin add https://github.com/weedwhitesandwine/namazu.git --enable
```

The first time it opens it shows the settings, so you can choose your threshold
and give it a hotkey. Until you do, you can open it from a terminal:

```
omarchy-shell shell toggle io.github.weedwhitesandwine.namazu
```

## Update

```
omarchy plugin update io.github.weedwhitesandwine.namazu --yes
```

## Remove

Turn the hotkey and the bar icon off in the settings first — that removes
Namazu's marked block from `bindings.lua` and its entry from the bar — then:

```
omarchy plugin remove io.github.weedwhitesandwine.namazu
```

The only thing left behind is `~/.local/state/namazu/`, which you can delete.

## What it runs, reads and writes

**Network.** Namazu contacts two hosts, and reads from both — it never sends
anything but the request itself.

| Host | What for | When |
|---|---|---|
| `api.p2pquake.net` | Confirmed reports (JMA code 551) over HTTPS | Every 30 seconds |
| `api.p2pquake.net` | Early warnings (JMA code 556) over a WebSocket | Held open, only while early warnings are switched on |
| `www.jma.go.jp` | The English name for each epicentre, cached locally | Alongside each report poll |

**Background process.** One: `namazud.py`, started as a child of the shell with
`setpriv --pdeathsig TERM` so it cannot outlive the shell, and holding a lock
file so a second copy steps aside. It is what polls the feeds and holds the
early-warning connection. It uses nothing outside the Python standard library —
including its WebSocket client, which is written out longhand in that file so
there is no library to install and nothing hidden.

**Files it writes**, all inside its own state directory:

| Path | What |
|---|---|
| `~/.local/state/namazu/state.json` | The recent quakes and the latest warning |
| `~/.local/state/namazu/place-names.json` | Japanese → English epicentre names, cached |
| `~/.local/state/namazu/settings.json` | Your choices |
| `~/.local/state/namazu/namazud.lock` | So only one engine runs |

**Files it writes outside that directory** — only when you press **Apply** in
the settings, never on its own:

| Path | What |
|---|---|
| `~/.config/hypr/bindings.lua` | Only Namazu's own marked block, between `-- >>> namazu hotkey` and `-- <<< namazu hotkey`. Everything outside those two lines is copied through untouched |
| `~/.config/omarchy/shell.json` | Only Namazu's own `{"id": "io.github.weedwhitesandwine.namazu"}` entry, moved between the bar layout and the enabled-plugins list |

**Commands it runs:** `python3` (the engine, and the JSON edit inside the
helper), `bash` (the helper script and the settings write), and `hyprctl reload`
so a newly chosen hotkey takes effect.

## Data and attribution

- Earthquake data comes from the Japan Meteorological Agency, relayed by
  [P2P地震情報](https://www.p2pquake.net/). JMA is the source of every figure
  shown; Namazu adds nothing to it and interprets nothing.
- The coastline is [Natural Earth](https://www.naturalearthdata.com/) 1:50m
  Admin 0, which is in the public domain.

Namazu is a convenience for looking at published information. It is not an
emergency system, it is not operated by JMA, and it should not be the thing you
rely on in a real earthquake.

## Dependencies

`bash`, `python3` and `hyprctl`, all of which Omarchy already installs.

## Licence

MIT — see [LICENSE](LICENSE).

## Credits

Built with [Claude Code](https://claude.com/claude-code). The idea was my son's.
