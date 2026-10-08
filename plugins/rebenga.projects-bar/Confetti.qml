import QtQuick
import qs.Commons

// Confetti burst from the bottom centre. Call burst(); `running` is true while pieces fly.
Item {
  id: root
  property int count: 140
  property real duration: 3.2           // seconds
  property real t: 0                    // 0 → 1 over the animation
  property int seed: 0
  readonly property bool running: anim.running
  readonly property var palette: [Color.accent, Color.urgent, Color.foreground, "#f6c177", "#9ccfd8", "#c4a7e7", "#eb6f92", "#a6e3a1"]

  // The overlay window may not be sized yet on the first frame; retry until it is.
  function burst() {
    if (width <= 0 || height <= 0) { retry.start(); return }
    seed += 1
    anim.restart()
  }
  Timer { id: retry; interval: 16; onTriggered: root.burst() }

  NumberAnimation { id: anim; target: root; property: "t"; from: 0; to: 1; duration: root.duration * 1000; easing.type: Easing.Linear }

  Repeater {
    model: root.count
    delegate: Rectangle {
      id: piece
      required property int index
      // Randomised on each burst (seed change)
      property real vx: 0
      property real vy: 0
      property real spin: 0
      property real wobble: 0
      property real delay: 0
      property real x0: 0
      function shuffle() {
        var w = root.width, h = root.height
        var angle = (-90 + (Math.random() - 0.5) * 70) * Math.PI / 180
        var speed = h * (0.9 + Math.random() * 0.75)
        vx = Math.cos(angle) * speed
        vy = Math.sin(angle) * speed
        spin = (Math.random() - 0.5) * 1440
        wobble = Math.random() * Math.PI * 2
        delay = Math.random() * 0.12
        x0 = w / 2 + (Math.random() - 0.5) * 160
        width = 6 + Math.random() * 7
        height = Math.random() < 0.3 ? width : width * 0.45
        radius = Math.random() < 0.25 ? width / 2 : 1
        color = root.palette[Math.floor(Math.random() * root.palette.length)]
      }
      Connections { target: root; function onSeedChanged() { piece.shuffle() } }

      readonly property real s: Math.max(0, root.t * root.duration - delay)   // seconds since launch
      readonly property real g: root.height * 1.25                            // gravity px/s²
      visible: root.running && s > 0
      x: x0 + vx * s * 0.85 + Math.sin(wobble + s * 6) * 14 - width / 2
      y: root.height - 40 + vy * s + 0.5 * g * s * s
      rotation: spin * s / root.duration
      opacity: root.t < 0.72 ? 1 : Math.max(0, 1 - (root.t - 0.72) / 0.28)
      transform: Scale { origin.x: piece.width / 2; xScale: Math.cos(piece.wobble + piece.s * 9) }
    }
  }
}
