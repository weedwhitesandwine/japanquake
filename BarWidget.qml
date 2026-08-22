import QtQuick
import qs.Commons
import qs.Ui as Ui
import "Shindo.js" as Shindo
import "."

// The bar icon carries the one fact worth glancing at: how strong the most
// recent earthquake was, in the colour Japan already uses for that number.
// Clicking it opens the map.
// (qs.Ui is imported under a namespace because this file is itself named
// BarWidget.qml — a bare `BarWidget` would resolve to the file itself.)
Ui.BarWidget {
  id: root
  moduleName: "io.github.weedwhitesandwine.namazu"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property var overlay: NamazuState.overlay
  readonly property var latest: overlay && overlay.quakes && overlay.quakes.length > 0
    ? overlay.quakes[0] : null
  readonly property string shindo: latest ? (latest.shindo || "") : ""

  readonly property bool opened: overlay ? overlay.opened === true : false
  function open() { if (overlay) { overlay.view = "map"; overlay.opened = true } }
  function close() { if (overlay) overlay.close() }

  Ui.BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.shindo === "" ? "鯰" : root.shindo
    tooltipText: root.latest
      ? (root.overlay.placeOf(root.latest) + " · shindo " + root.shindo)
      : "Namazu — no earthquake data yet"
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
