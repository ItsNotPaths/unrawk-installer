## unrawk-installer — TUI-on-Wayland installer applet for the unrawk ISO.
##
## Owns the wayluigi window, palette load, selfFloat fallback, and the
## screen state machine: Form → Confirm → Execute. The Execute screen
## stays put after the install finishes; its terminal buttons (Reboot /
## Shell) reveal themselves rather than switching to a new screen, so we
## avoid destroying the active animation element mid-tick.
##
## Runtime modes:
##   - Interactive (default)         — opens window, shows form
##   - Interactive `--gates`         — runs pre-flight first; bad gates
##                                     route to the error screen
##   - `--headless --seed=<path>`    — no window; emits the full install
##                                     transcript to stdout for golden
##                                     testing
##   - any of the above `--for-real` — only honoured on the live ISO
##                                     (gated by /etc/unrawk-live-iso);
##                                     refuses otherwise

import std/[os, osproc, strutils]
import rawk_luigi, theme, preflight, runmode, logger, install

# rawk_luigi doesn't yet expose UILabelSetContent (no consumer needed it
# until now). Inline the FFI here; promote to rawk_luigi on next bump.
proc labelSetContent(label: ptr Label; cString: cstring; stringBytes: int)
  {.cdecl, importc: "UILabelSetContent", header: "luigi.h".}

const
  windowW:     cint   = 480
  windowH:     cint   = 800
  windowTitle        = "unrawk-installer"
  selfFloatDelaySec  = "0.15"

  defaultForm = FormData(
    keyboard:       "us",
    timezone:       "America/New_York",
    hostname:       "unrawk",
    user:           "paths",
    password:       "(unset)",
    luksPassphrase: "(unset)",
    disk:           "/dev/sda",
    filesystem:     "ext4",
  )

  separator = "=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-="

# ---------- screen state ----------

type Screen = enum
  scForm, scConfirm, scExecute

# Globals — the wayluigi callback ABI is cdecl, so we can't close over
# locals from main. State that callbacks need lives here.
var
  gWindow:        ptr Window
  gScreenPanel:   ptr Panel       # rebuilt per screen
  gScreen:        Screen = scForm
  gForm:          FormData

  # Execute-screen-specific state. Reset by initExecute, read/written by
  # the ticker and the per-tick UI refresh.
  gInstallState:    InstallState
  gInstallLogBuf:   ref seq[string]
  gInstallLogger:   Logger
  gShownLogCount:   int
  gStepLabels:      array[InstallStep, ptr Label]
  gLogParentPanel:  ptr Panel
  gRebootBtn:       ptr Button
  gShellBtn:        ptr Button

# ---------- font / selfFloat (unchanged from earlier steps) ----------

proc selfFloat() =
  ## See README "Sway integration" and installer-spec.md. The for_window
  ## rule is the real no-flash fix; this fallback only matters on dev
  ## boxes without the rule.
  let pid = $getCurrentProcessId()
  let cmd = "(sleep " & selfFloatDelaySec & " && swaymsg \"[pid=" & pid &
    "] floating enable, resize set width " & $windowW &
    " height " & $windowH & ", move position center\" >/dev/null 2>&1) &"
  discard execShellCmd(cmd)

proc systemMonoPath(): string =
  let override = getEnv("RAWK_FONT")
  if override.len > 0 and fileExists(override):
    return override
  try:
    let (output, code) = execCmdEx("fc-match --format=%{file} monospace:mono")
    if code == 0:
      let p = output.strip()
      if p.len > 0 and fileExists(p):
        return p
  except CatchableError:
    discard
  return ""

