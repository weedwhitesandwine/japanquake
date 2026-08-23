import QtQuick
import qs.Commons
import "JapanGeo.js" as Geo
import "Shindo.js" as Shindo

// Japan, drawn from a coastline and a list of epicentres.
//
// The projection is equirectangular with the longitude axis squeezed by the
// cosine of the middle latitude — without that, a country running from
// Okinawa to Hokkaido comes out visibly fat. It is not a projection anyone
// would navigate by, but for "where did this happen" at this scale nothing
// more elaborate earns its cost.
Item {
  id: map

  property var quakes: []
  property var eew: null
  property int selectedIndex: -1
  property color land: Color.foreground
  property color sea: "transparent"
  property real landAlpha: 0.16

  readonly property real midLat: (Geo.LAT_MIN + Geo.LAT_MAX) / 2
  readonly property real lonSpan: (Geo.LON_MAX - Geo.LON_MIN) * Math.cos(midLat * Math.PI / 180)
  readonly property real latSpan: Geo.LAT_MAX - Geo.LAT_MIN
  readonly property real scale: Math.min(width / lonSpan, height / latSpan)
  readonly property real offsetX: (width - lonSpan * scale) / 2
  readonly property real offsetY: (height - latSpan * scale) / 2

  function xOf(lon) {
    return offsetX + (lon - Geo.LON_MIN) * Math.cos(midLat * Math.PI / 180) * scale
  }
  function yOf(lat) {
    return offsetY + (Geo.LAT_MAX - lat) * scale
  }
  function onMap(lat, lon) {
    return lat !== null && lon !== null && lat >= Geo.LAT_MIN && lat <= Geo.LAT_MAX
        && lon >= Geo.LON_MIN && lon <= Geo.LON_MAX
  }

  Canvas {
    id: coast
    anchors.fill: parent
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      ctx.fillStyle = Qt.rgba(map.land.r, map.land.g, map.land.b, map.landAlpha)
      ctx.strokeStyle = Qt.rgba(map.land.r, map.land.g, map.land.b, 0.55)
      ctx.lineWidth = 1
      for (var i = 0; i < Geo.RINGS.length; i++) {
        var ring = Geo.RINGS[i]
        ctx.beginPath()
        for (var j = 0; j < ring.length; j++) {
          var x = map.xOf(ring[j][0])
          var y = map.yOf(ring[j][1])
          if (j === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y)
        }
        ctx.closePath()
        ctx.fill()
        ctx.stroke()
      }
    }
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
  }

  Connections {
    target: Color
    function onForegroundChanged() { coast.requestPaint() }
  }

  // Tokyo, because every distance in this plugin is measured from it.
  Rectangle {
    x: map.xOf(Geo.TOKYO_LON) - width / 2
    y: map.yOf(Geo.TOKYO_LAT) - height / 2
    width: Style.space(7); height: width; radius: width / 2
    color: "transparent"
    border.color: Color.foreground
    border.width: 1
    opacity: 0.8
  }

  // Every epicentre we know about, oldest first so the newest sits on top.
  Repeater {
    model: map.quakes

    Item {
      required property var modelData
      required property int index
      visible: map.onMap(modelData.lat, modelData.lon)
      x: map.xOf(modelData.lon || 0)
      y: map.yOf(modelData.lat || 0)
      z: map.quakes.length - index

      readonly property bool latest: index === 0
      readonly property bool picked: index === map.selectedIndex
      // Magnitude is a log scale, so a linear radius would make every quake
      // look the same size. Squaring it separates a M3 from a M6.
      readonly property real dotSize: Style.space(6) +
        Style.space(2.2) * Math.max(0, (modelData.magnitude || 2)) *
        Math.max(0.4, (modelData.magnitude || 2) / 5)

      Rectangle {
        anchors.centerIn: parent
        width: parent.dotSize; height: width; radius: width / 2
        color: Shindo.color(modelData.shindo)
        opacity: parent.latest ? 0.9 : (parent.picked ? 0.85 : 0.45)
        border.width: parent.picked || parent.latest ? 1 : 0
        border.color: Color.foreground
      }

      // The newest quake breathes, so the eye finds it without being told.
      Rectangle {
        id: pulse
        anchors.centerIn: parent
        visible: parent.latest
        width: parent.dotSize; height: width; radius: width / 2
        color: "transparent"
        border.color: Shindo.color(modelData.shindo)
        border.width: 2
        SequentialAnimation on scale {
          running: pulse.visible
          loops: Animation.Infinite
          NumberAnimation { from: 1.0; to: 2.6; duration: 1800; easing.type: Easing.OutQuad }
          PropertyAction { value: 1.0 }
        }
        SequentialAnimation on opacity {
          running: pulse.visible
          loops: Animation.Infinite
          NumberAnimation { from: 0.7; to: 0.0; duration: 1800 }
        }
      }
    }
  }

  // An early warning is a forecast about a quake still in progress, so it is
  // drawn differently from anything confirmed: a cross, not a disc.
  Item {
    visible: map.eew !== null && !map.eew.cancelled && map.onMap(map.eew.lat, map.eew.lon)
    x: map.eew ? map.xOf(map.eew.lon || 0) : 0
    y: map.eew ? map.yOf(map.eew.lat || 0) : 0
    z: 9999

    Rectangle {
      anchors.centerIn: parent
      width: Style.space(2); height: Style.space(22)
      color: Color.urgent
    }
    Rectangle {
      anchors.centerIn: parent
      width: Style.space(22); height: Style.space(2)
      color: Color.urgent
    }
    Rectangle {
      anchors.centerIn: parent
      width: Style.space(30); height: width; radius: width / 2
      color: "transparent"
      border.color: Color.urgent
      border.width: 2
      SequentialAnimation on scale {
        running: parent.visible
        loops: Animation.Infinite
        NumberAnimation { from: 0.6; to: 2.0; duration: 900; easing.type: Easing.OutQuad }
        PropertyAction { value: 0.6 }
      }
      SequentialAnimation on opacity {
        running: parent.visible
        loops: Animation.Infinite
        NumberAnimation { from: 0.9; to: 0.0; duration: 900 }
      }
    }
  }
}
