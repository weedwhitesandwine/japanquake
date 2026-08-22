import QtQuick
import qs.Commons
import qs.Ui as Ui
import "Shindo.js" as Shindo
import "."

// A lightning bolt, with a stripe beneath it in the colour Japan uses for the
// intensity of the most recent quake — so a glance gives you the severity even
// though the icon itself is fixed. Clicking opens the map.
// (qs.Ui is imported under a namespace because this file is itself named
// BarWidget.qml — a bare `BarWidget` would resolve to the file itself.)
Ui.BarWidget {
  id: root
  moduleName: "io.github.weedwhitesandwine.japanquake"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property var overlay: JapanQuakeState.overlay
  readonly property var latest: overlay && overlay.quakes && overlay.quakes.length > 0
    ? overlay.quakes[0] : null
  readonly property string shindo: latest ? (latest.shindo || "") : ""

  readonly property bool opened: overlay ? overlay.opened === true : false

  function plain(v) { return String(v === undefined || v === null ? "" : v).replace(/[<>]/g, "") }
  function open() { if (overlay) { overlay.view = "map"; overlay.opened = true } }
  function close() { if (overlay) overlay.close() }

  Ui.BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // A font glyph rather than the emoji, so it takes the theme's foreground
    // colour like every other icon in the bar.
    text: "\uF0E7"
    // The place name and the intensity both arrive off the network, and this
    // sink is not ours: Omarchy's Ui/Button.qml renders tooltipText through a
    // Text with no textFormat set, which leaves it on AutoText, where Qt
    // decides for itself whether a string is writing or markup. Markup there
    // can fetch a remote resource from inside the shell process, so the two
    // characters that make a string markup are taken out first. Every Text in
    // this plugin is pinned to plain text; this is the one sink that cannot be.
    tooltipText: root.latest
      ? (root.plain(root.overlay.placeOf(root.latest)) + " · shindo " + root.plain(root.shindo))
      : "Japan Quake Monitor — no earthquake data yet"
    onPressed: function(b) {
      if (!root.overlay) return
      if (root.overlay.opened) root.overlay.close()
      else { root.overlay.view = "map"; root.overlay.opened = true }
    }
  }

  // The intensity of the latest quake, as a bar underneath the number. Quiet
  // when nothing has happened, and never louder than the number itself.
  Rectangle {
    visible: root.shindo !== ""
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.space(3)
    width: Style.space(14)
    height: Style.space(2)
    radius: height / 2
    color: Shindo.color(root.shindo)
  }
}
