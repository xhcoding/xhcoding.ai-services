import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar indicator + popup that owns the three GPU AI services on this machine:
// ComfyUI, a local LLM and a Strata service. Only one may run at a time, so
// starting one stops the others. Replaces the old single-service `local-llm`
// bar module.
// It also carries the GPU power cap and the CPU package limit (PL1+PL2) switchers; the numbers in
// the tooltips come from measurements on this machine.
Panel {
  id: root

  moduleName: "xhcoding.ai-services"
  ipcTarget: "xhcoding.ai-services"
  manageIpc: true

  readonly property string scriptPath: Qt.resolvedUrl("ai-services.sh").toString().replace("file://", "")
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // id -> "stopped" | "starting" | "running" | "failed"
  property var states: ({})
  property string pending: ""
  property int cursorIndex: -1

  // Tailscale line from ai-services.sh: the address peers use.  The services bind 0.0.0.0, so this
  // address works as soon as tailscale is up; your firewall decides who gets in, and the tailnet
  // ports must be allowed through it.
  property var tailnet: ({ ip: "down" })
  // the URL just put on the clipboard, shown for a few seconds
  property string copied: ""

  // GPU power cap line: cap/draw/boot from ai-services.sh, "tool" says whether the
  // privileged helper is installed. Reading needs nothing; changing runs pkexec, which
  // pops the normal polkit password dialog.
  property var gpu: ({ cap: "?", draw: "?", boot: "default", tool: "no" })
  property string powerPending: ""
  property string powerError: ""

  // CPU package limits (Intel RAPL PL1/PL2) from ai-services.sh. Reading is free; only writing
  // runs pkexec. PL1 and PL2 have to be written together on this board - PL1 alone does nothing
  // (measured), so the helper always sets both and reads them back.
  property var cpu: ({ pl1: "?", pl2: "?", saved: "default", tool: "no" })
  property string cpuPending: ""
  property string cpuError: ""

  // Steps measured on this card (decode tok/s).
  readonly property var powerOptions: [
    { value: "default", label: "No cap", tooltip: "Let the card boost on its own. This workload never reaches the ceiling: prefill peaks ~371 W." },
    { value: "350",     label: "350",    tooltip: "Free: 100% of top decode speed, peak 326 W instead of ~371 W." },
    { value: "300",     label: "300",    tooltip: "98.8% of top decode speed, average 216 W." },
    { value: "250",     label: "250",    tooltip: "96.0% of top decode speed, 200 W average, 252 W peak - the quiet choice." },
    { value: "200",     label: "200",    tooltip: "81.8% of top decode speed: the first step you can feel." }
  ]

  // pkexec always asks, so say so up front instead of looking stuck while the dialog is open.
  readonly property string powerAskHint: "changing either cap asks for your password"

  // Measured on this chip at a 250 W GPU cap, 30 s of steady decode:
  // PL1/PL2 default 262 W package + 91 C, 150 W -> 187 W + 74 C at 97.6% speed, 100 W -> 127 W + 66 C at 95.7%.
  readonly property var cpuOptions: [
    { value: "default", label: "No cap", tooltip: "Board defaults: PL1 253 W, PL2 4095 W (unlimited), and no PL1 time window - so the chip just lives in PL2. Measured 262 W package, 91 C during decode." },
    { value: "150",     label: "150",    tooltip: "The pick: 187 W package instead of 262 W, 74 C instead of 91 C, for 97.6% of decode speed." },
    { value: "125",     label: "125",    tooltip: "Not measured, interpolated between 150 W and 100 W: roughly 155 W package, 70 C, ~97% of decode speed." },
    { value: "100",     label: "100",    tooltip: "127 W package, 66 C, 95.7% of decode speed - the quietest useful step." }
  ]

  readonly property var services: [
    { id: "comfyui",      label: "ComfyUI",   description: "Image generation · 0.0.0.0:18188", url: "http://127.0.0.1:18188", port: 18188 },
    { id: "local-llm",    label: "Local LLM", description: "Local LLM · 0.0.0.0:11434",      url: "http://127.0.0.1:11434", port: 11434 },
    { id: "strata-iq3_s", label: "Strata",    description: "Strata · 0.0.0.0:18182",         url: "http://127.0.0.1:18182", port: 18182 }
  ]

  readonly property string activeId: {
    for (var i = 0; i < services.length; i++) {
      var s = stateOf(services[i].id)
      if (s === "running" || s === "starting") return services[i].id
    }
    return ""
  }
  readonly property bool anyOn: activeId !== ""

  function stateOf(id) { return states[id] || "stopped" }
  function isOn(id) { var s = stateOf(id); return s === "running" || s === "starting" }

  // "250 W cap · 246 W now · kept at boot"
  function powerSummary() {
    if (String(gpu.cap) === "?") return "GPU power: nvidia-smi is not answering"
    var cap = String(gpu.cap), boot = String(gpu.boot)
    var text = cap + " W cap · " + gpu.draw + " W now"
    return text + (boot === cap ? " · kept at boot" : " · boot: " + boot + " W")
  }

  function powerPendingLabel() {
    if (powerPending === "") return ""
    return "Setting " + (powerPending === "default" ? "no cap" : powerPending + " W") + "…  ·  confirm the password dialog"
  }

  function powerReady() { return String(gpu.tool) === "yes" }

  // Pick a cap: "default" clears it, a number caps there and survives the next boot.
  function setPower(value) {
    if (!root.bar || !powerReady() || powerProc.running) return
    // Nothing to do when the saved choice and the live cap already agree.
    if (String(value) === String(gpu.boot) && String(value) === String(gpu.cap)) return
    powerPending = String(value)
    powerError = ""
    powerProc.command = value === "default"
                         ? ["pkexec", "/usr/local/bin/omarchy-gpu-power", "off"]
                         : ["pkexec", "/usr/local/bin/omarchy-gpu-power", "set", String(value)]
    powerProc.running = true
  }

  // Press p: walk the ladder, so the common "cool it down / let it run" case needs no mouse.
  function cyclePower() {
    if (!powerReady()) return
    var i = -1
    for (var k = 0; k < powerOptions.length; k++)
      if (String(powerOptions[k].value) === String(gpu.boot)) { i = k; break }
    setPower(powerOptions[(i + 1) % powerOptions.length].value)
  }

  // "PL1+PL2 150 W · kept at boot" (live package watts are root-only, so they are not shown here)
  function cpuSummary() {
    if (String(cpu.pl1) === "?") return "CPU limits: no RAPL package zone (intel_rapl not loaded?)"
    var both = String(cpu.pl1) === String(cpu.pl2)
    var text = both ? "PL1+PL2 " + cpu.pl1 + " W" : "PL1 " + cpu.pl1 + " W / PL2 " + cpu.pl2 + " W"
    if (!both) text += " · PL2 still open, which defeats PL1 on this board"
    text += String(cpu.saved) === "default" ? " · board defaults" : " · kept at boot"
    return text
  }

  function cpuPendingLabel() {
    if (cpuPending === "") return ""
    return "Setting PL1+PL2 " + (cpuPending === "default" ? "back to board defaults" : cpuPending + " W")
           + "…  ·  confirm the password dialog"
  }

  function cpuReady() { return String(cpu.tool) === "yes" }

  function setCpuPower(value) {
    if (!root.bar || !cpuReady() || cpuProc.running) return
    if (String(value) === String(cpu.saved)
        && String(value) !== "default"
        && String(value) === String(cpu.pl1) && String(value) === String(cpu.pl2)) return
    cpuPending = String(value)
    cpuError = ""
    cpuProc.command = value === "default"
                      ? ["pkexec", "/usr/local/bin/omarchy-cpu-power", "off"]
                      : ["pkexec", "/usr/local/bin/omarchy-cpu-power", "set", String(value)]
    cpuProc.running = true
  }

  function cycleCpu() {
    if (!cpuReady()) return
    var i = -1
    for (var k = 0; k < cpuOptions.length; k++)
      if (String(cpuOptions[k].value) === String(cpu.saved)) { i = k; break }
    setCpuPower(cpuOptions[(i + 1) % cpuOptions.length].value)
  }

  function rowDescription(id, base) {
    if (pending === id) return base + "  ·  working…"
    var s = stateOf(id)
    if (s === "starting") return base + "  ·  starting…"
    if (s === "failed") return base + "  ·  failed"
    return base
  }

  function serviceAt(id) {
    for (var i = 0; i < services.length; i++)
      if (services[i].id === id) return services[i]
    return null
  }

  // What to type on another tailnet machine. MagicDNS is off on this tailnet, so the 100.x address is the name.
  function tailnetUrl(id) {
    var svc = serviceAt(id)
    if (!svc || String(root.tailnet.ip) === "down" || root.tailnet.ip === "") return ""
    return "http://" + root.tailnet.ip + ":" + svc.port
  }

  function copyTailnetUrl(id) {
    var url = tailnetUrl(id)
    if (url === "") return
    Quickshell.execDetached(["wl-copy", url])
    root.copied = url
    copyTimer.restart()
  }

  // "Tailnet: <tailnet-ip> · :18188 :11434 :18182", or what is missing.
  function tailnetSummary() {
    var ip = String(root.tailnet.ip)
    if (ip === "down" || ip === "") return "Tailscale has no address on this machine"
    var ports = []
    for (var i = 0; i < services.length; i++) ports.push(":" + services[i].port)
    return "Tailnet: " + ip + "  ·  " + ports.join(" ")
  }

  function refresh() {
    if (!root.bar || statusProc.running) return
    statusProc.running = true
  }

  // Named toggleService, not toggle: the Panel base owns toggle() for the
  // popup lifecycle, and QML has no arity overloading.
  function toggleService(id) {
    if (!root.bar || pending !== "") return
    pending = id
    actionProc.command = ["bash", scriptPath, "toggle", id]
    actionProc.running = true
  }

  // Open a running service's web UI in the default browser.
  function openService(id) {
    if (!root.isOn(id)) return
    var svc = serviceAt(id)
    if (svc && svc.url) Quickshell.execDetached(["omarchy-launch-browser", svc.url])
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: refresh()

  Timer {
    interval: 2000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    id: copyTimer
    interval: 4000
    onTriggered: root.copied = ""
  }

  Process {
    id: statusProc
    command: ["bash", root.scriptPath, "status"]
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    onExited: function() {
      var out = String(statusOut.text || "").trim()
      var next = {}
      if (out !== "") {
        var lines = out.split("\n")
        for (var i = 0; i < lines.length; i++) {
          var p = lines[i].trim().split(/\s+/)
          if (p.length < 2) continue
          if (p[0] === "gpu-power") {
            root.gpu = { cap: p[1], draw: p[2], boot: p[3] || "default", tool: p[4] || "no" }
            continue
          }
          if (p[0] === "cpu-power") {
            root.cpu = { pl1: p[1], pl2: p[2], saved: p[3] || "default", tool: p[4] || "no" }
            continue
          }
          if (p[0] === "tailnet") {
            root.tailnet = { ip: p[1] || "down" }
            continue
          }
          next[p[0]] = p[1]
        }
      }
      root.states = next
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function() {
      root.pending = ""
      root.refresh()
    }
  }

  Process {
    id: powerProc
    // No timeout: this has to stay alive while the polkit dialog waits for a password.
    stdout: StdioCollector { id: powerOut; waitForEnd: true }
    stderr: StdioCollector { id: powerErr; waitForEnd: true }
    onExited: function(code) {
      root.powerPending = ""
      if (code !== 0) {
        var lines = String(powerErr.text || "").trim().split("\n").filter(function(l) { return l.trim() !== "" })
        var first = lines.length ? lines[0] : ""
        if (/not authorized|authenticat/i.test(first))
          root.powerError = "authorization cancelled — cap left at " + gpu.cap + " W"
        else
          root.powerError = first || "the power change failed (exit " + code + ")"
      } else {
        root.powerError = ""
      }
      root.refresh()
    }
  }

  Process {
    id: cpuProc
    // No timeout: this has to stay alive while the polkit dialog waits for a password.
    stdout: StdioCollector { id: cpuOut; waitForEnd: true }
    stderr: StdioCollector { id: cpuErr; waitForEnd: true }
    onExited: function(code) {
      root.cpuPending = ""
      if (code !== 0) {
        var lines = String(cpuErr.text || "").trim().split("\n").filter(function(l) { return l.trim() !== "" })
        var first = lines.length ? lines[0] : ""
        if (/not authorized|authenticat/i.test(first))
          root.cpuError = "authorization cancelled — PL1/PL2 left at " + cpu.pl1 + " W"
        else
          root.cpuError = first || "the CPU limit change failed (exit " + code + ")"
      } else {
        root.cpuError = ""
      }
      root.refresh()
    }
  }

  readonly property string tooltip: {
    var parts = []
    for (var i = 0; i < services.length; i++) {
      var id = services[i].id
      var s = stateOf(id)
      var label = s === "running" ? "running"
                : s === "starting" ? "starting…"
                : s === "failed" ? "failed"
                : "stopped"
      parts.push(services[i].label + ": " + label)
    }
    return "AI Services\n" + parts.join("\n")
           + "\n" + root.tailnetSummary()
           + "\nGPU power: " + root.powerSummary()
           + "\nCPU limits: " + root.cpuSummary()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰚩"
    tooltipText: root.tooltip
    opacity: root.anyOn ? 1 : 0.45
    dimmed: !root.anyOn
    useActiveColor: false
    fontSize: Style.font.caption
    horizontalMargin: 5
    verticalPadding: 5
    fixedWidth: vertical ? -1 : Style.bar.statusSlot
    fixedHeight: vertical ? Style.bar.statusSlot : -1

    onPressed: function() {
      if (root.opened) root.close()
      else root.open()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dy === 0) return
        if (root.cursorIndex < 0) root.cursorIndex = dy > 0 ? 0 : root.services.length - 1
        else root.cursorIndex = Math.max(0, Math.min(root.services.length - 1, root.cursorIndex + dy))
      }
      onActivateRequested: {
        if (root.cursorIndex >= 0 && root.cursorIndex < root.services.length)
          root.toggleService(root.services[root.cursorIndex].id)
      }
      onCloseRequested: root.close()
      onTextKey: function(t) {
        if (t === "o" || t === "O") {
          var id = (root.cursorIndex >= 0 && root.cursorIndex < root.services.length)
                   ? root.services[root.cursorIndex].id
                   : root.activeId
          if (id) root.openService(id)
        } else if (t === "t" || t === "T") {
          var tid = (root.cursorIndex >= 0 && root.cursorIndex < root.services.length)
                    ? root.services[root.cursorIndex].id
                    : root.activeId
          if (tid) root.copyTailnetUrl(tid)
        } else if (t === "p" || t === "P") {
          root.cyclePower()
        } else if (t === "c" || t === "C") {
          root.cycleCpu()
        }
      }
    }

    Column {
      id: column
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: "AI SERVICES"
        color: Qt.darker(root.foreground, 1.4)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        topPadding: Math.ceil(font.pixelSize * 0.15)
      }

      Text {
        textFormat: Text.PlainText
        text: (root.anyOn
              ? "One service is running. Starting another stops it first."
              : "Nothing running. Only one service can run at a time.")
              + " Click the arrow (or press o) to open a running service in the browser."
              + "  p walks the GPU cap, c walks the CPU PL1+PL2."
              + "  t copies the tailnet URL."
        color: Qt.darker(root.foreground, 1.55)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        width: parent.width
      }

      PanelSeparator { foreground: root.foreground }

      Text {
        textFormat: Text.PlainText
        text: root.copied !== "" ? "copied: " + root.copied : root.tailnetSummary()
        color: root.copied !== "" ? root.foreground : Qt.darker(root.foreground, 1.55)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        width: parent.width
      }

      Repeater {
        model: root.services
        delegate: RowLayout {
          required property var modelData
          required property int index
          width: column.width
          spacing: Style.spacing.xs

          Toggle {
            Layout.fillWidth: true
            label: modelData.label
            description: root.rowDescription(modelData.id, modelData.description)
            checked: root.isOn(modelData.id)
            hasCursor: root.cursorIndex === index
            foreground: root.foreground
            onClicked: root.toggleService(modelData.id)
            onHovered: function(isHovered) { if (isHovered) root.cursorIndex = index }
          }

          Button {
            Layout.preferredWidth: Style.space(46)
            Layout.fillHeight: true
            iconText: "󰏌"
            iconSize: Style.font.subtitle
            tooltipText: root.isOn(modelData.id)
                         ? "Open " + modelData.label + " in browser"
                         : modelData.label + " is not running"
            foreground: root.foreground
            opacity: root.isOn(modelData.id) ? 1 : 0.4
            onClicked: root.openService(modelData.id)
            onHovered: function(isHovered) { if (isHovered) root.cursorIndex = index }
          }

          // Copy the address another tailnet machine would use (the servers bind 0.0.0.0, so this
          // is the tailscale0 face of the same listener).
          Button {
            Layout.preferredWidth: Style.space(46)
            Layout.fillHeight: true
            iconText: "󰆏"
            iconSize: Style.font.subtitle
            tooltipText: root.tailnetUrl(modelData.id) !== ""
                         ? "Copy " + root.tailnetUrl(modelData.id) + "  (tailscale only)"
                         : "tailscale has no address on this machine"
            foreground: root.foreground
            opacity: root.tailnetUrl(modelData.id) !== "" ? 1 : 0.4
            onClicked: root.copyTailnetUrl(modelData.id)
            onHovered: function(isHovered) { if (isHovered) root.cursorIndex = index }
          }
        }
      }

      PanelSeparator { foreground: root.foreground }

      Text {
        textFormat: Text.PlainText
        text: "GPU POWER"
        color: Qt.darker(root.foreground, 1.4)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        topPadding: Math.ceil(font.pixelSize * 0.15)
      }

      Text {
        textFormat: Text.PlainText
        text: root.powerPendingLabel() !== ""
              ? root.powerPendingLabel()
              : root.powerError !== ""
              ? root.powerError
              : !root.powerReady()
              ? "Cap switching needs the omarchy-gpu-power helper installed on this machine"
              : root.powerSummary() + "   ·   press p to walk the ladder   ·   " + root.powerAskHint
        color: root.powerError !== "" ? root.foreground : Qt.darker(root.foreground, 1.55)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        width: parent.width
      }

      ButtonGroup {
        options: root.powerOptions
        value: String(root.gpu.boot)
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        focusable: false
        opacity: root.powerReady() ? 1 : 0.4
        enabled: root.powerReady()
        onChanged: function(v) { root.setPower(v) }
      }

      PanelSeparator { foreground: root.foreground }

      Text {
        textFormat: Text.PlainText
        text: "CPU POWER (PL1 + PL2)"
        color: Qt.darker(root.foreground, 1.4)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        topPadding: Math.ceil(font.pixelSize * 0.15)
      }

      Text {
        textFormat: Text.PlainText
        text: root.cpuPendingLabel() !== ""
              ? root.cpuPendingLabel()
              : root.cpuError !== ""
              ? root.cpuError
              : !root.cpuReady()
              ? "CPU cap switching needs the omarchy-cpu-power helper installed on this machine"
              : root.cpuSummary() + "   ·   press c to walk the ladder"
        color: root.cpuError !== "" ? root.foreground : Qt.darker(root.foreground, 1.55)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        width: parent.width
      }

      ButtonGroup {
        options: root.cpuOptions
        value: String(root.cpu.saved)
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        focusable: false
        opacity: root.cpuReady() ? 1 : 0.4
        enabled: root.cpuReady()
        onChanged: function(v) { root.setCpuPower(v) }
      }
    }
  }
}