proc loadFont() =
  let path = systemMonoPath()
  if path.len == 0: return
  let f = fontCreate(path.cstring, 12'u32)
  if f != nil:
    discard fontActivate(f)

# ---------- button invokes ----------

proc shellInvoke(cp: pointer) {.cdecl.}
proc exitInvoke(cp: pointer) {.cdecl.}
proc rebootInvoke(cp: pointer) {.cdecl.}
proc installInvoke(cp: pointer) {.cdecl.}
proc backInvoke(cp: pointer) {.cdecl.}
proc wipeInvoke(cp: pointer) {.cdecl.}

# ---------- screen builders ----------

proc buildHeading(parent: ptr Element, text: string) =
  discard buttonCreate(parent, 0, text.cstring, text.len)
  discard labelCreate(parent, 0, separator.cstring, separator.len)

proc addField(parent: ptr Element, title, value: string) =
  discard labelCreate(parent, 0, title.cstring, title.len)
  discard buttonCreate(parent, 0, value.cstring, value.len)
  discard labelCreate(parent, 0, separator.cstring, separator.len)

proc buildForm(parent: ptr Element) =
  buildHeading(parent, "=== unrawk installer ===")
  addField(parent, "Keyboard",   gForm.keyboard)
  addField(parent, "Timezone",   gForm.timezone)
  addField(parent, "Hostname",   gForm.hostname)
  addField(parent, "User",       gForm.user)
  addField(parent, "Password",   "********")
  addField(parent, "Disk",       gForm.disk)
  addField(parent, "LUKS",       "********")
  addField(parent, "Filesystem", gForm.filesystem)

  let install = buttonCreate(parent, 0, "Install", -1)
  install.invoke = installInvoke

proc buildErrorScreen(parent: ptr Element, failedGates: seq[Gate]) =
  buildHeading(parent, "=== cannot start install ===")
  discard labelCreate(parent, 0, "The following checks failed:".cstring, -1)
  discard labelCreate(parent, 0, "".cstring, 0)
  for g in failedGates:
    let line = "  - " & g.reason
    discard labelCreate(parent, 0, line.cstring, line.len)
  discard labelCreate(parent, 0, "".cstring, 0)
  discard labelCreate(parent, 0, separator.cstring, separator.len)
  let shellBtn = buttonCreate(parent, 0, "Shell", -1)
  shellBtn.invoke = shellInvoke
  let exitBtn = buttonCreate(parent, 0, "Exit", -1)
  exitBtn.invoke = exitInvoke

proc buildConfirm(parent: ptr Element) =
  buildHeading(parent, "=== confirm install ===")

  discard labelCreate(parent, 0, "Will wipe and install to:".cstring, -1)
  let diskLine = "  " & gForm.disk
  discard labelCreate(parent, 0, diskLine.cstring, diskLine.len)
  discard labelCreate(parent, 0, "".cstring, 0)

  discard labelCreate(parent, 0, "Settings:".cstring, -1)
  let lines = [
    "  hostname    " & gForm.hostname,
    "  user        " & gForm.user,
    "  keyboard    " & gForm.keyboard,
    "  timezone    " & gForm.timezone,
    "  filesystem  " & gForm.filesystem,
  ]
  for line in lines:
    discard labelCreate(parent, 0, line.cstring, line.len)
  discard labelCreate(parent, 0, "".cstring, 0)
  discard labelCreate(parent, 0, separator.cstring, separator.len)

  discard labelCreate(parent, 0, "WARNING: This will erase all data on the disk above.".cstring, -1)
  discard labelCreate(parent, 0, "         There is no undo.".cstring, -1)
  discard labelCreate(parent, 0, separator.cstring, separator.len)

  let back = buttonCreate(parent, 0, "Back", -1)
  back.invoke = backInvoke
  let wipe = buttonCreate(parent, 0, "Wipe and install", -1)
  wipe.invoke = wipeInvoke

proc executeTickerMessage(e: ptr Element, m: Message, di: cint, dp: pointer): cint {.cdecl.}

proc refreshExecuteUI() =
  ## Update step-label content from gInstallState, append any new log
  ## lines as labels under gLogParentPanel, and reveal the terminal
  ## buttons once the install is finished.
  for step in InstallStep:
    let lbl = gStepLabels[step]
    if lbl == nil: continue
    let marker = case gInstallState.stepStates[step]
      of ssPending: "[ ]"
      of ssRunning: "[>]"
      of ssDone:    "[*]"
      of ssFailed:  "[X]"
    let line = marker & " " & stepDisplay(step, gInstallState.form.filesystem)
    labelSetContent(lbl, line.cstring, line.len)

  while gShownLogCount < gInstallLogBuf[].len:
    let line = gInstallLogBuf[][gShownLogCount]
    discard labelCreate(addr gLogParentPanel.e, 0, line.cstring, line.len)
    inc gShownLogCount

  if gInstallState.finished:
    if gRebootBtn != nil and (gRebootBtn.e.flags and ELEMENT_HIDE) != 0:
      gRebootBtn.e.flags = gRebootBtn.e.flags and not ELEMENT_HIDE
      gShellBtn.e.flags  = gShellBtn.e.flags  and not ELEMENT_HIDE

  elementRefresh(addr gScreenPanel.e)

proc initExecute() =
  gInstallState = newInstallState(gForm)
  gInstallLogBuf = new(seq[string])
  gInstallLogBuf[] = @[]
  gInstallLogger = newBufferLogger(gInstallLogBuf, redactSecrets = true)
  gShownLogCount = 0
  for step in InstallStep:
    gStepLabels[step] = nil
  gRebootBtn = nil
  gShellBtn = nil

proc buildExecute(parent: ptr Element) =
  buildHeading(parent, "=== installing ===")

  for step in InstallStep:
    let line = "[ ] " & stepDisplay(step, gForm.filesystem)
    let lbl = labelCreate(parent, 0, line.cstring, line.len)
    gStepLabels[step] = lbl

  discard labelCreate(parent, 0, separator.cstring, separator.len)
  discard labelCreate(parent, 0, "log:".cstring, -1)

  # Sub-panel hosting the live log lines. Lines append as labels; once
  # we have many of them, a real scroll widget will replace this.
  gLogParentPanel = panelCreate(parent,
    PANEL_GRAY or ELEMENT_H_FILL or ELEMENT_V_FILL)

  # Terminal buttons — hidden until install finishes; toggled in
  # refreshExecuteUI when state.finished flips.
  gRebootBtn = buttonCreate(parent, ELEMENT_HIDE, "Reboot", -1)
  gRebootBtn.invoke = rebootInvoke
  gShellBtn = buttonCreate(parent, ELEMENT_HIDE, "Shell", -1)
  gShellBtn.invoke = shellInvoke

  # Hidden ticker element drives the install + UI refresh.
  let ticker = elementCreate(csize_t(sizeof(Element)), parent,
    ELEMENT_HIDE, executeTickerMessage, "ExecuteTicker")
  discard elementAnimate(ticker, false)

# ---------- screen switching ----------

proc destroyChildren(parent: ptr Element) =
  var toGo: seq[ptr Element] = @[]
  var c = parent.children
  while c != nil:
    toGo.add(c)
    c = c.next
  for e in toGo:
    elementDestroy(e)

proc switchScreen(s: Screen) =
  gScreen = s
  if gScreenPanel != nil:
    destroyChildren(addr gScreenPanel.e)
  case s
  of scForm:    buildForm(addr gScreenPanel.e)
  of scConfirm: buildConfirm(addr gScreenPanel.e)
  of scExecute:
    initExecute()
    buildExecute(addr gScreenPanel.e)
  elementRefresh(addr gScreenPanel.e)

# ---------- button bodies (forward-declared above) ----------

proc shellInvoke(cp: pointer) {.cdecl.} =
  ## Spawn alacritty in the user's sway session. The "manual mode"
  ## escape hatch — works on the live ISO and dev boxes (both have
  ## alacritty available). Detached so closing the terminal doesn't
  ## affect the installer.
  discard execShellCmd("(swaymsg exec alacritty >/dev/null 2>&1) &")

proc exitInvoke(cp: pointer) {.cdecl.} =
  quit(1)

proc rebootInvoke(cp: pointer) {.cdecl.} =
  ## Dry-run: just exit. Step 6+ will issue `reboot` when --for-real.
  quit(0)

proc installInvoke(cp: pointer) {.cdecl.} =
  switchScreen(scConfirm)

proc backInvoke(cp: pointer) {.cdecl.} =
  switchScreen(scForm)

proc wipeInvoke(cp: pointer) {.cdecl.} =
  switchScreen(scExecute)

# ---------- execute ticker body ----------

proc executeTickerMessage(e: ptr Element, m: Message, di: cint, dp: pointer): cint {.cdecl.} =
  if m == msgAnimate:
    if not gInstallState.finished:
      dryRunTick(gInstallState, gInstallLogger)
      refreshExecuteUI()
      if gInstallState.finished:
        # Stop the animate loop; the UI is now static until the user
        # clicks Reboot or Shell.
        discard elementAnimate(e, true)
    return 0
  return 0

# ---------- mode entry points ----------

proc runHeadless(cfg: RunConfig) =
  ## Drain the install flow synchronously to stdout. Pre-flight detect
  ## is skipped (host-variable; would flake goldens). When step 6 lands
  ## --for-real wiring, runHeadless with --for-real should be refused
  ## explicitly — for now it's blocked by the live-ISO marker check.
  let l = newFileLogger(stdout, redactSecrets = true)
  let form = if cfg.seedPath.len > 0: cfg.seed else: defaultForm
  if cfg.seedPath.len > 0:
    l.logUserInput(seedKvs(cfg.seed))
  var state = newInstallState(form)
  state.runHeadless(l)

proc runInteractive(cfg: RunConfig) =
  initialise()
  loadInitialTheme()
  loadFont()

  gWindow = windowCreate(nil, 0, windowTitle, windowW, windowH)
  gScreenPanel = panelCreate(addr gWindow.e,
    PANEL_GRAY or ELEMENT_V_FILL or ELEMENT_H_FILL)
  gForm = if cfg.seedPath.len > 0: cfg.seed else: defaultForm

  if cfg.runGates:
    let pf = runPreflight()
    let bad = pf.failed
    if bad.len > 0:
      buildErrorScreen(addr gScreenPanel.e, bad)
    else:
      switchScreen(scForm)
  else:
    switchScreen(scForm)

  selfFloat()
  discard messageLoop()

# ---------- main ----------

proc main() =
  var cfg: RunConfig
  try:
    cfg = parseCli(commandLineParams())
  except CliError as e:
    stderr.writeLine("unrawk-installer: " & e.msg)
    quit(2)
  cfg.enforceForRealMarker()

  if cfg.headless:
    runHeadless(cfg)
  else:
    runInteractive(cfg)

when isMainModule: main()
