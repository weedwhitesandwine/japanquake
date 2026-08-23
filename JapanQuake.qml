import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick

import qs.Commons
import qs.Ui
import "Shindo.js" as Shindo
import "."

// Japan Quake Monitor — Japanese earthquakes, on a map of Japan.
//
// Two surfaces. The overlay is an ordinary focused panel you open deliberately:
// the map, the recent list, and the detail of whichever quake is selected. The
// alert is not — it appears unbidden while you are working, so it takes no
// keyboard focus and only its own card accepts a click. Nothing about it
// interrupts what you were typing.
Item {
  id: root

  // A file this plugin reads but does not own can be anything by the time it
  // is opened: a link pointing elsewhere, a pipe that never produces anything,
  // or something far too large. `head` opens a path the ordinary way and would
  // follow the first and wait forever on the second, inside a shell process
  // that stays up for days. So the open refuses on its own terms and hands
  // back nothing at all rather than something over the ceiling. O_NOFOLLOW
  // covers the final name only — a link in a parent directory is still
  // followed, which is the same trust already placed in the home directory.
  readonly property string safeRead: [
    'import os, stat, sys',
    'path = sys.argv[1]; ceiling = int(sys.argv[2])',
    'try:',
    '    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)',
    'except FileNotFoundError:',
    '    raise SystemExit(2)',
    'except OSError:',
    '    raise SystemExit(1)',
    'try:',
    '    if not stat.S_ISREG(os.fstat(fd).st_mode):',
    '        raise SystemExit(1)',
    '    with os.fdopen(fd, "rb") as handle:',
    '        fd = None',
    '        raw = handle.read(ceiling + 1)',
    'except OSError:',
    '    raise SystemExit(1)',
    'finally:',
    '    if fd is not None:',
    '        os.close(fd)',
    'if len(raw) > ceiling:',
    '    raise SystemExit(1)',
    'sys.stdout.buffer.write(raw)'
  ].join("
")

  property string home: Quickshell.env("HOME")
  readonly property string pluginDir: {
    var u = String(Qt.resolvedUrl("."))
    return decodeURIComponent(u.replace(/^file:\/\//, "")).replace(/\/$/, "")
  }
  readonly property string stateDir: root.home + "/.local/state/japanquake"

  // ------------------------------------------------------------------ theme
  property color foreground: Color.menu.text
  property color background: Color.menu.background
  property color border: Color.menu.border
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  readonly property int labelWidth: Style.space(190)

  // --------------------------------------------------------------- settings
  // Applying is the ONLY time Japan Quake Monitor writes outside its own state directory —
  // its marked hotkey block and its own bar entry, both via japanquake-ctl.sh.
  readonly property string settingsFile: root.stateDir + "/settings.json"
  property var nsettings: ({
    configured: false, threshold: "3", earlyWarning: true, sound: true,
    shortcut: "", barIcon: true, barSection: "right", lastSeenTime: "", lastEew: ""
  })

  property string draftThreshold: "3"
  property bool draftEarlyWarning: true
  property bool draftSound: true
  property string draftShortcut: ""
  property bool draftBarIcon: true
  property string draftBarSection: "right"
  property bool capturing: false
  property string captureNote: ""

  readonly property var thresholds: ["1", "2", "3", "4", "5-", "5+", "6-"]

  // ------------------------------------------------------------------ state
  property var quakes: []
  property var eew: null
  property bool eewConnected: false
  property string feedError: ""
  property int selectedIndex: 0

  readonly property var latest: root.quakes.length > 0 ? root.quakes[0] : null
  readonly property var selected: (root.selectedIndex >= 0 && root.selectedIndex < root.quakes.length)
    ? root.quakes[root.selectedIndex] : null

  // "view" is "map" normally, "settings" via the gear, "greeter" on first run.
  property string view: "map"
  property bool opened: false

  // ------------------------------------------------------------------ alert
  property var alertQuake: null
  property bool alertIsEew: false
  readonly property bool alertShown: root.alertQuake !== null

  function fmtDistance(q) {
    if (!q || q.distance === null || q.distance === undefined) return "—"
    return q.distance + " km " + (q.bearing || "") + " of Tokyo"
  }

  function fmtDepth(q) {
    if (!q || q.depth === null || q.depth === undefined) return "—"
    return q.depth === 0 ? "very shallow" : q.depth + " km deep"
  }

  function fmtMagnitude(q) {
    return (q && q.magnitude !== null && q.magnitude !== undefined) ? "M" + q.magnitude : "M—"
  }

  function placeOf(q) {
    if (!q) return ""
    if (q.placeEn && q.place) return q.placeEn
    return q.place || q.placeEn || "epicentre not yet determined"
  }

  // pw-play is PipeWire's own player, which Omarchy already runs. The sounds
  // are plain generated tones that live in the plugin directory; the script
  // that made them sits beside them.
  function playSound(isEew) {
    if (root.nsettings.sound === false) return
    Quickshell.execDetached(["pw-play",
      root.pluginDir + (isEew ? "/sounds/warning.wav" : "/sounds/report.wav")])
  }

  function showAlert(q, isEew) {
    root.alertQuake = q
    root.alertIsEew = isEew === true
    root.playSound(root.alertIsEew)
    alertTimer.restart()
  }

  function dismissAlert() {
    root.alertQuake = null
    alertTimer.stop()
  }

  // A new confirmed report, or a new early warning, decides whether to
  // interrupt. Everything quieter than the chosen threshold still lands on the
  // map and in the list — it simply does not take over the screen.
  // Keyed on the quake's time, not the bulletin's id. JMA issues one
  // earthquake in instalments and the engine folds them into whichever
  // bulletin is fullest — which means the id CHANGES as the fuller reports
  // arrive, so "have I shown this?" never matched and the same quake
  // interrupted two to four times, chime and all. The time is the merge key
  // and is the one thing every instalment agrees on.
  function considerReport() {
    if (!root.latest || !root.latest.time) return
    if (root.latest.time === root.nsettings.lastSeenTime) return
    var firstEver = !root.nsettings.lastSeenTime
    var s = root.nsettings
    s.lastSeenTime = root.latest.time
    root.nsettings = s
    root.saveSettings()
    // On the very first run there is always a "latest" quake, hours old.
    // Announcing it would be a lie about something just having happened.
    if (firstEver) return
    if (Shindo.rank(root.latest.shindo) >= Shindo.rank(root.chosenThreshold))
      root.showAlert(root.latest, false)
  }

  // An early warning is only news while it is happening. The stored one
  // outlives the shell, so without this a warning from days ago announces
  // itself — with the urgent chime — on any start where the settings have not
  // been read yet. The confirmed-report path has always had this guard; the
  // warning path, which is the louder of the two, did not.
  readonly property int eewMaxAgeSeconds: 180

  // A threshold the scale does not contain ranks as zero, which would let
  // every tremor — and every bulletin with no intensity at all — take over the
  // screen with a chime. A hand-edited "5" rather than the "5-"/"5+" the UI
  // writes was enough to do it.
  readonly property string chosenThreshold: {
    var t = root.nsettings.threshold
    return (typeof t === "string" && Shindo.rank(t) > 0) ? t : "3"
  }

  function considerEew() {
    if (!root.eew || !root.eew.id) return
    if (root.nsettings.earlyWarning === false) return
    if (root.eew.test) return
    if (root.eew.id === root.nsettings.lastEew) return
    var s = root.nsettings
    s.lastEew = root.eew.id
    root.nsettings = s
    root.saveSettings()
    var age = (Date.now() / 1000) - (root.eew.at || 0)
    if (!root.eew.at || age > root.eewMaxAgeSeconds) return
    // A cancellation is worth showing only if we showed the warning it cancels.
    if (root.eew.cancelled && !root.alertIsEew) return
    root.showAlert(root.eew, true)
  }

  Timer {
    id: alertTimer
    interval: root.alertIsEew ? 60000 : 25000
    onTriggered: root.dismissAlert()
  }

  // --------------------------------------------------------------- lifecycle
  function open(payloadJson) {
    var payload = {}
    try { if (payloadJson) payload = JSON.parse(payloadJson) || {} } catch (e) {}
    if (payload.view === "settings" || root.nsettings.configured !== true) {
      root.syncDrafts()
      root.view = root.nsettings.configured === true ? "settings" : "greeter"
    } else {
      root.view = "map"
    }
    root.opened = true
  }

  function close() { root.opened = false; root.capturing = false }

  Component.onCompleted: {
    JapanQuakeState.overlay = root
    root.readSettings()
    root.readState()
  }

  // ------------------------------------------------------------ persistence
  // state.json and settings.json load independently, and the quake state
  // usually wins the race. Recording "I have seen this quake" then persisted
  // the not-yet-loaded defaults straight over the user's real settings, which
  // is how a chosen threshold could silently revert. Nothing is written until
  // the settings themselves have been read at least once.
  property bool settingsLoaded: false

  // Written to an exclusively-created temporary name beside the file and
  // renamed over it: a bare `>` redirection truncates whatever already sits
  // at that path — including the target of a symlink a restored backup could
  // have left there — before the new content lands. `-O` confirms the state
  // directory is ours before anything is staged in it.
  function saveSettings() {
    if (!root.settingsLoaded) return
    Quickshell.execDetached(["bash", "-c",
      'd=$(dirname "$2") && mkdir -p "$d" && [ -O "$d" ] && t=$(mktemp "$2.XXXXXXXX") && printf "%s\\n" "$1" > "$t" && mv -f "$t" "$2"', "--",
      JSON.stringify(root.nsettings), root.settingsFile])
  }

  function syncDrafts() {
    root.draftThreshold = root.nsettings.threshold || "3"
    root.draftEarlyWarning = root.nsettings.earlyWarning !== false
    root.draftSound = root.nsettings.sound !== false
    root.draftShortcut = root.validShortcut(root.nsettings.shortcut) ? root.nsettings.shortcut : ""
    root.draftBarIcon = root.nsettings.barIcon !== false
    root.draftBarSection = root.nsettings.barSection || "right"
    root.capturing = false
    root.captureNote = ""
  }

  function applyDrafts() {
    var s = {
      configured: true,
      threshold: root.draftThreshold,
      earlyWarning: root.draftEarlyWarning,
      sound: root.draftSound,
      shortcut: root.validShortcut(root.draftShortcut) ? root.draftShortcut : "",
      barIcon: root.draftBarIcon,
      barSection: root.draftBarSection,
      lastSeenTime: root.nsettings.lastSeenTime || "",
      lastEew: root.nsettings.lastEew || ""
    }
    root.nsettings = s
    root.saveSettings()
    Quickshell.execDetached(["bash", root.pluginDir + "/japanquake-ctl.sh", "bar",
                             s.barIcon ? "on" : "off", s.barSection])
    if (root.validShortcut(s.shortcut))
      Quickshell.execDetached(["bash", root.pluginDir + "/japanquake-ctl.sh", "bind", s.shortcut])
    else
      Quickshell.execDetached(["bash", root.pluginDir + "/japanquake-ctl.sh", "unbind"])
    root.view = "map"
  }

  // A hotkey is a fixed shape: one or more modifiers, then one key. Anything
  // else is not a hotkey, and since this value is written into bindings.lua as
  // Lua source, "anything else" has to mean rejected rather than escaped.
  readonly property var shortcutPattern:
    /^(SUPER|CTRL|ALT|SHIFT)( \+ (SUPER|CTRL|ALT|SHIFT))* \+ ([A-Z0-9]|F([1-9]|1[0-2])|SPACE|RETURN|ENTER|TAB|ESCAPE|BACKSPACE|DELETE|INSERT|HOME|END|PAGE_UP|PAGE_DOWN|UP|DOWN|LEFT|RIGHT|COMMA|PERIOD|SLASH|MINUS|EQUAL|SEMICOLON|APOSTROPHE|GRAVE|BRACKETLEFT|BRACKETRIGHT|BACKSLASH)$/

  function validShortcut(s) {
    return typeof s === "string" && s.length <= 40 && root.shortcutPattern.test(s)
  }

  function captureKey(event) {
    if (event.key === Qt.Key_Escape) { root.capturing = false; root.captureNote = ""; return }
    var mods = []
    if (event.modifiers & Qt.MetaModifier) mods.push("SUPER")
    if (event.modifiers & Qt.ControlModifier) mods.push("CTRL")
    if (event.modifiers & Qt.AltModifier) mods.push("ALT")
    if (event.modifiers & Qt.ShiftModifier) mods.push("SHIFT")
    var name = ""
    if (event.key >= Qt.Key_A && event.key <= Qt.Key_Z) name = String.fromCharCode(65 + (event.key - Qt.Key_A))
    else if (event.key >= Qt.Key_0 && event.key <= Qt.Key_9) name = String.fromCharCode(48 + (event.key - Qt.Key_0))
    else if (event.key >= Qt.Key_F1 && event.key <= Qt.Key_F12) name = "F" + (event.key - Qt.Key_F1 + 1)
    if (name === "") return
    // Shift on its own does not qualify — the guidance already says so, but
    // only "no modifier at all" was refused, so SHIFT + A bound capital A
    // globally and typing one anywhere opened the overlay.
    if (mods.length === 1 && mods[0] === "SHIFT") {
      root.captureNote = "Shift on its own is not enough — hold SUPER, CTRL or ALT too"
      return
    }
    if (mods.length === 0) { root.captureNote = "Add a modifier — SUPER, CTRL or ALT"; return }
    root.draftShortcut = mods.join(" + ") + " + " + name
    root.captureNote = ""
    root.capturing = false
  }

  // Settings are a handful of short values; the state file is a few hundred
  // quakes at most. Both are written by the engine, but they sit on disk, where
  // a restored backup or anything else could have put something quite different
  // — and this shell stays up for days, so a file it reads is a file it has to
  // hold. Reading them through `head` puts the ceiling before the read rather
  // than after it: whatever is on disk, the shell is handed at most this many
  // bytes. Anything larger arrives cut off, fails to parse, and is refused,
  // leaving the last good values in place.
  readonly property int settingsCeiling: 16 * 1024
  readonly property int stateCeiling: 4 * 1024 * 1024

  // The watchers read nothing themselves. blockAllReads keeps the file out of
  // the shell's memory altogether, leaving them the one job we actually want
  // from them: saying that something changed.
  FileView {
    path: root.settingsFile
    printErrors: false
    watchChanges: true
    blockAllReads: true
    preload: false
    onFileChanged: root.readSettings()
  }

  FileView {
    path: root.stateDir + "/state.json"
    printErrors: false
    watchChanges: true
    blockAllReads: true
    preload: false
    onFileChanged: root.readState()
  }

  function readSettings() {
    settingsReader.running = false
    settingsReader.running = true
  }

  function readState() {
    stateReader.running = false
    stateReader.running = true
  }

  Process {
    id: settingsReader
    command: ["python3", "-c", root.safeRead,
              root.settingsFile, String(root.settingsCeiling)]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var s = JSON.parse(text)
          if (s && typeof s === "object" && !Array.isArray(s)) root.nsettings = s
        } catch (e) {}
      }
    }
    // No settings file yet is a perfectly good answer: it means first run, and
    // the defaults in memory are the truth. Either way the answer is in, and
    // settings may now be written back.
    onExited: root.settingsLoaded = true
  }

  Process {
    id: stateReader
    command: ["python3", "-c", root.safeRead,
              root.stateDir + "/state.json", String(root.stateCeiling)]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var s = JSON.parse(text)
          if (!s || typeof s !== "object" || Array.isArray(s)) return
          root.quakes = Array.isArray(s.quakes) ? s.quakes.slice(0, 200) : []
          root.eew = s.eew || null
          root.eewConnected = s.eewConnected === true
          root.feedError = s.error || ""
          if (root.selectedIndex >= root.quakes.length) root.selectedIndex = 0
          root.considerReport()
          root.considerEew()
        } catch (e) {}
      }
    }
  }

  // The engine. A child of the shell so its life matches the shell's, with
  // pdeathsig so it can never be orphaned, and a lock file so a second copy
  // steps aside rather than fighting for the socket.
  Process {
    id: daemon
    command: ["setpriv", "--pdeathsig", "TERM",
              "python3", root.pluginDir + "/japanquaked.py", "daemon"]
    running: true
    // Exit 0 is the engine choosing to stop — most often because another
    // shell instance already holds the lock and this copy stepped aside.
    // Restarting it then spawns a Python process every ten seconds for as
    // long as both shells are up. Only a failure is worth retrying.
    onExited: function(code) { if (code !== 0) daemonRestart.restart() }
  }

  Timer {
    id: daemonRestart
    interval: 10000
    onTriggered: daemon.running = true
  }

  Process {
    id: refreshProc
    command: ["python3", root.pluginDir + "/japanquaked.py", "once"]
    onExited: root.readState()
  }

  function refresh() { refreshProc.running = false; refreshProc.running = true }

  // ------------------------------------------------------------- components
  component SettingLabel: Text {
    textFormat: Text.PlainText
    width: root.labelWidth
    anchors.verticalCenter: parent.verticalCenter
    color: root.foreground
    opacity: 0.75
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    elide: Text.ElideRight
  }

  component SettingPill: Rectangle {
    id: pill
    property string label
    property bool active: false
    signal picked()
    width: pillLabel.width + Style.spacing.lg * 2
    height: Style.space(32)
    radius: root.cornerRadius
    color: pill.active ? root.selectedBackground : "transparent"
    border.color: pill.active ? root.foreground : root.border
    border.width: pill.active ? 1 : 0

    Text {
      textFormat: Text.PlainText
      id: pillLabel
      anchors.centerIn: parent
      text: pill.label
      color: pill.active ? root.selectedText : root.foreground
      opacity: pill.active ? 1 : 0.55
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: pill.picked()
    }
  }

  component DataLink: Text {
    textFormat: Text.PlainText
    property string url: ""
    color: "#93c5fd"
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.underline: linkArea.containsMouse
    MouseArea {
      id: linkArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: Quickshell.execDetached(["xdg-open", parent.url])
    }
  }

  component ShindoBadge: Rectangle {
    property string shindo: ""
    property real size: Style.space(40)
    width: size; height: size
    radius: Style.space(6)
    color: Shindo.color(shindo)
    Text {
      textFormat: Text.PlainText
      anchors.centerIn: parent
      text: parent.shindo || "?"
      color: "#ffffff"
      font.family: root.fontFamily
      font.pixelSize: parent.size * 0.5
      font.bold: true
    }
  }

  // ---------------------------------------------------------- the alert
  // Appears unbidden, so it must not steal focus or swallow a click meant for
  // the window underneath: no keyboard focus, and the input region is limited
  // to the card itself.
  PanelWindow {
    id: alertPanel
    visible: root.alertShown
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "japanquake-alert"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    mask: Region { item: alertCard }

    BorderSurface {
      id: alertCard
      width: Style.space(400)
      height: alertBody.implicitHeight + alertCard.contentTopInset + alertCard.contentBottomInset
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.topMargin: Style.space(46)
      anchors.rightMargin: Style.gapsOut
      color: root.background
      radius: root.cornerRadius
      padding: Style.space(18)
      borderSpec: Border.surfaceSpec("menu", "border",
        root.alertIsEew ? Color.urgent : Shindo.color(root.alertQuake ? root.alertQuake.shindo : ""),
        Math.max(2, Style.space(3)))

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: { root.dismissAlert(); root.view = "map"; root.opened = true }
      }

      Column {
        id: alertBody
        anchors.fill: parent
        anchors.topMargin: alertCard.contentTopInset
        anchors.rightMargin: alertCard.contentRightInset
        anchors.bottomMargin: alertCard.contentBottomInset
        anchors.leftMargin: alertCard.contentLeftInset
        spacing: Style.spacing.md

        Row {
          width: parent.width
          spacing: Style.spacing.md

          ShindoBadge {
            visible: !root.alertIsEew
            shindo: root.alertQuake ? (root.alertQuake.shindo || "?") : ""
            size: Style.space(46)
          }

          Rectangle {
            visible: root.alertIsEew
            width: Style.space(46); height: width
            radius: Style.space(6)
            color: Color.urgent
            Text {
              textFormat: Text.PlainText
              anchors.centerIn: parent
              text: "!"
              color: "#ffffff"
              font.family: root.fontFamily
              font.pixelSize: Style.space(30)
              font.bold: true
            }
          }

          Column {
            width: parent.width - Style.space(46) - Style.spacing.md
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.alertIsEew
                ? (root.alertQuake && root.alertQuake.cancelled
                    ? "Early warning cancelled" : "Earthquake early warning")
                : "Earthquake · shindo " + (root.alertQuake ? root.alertQuake.shindo : "")
              color: root.alertIsEew ? Color.urgent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.alertIsEew
                ? "Shaking may arrive shortly — this is a forecast, not a measurement"
                : Shindo.meaning(root.alertQuake ? root.alertQuake.shindo : "")
              color: root.foreground
              opacity: 0.7
              wrapMode: Text.WordWrap
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: root.placeOf(root.alertQuake)
          color: root.foreground
          wrapMode: Text.WordWrap
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: root.alertQuake && root.alertQuake.place && root.alertQuake.placeEn
          text: root.alertQuake ? (root.alertQuake.place || "") : ""
          color: root.foreground
          opacity: 0.6
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: root.fmtMagnitude(root.alertQuake) + " · " + root.fmtDepth(root.alertQuake)
                + " · " + root.fmtDistance(root.alertQuake)
          color: root.foreground
          opacity: 0.8
          wrapMode: Text.WordWrap
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: !root.alertIsEew && root.alertQuake
                   && root.alertQuake.tsunami !== "none" && root.alertQuake.tsunami !== "unknown"
          text: "Tsunami: " + (root.alertQuake ? root.alertQuake.tsunami : "")
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }

        Row {
          spacing: Style.spacing.md
          SettingPill {
            label: "map"
            active: true
            onPicked: { root.dismissAlert(); root.view = "map"; root.opened = true }
          }
          SettingPill {
            label: "dismiss"
            onPicked: root.dismissAlert()
          }
        }
      }
    }
  }

  // --------------------------------------------------------- the overlay
  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "japanquake"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: root.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.close() }

    BorderSurface {
      id: card
      width: Math.min(Style.space(980), panel.width - Style.gapsOut * 2)
      height: Math.min(Style.space(640), panel.height - Style.gapsOut * 2)
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      radius: root.cornerRadius
      padding: Style.space(20)

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (root.capturing) { root.captureKey(event); event.accepted = true; return }
          if (root.view !== "map") {
            if (event.key === Qt.Key_Escape) root.view = "map"
            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) root.applyDrafts()
            event.accepted = true
            return
          }
          if (event.key === Qt.Key_Escape) root.close()
          else if (event.key === Qt.Key_Down) root.selectedIndex = Math.min(root.quakes.length - 1, root.selectedIndex + 1)
          else if (event.key === Qt.Key_Up) root.selectedIndex = Math.max(0, root.selectedIndex - 1)
          else if (event.key === Qt.Key_R) root.refresh()
          else if (event.key === Qt.Key_Comma && (event.modifiers & Qt.ControlModifier)) {
            root.syncDrafts(); root.view = "settings"
          }
          event.accepted = true
        }

        // ---------------------------------------------------------- header
        Item {
          id: header
          width: parent.width
          height: Style.space(34)

          Text {
            textFormat: Text.PlainText
            id: title
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.view === "greeter" ? "震 welcome to Japan Quake Monitor"
                : root.view === "settings" ? "Japan Quake Monitor settings" : "震 Japan Quake Monitor"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
          }

          Text {
            textFormat: Text.PlainText
            anchors.left: title.right
            anchors.leftMargin: Style.spacing.lg
            anchors.verticalCenter: parent.verticalCenter
            visible: root.view === "map"
            text: root.feedError !== "" ? "feed unreachable"
                : (root.nsettings.earlyWarning === false ? "early warnings off"
                   : (root.eewConnected ? "early warnings live" : "early warnings connecting…"))
            color: root.feedError !== "" ? Color.urgent : root.foreground
            opacity: 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.md
            visible: root.view === "map"

            SettingPill { label: "refresh"; onPicked: root.refresh() }
            SettingPill {
              label: "settings"
              active: true
              onPicked: { root.syncDrafts(); root.view = "settings" }
            }
          }
        }

        // ------------------------------------------------------- map view
        Item {
          anchors.top: header.bottom
          anchors.topMargin: Style.spacing.lg
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          visible: root.view === "map"

          JapanMap {
            id: mapView
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: parent.width * 0.52
            quakes: root.quakes
            eew: root.eew
            selectedIndex: root.selectedIndex
            land: root.foreground
          }

          Column {
            anchors.left: mapView.right
            anchors.leftMargin: Style.spacing.xl
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            spacing: Style.spacing.md

            // Detail of whichever quake is selected.
            Row {
              width: parent.width
              spacing: Style.spacing.lg
              visible: root.selected !== null

              ShindoBadge {
                shindo: root.selected ? (root.selected.shindo || "?") : ""
                size: Style.space(52)
              }

              Column {
                width: parent.width - Style.space(52) - Style.spacing.lg
                spacing: Style.space(2)

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: root.placeOf(root.selected)
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  wrapMode: Text.WordWrap
                }
                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  visible: root.selected && root.selected.place && root.selected.placeEn
                  text: root.selected ? (root.selected.place || "") : ""
                  color: root.foreground
                  opacity: 0.6
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: root.selected ? (root.selected.time || "") : ""
                  color: root.foreground
                  opacity: 0.7
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: root.fmtMagnitude(root.selected) + " · " + root.fmtDepth(root.selected)
                  color: root.foreground
                  opacity: 0.85
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: root.fmtDistance(root.selected)
                  color: root.foreground
                  opacity: 0.85
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  text: Shindo.meaning(root.selected ? root.selected.shindo : "")
                  color: root.foreground
                  opacity: 0.6
                  wrapMode: Text.WordWrap
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  visible: root.selected && root.selected.tsunami !== "none"
                           && root.selected.tsunami !== "unknown"
                  text: "Tsunami: " + (root.selected ? root.selected.tsunami : "")
                  color: Color.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }
            }

            Rectangle {
              width: parent.width
              height: 1
              color: root.border
              opacity: 0.4
            }

            // The recent list.
            ListView {
              id: list
              width: parent.width
              height: parent.height - y
              clip: true
              model: root.quakes
              currentIndex: root.selectedIndex
              spacing: Style.space(2)

              delegate: Rectangle {
                required property var modelData
                required property int index
                width: list.width
                height: Style.space(34)
                radius: root.cornerRadius
                color: index === root.selectedIndex ? root.selectedBackground : "transparent"

                Row {
                  anchors.fill: parent
                  anchors.leftMargin: Style.spacing.md
                  anchors.rightMargin: Style.spacing.md
                  spacing: Style.spacing.md

                  ShindoBadge {
                    anchors.verticalCenter: parent.verticalCenter
                    shindo: modelData.shindo || "?"
                    size: Style.space(22)
                  }

                  Text {
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - Style.space(22) - Style.space(120)
                    text: root.placeOf(modelData)
                    color: root.foreground
                    opacity: index === root.selectedIndex ? 1 : 0.8
                    elide: Text.ElideRight
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }

                  Text {
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                    text: (modelData.time || "").slice(5, 16)
                    color: root.foreground
                    opacity: 0.55
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.selectedIndex = index
                }
              }
            }
          }
        }

        // -------------------------------------------------- settings view
        Item {
          anchors.top: header.bottom
          anchors.topMargin: Style.spacing.xl
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          visible: root.view !== "map"

          Column {
            width: parent.width
            spacing: Style.spacing.xl

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: root.view === "greeter"
              wrapMode: Text.WordWrap
              text: "Japan records around a dozen earthquakes a day, and most of them nobody feels. Choose how strong one has to be before Japan Quake Monitor interrupts you — everything quieter still appears on the map."
              color: root.foreground
              opacity: 0.75
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Row {
              spacing: Style.spacing.md
              SettingLabel { text: "Interrupt me from shindo" }
              Row {
                spacing: Style.space(4)
                Repeater {
                  model: root.thresholds
                  SettingPill {
                    required property var modelData
                    label: modelData
                    active: root.draftThreshold === modelData
                    onPicked: root.draftThreshold = modelData
                  }
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              wrapMode: Text.WordWrap
              text: {
                var t = root.draftThreshold
                var note = Shindo.meaning(t)
                var rate = t === "1" ? "about twelve a day"
                  : t === "2" ? "about four or five a day"
                  : t === "3" ? "about two or three a day"
                  : t === "4" ? "roughly one every few days"
                  : "rare — a handful a year"
                return "Shindo " + t + ": " + note + ". Expect " + rate + "."
              }
              color: root.foreground
              opacity: 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Row {
              spacing: Style.spacing.md
              SettingLabel { text: "Early warnings" }
              Row {
                spacing: Style.space(4)
                SettingPill {
                  label: "on"
                  active: root.draftEarlyWarning
                  onPicked: root.draftEarlyWarning = true
                }
                SettingPill {
                  label: "off"
                  active: !root.draftEarlyWarning
                  onPicked: root.draftEarlyWarning = false
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              wrapMode: Text.WordWrap
              text: root.draftEarlyWarning
                ? "緊急地震速報 — warnings that arrive seconds before the shaking, rather than minutes after. They are forecasts: occasionally overstated, and sometimes cancelled outright. Keeping them on holds one network connection open."
                : "Off. Japan Quake Monitor will only ever show confirmed reports, which arrive a couple of minutes after a quake and are never wrong. No connection is held open."
              color: root.foreground
              opacity: 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Row {
              spacing: Style.spacing.md
              SettingLabel { text: "Alert sound" }
              Row {
                spacing: Style.space(4)
                SettingPill {
                  label: "on"
                  active: root.draftSound
                  onPicked: { root.draftSound = true }
                }
                SettingPill {
                  label: "off"
                  active: !root.draftSound
                  onPicked: root.draftSound = false
                }
                SettingPill {
                  label: "hear report"
                  onPicked: Quickshell.execDetached(["pw-play", root.pluginDir + "/sounds/report.wav"])
                }
                SettingPill {
                  label: "hear warning"
                  onPicked: Quickshell.execDetached(["pw-play", root.pluginDir + "/sounds/warning.wav"])
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              wrapMode: Text.WordWrap
              text: "A short chime when a quake passes your threshold, and a more insistent one for an early warning — different on purpose, because they mean different things. The two buttons play them now."
              color: root.foreground
              opacity: 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Row {
              width: parent.width
              spacing: Style.spacing.md
              SettingLabel { text: "Hotkey" }
              Rectangle {
                width: Style.space(210)
                height: Style.space(32)
                radius: root.cornerRadius
                color: "transparent"
                border.color: root.border
                border.width: 1
                Text {
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  text: root.capturing ? "press your keys…"
                    : (root.draftShortcut !== "" ? root.draftShortcut : "none set")
                  color: root.foreground
                  opacity: root.capturing || root.draftShortcut === "" ? 0.6 : 1
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
              }
              SettingPill {
                label: root.capturing ? "cancel" : "record"
                active: true
                onPicked: { root.capturing = !root.capturing; root.captureNote = "" }
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: root.captureNote !== ""
              text: root.captureNote
              color: root.foreground
              opacity: 0.6
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Row {
              spacing: Style.spacing.md
              SettingLabel { text: "Bar icon" }
              Row {
                spacing: Style.space(4)
                SettingPill { label: "show"; active: root.draftBarIcon; onPicked: root.draftBarIcon = true }
                SettingPill { label: "hide"; active: !root.draftBarIcon; onPicked: root.draftBarIcon = false }
              }
            }

            Row {
              spacing: Style.spacing.md
              visible: root.draftBarIcon
              SettingLabel { text: "Bar position" }
              Row {
                spacing: Style.space(4)
                SettingPill { label: "left"; active: root.draftBarSection === "left"; onPicked: root.draftBarSection = "left" }
                SettingPill { label: "center"; active: root.draftBarSection === "center"; onPicked: root.draftBarSection = "center" }
                SettingPill { label: "right"; active: root.draftBarSection === "right"; onPicked: root.draftBarSection = "right" }
              }
            }

            Rectangle { width: parent.width; height: 1; color: root.border; opacity: 0.35 }

            Column {
              width: parent.width
              spacing: Style.space(3)

              Text {
                textFormat: Text.PlainText
                width: parent.width
                wrapMode: Text.WordWrap
                text: "Every figure shown here comes from the Japan Meteorological Agency. This plugin measures nothing itself — check JMA directly for anything that matters."
                color: root.foreground
                opacity: 0.75
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              DataLink {
                text: "気象庁 JMA — earthquake information (English)"
                url: "https://www.data.jma.go.jp/multi/quake/index.html?lang=en"
              }

              DataLink {
                text: "気象庁 JMA — live map (Japanese)"
                url: "https://www.jma.go.jp/bosai/map.html#contents=earthquake_map"
              }

              DataLink {
                text: "P2P地震情報 — the relay this plugin reads"
                url: "https://www.p2pquake.net/"
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              wrapMode: Text.WordWrap
              text: "Applying saves these choices, updates Japan Quake Monitor's own marked hotkey block in bindings.lua, and adds or removes its bar icon. Nothing else is touched."
              color: root.foreground
              opacity: 0.55
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Row {
              spacing: Style.spacing.md
              SettingPill {
                label: root.view === "greeter" ? "Start Japan Quake Monitor" : "Apply"
                active: true
                onPicked: root.applyDrafts()
              }
              SettingPill {
                label: "Cancel"
                visible: root.view !== "greeter"
                onPicked: root.view = "map"
              }
            }
          }
        }
      }
    }
  }

}
