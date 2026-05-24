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

import std/[os, options, osproc, strutils]
import rawk_luigi, theme, preflight, runmode, logger, install, widgets, pickers

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

  # Approx max chars per UI line before luigi clips at the panel right
  # edge. The separator above is 57 chars and renders flush, so 55 gives
  # a small safety margin for label rendering quirks. Used by wrapLogLine.
  uiLineCharLimit = 55

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

  # Form widget refs — populated by buildForm, read by installInvoke to
  # gather values into gForm before transitioning to Confirm.
  gHostnameTb:    ptr Textbox
  gUserTb:        ptr Textbox
  gPasswordTb:    ptr MaskedTextbox
  gLuksTb:        ptr MaskedTextbox
  gFsExt4Btn:     ptr Button
  gFsBtrfsBtn:    ptr Button
  gKbdBtn:        ptr Button
  gTzBtn:         ptr Button
  gDiskBtn:       ptr Button

  # Picker session state — populated when a dropdown opens. The menu
  # item invoke reads gPickerField + the cp-encoded index into
  # gPickerItems to know what value the user picked.
  gPickerField:   PickerField
  gPickerItems:   seq[PickerItem]

  # Execute-screen-specific state. Reset by initExecute, read/written by
  # the ticker and the per-tick UI refresh.
  gInstallState:    InstallState
  gInstallLogBuf:   ref seq[string]
  gInstallLogger:   Logger
  gInstallRunner:   Runner
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
proc fsExt4Invoke(cp: pointer) {.cdecl.}
proc fsBtrfsInvoke(cp: pointer) {.cdecl.}
proc kbdPickerInvoke(cp: pointer) {.cdecl.}
proc tzPickerInvoke(cp: pointer) {.cdecl.}
proc diskPickerInvoke(cp: pointer) {.cdecl.}
proc pickerItemInvoke(cp: pointer) {.cdecl.}
proc snapshotForm()

# ---------- screen builders ----------

proc buildHeading(parent: ptr Element, text: string) =
  discard buttonCreate(parent, 0, text.cstring, text.len)
  discard labelCreate(parent, 0, separator.cstring, separator.len)

proc addTitle(parent: ptr Element, title: string) =
  discard labelCreate(parent, 0, title.cstring, title.len)

proc addSeparator(parent: ptr Element) =
  discard labelCreate(parent, 0, separator.cstring, separator.len)

proc addPickerField(parent: ptr Element, title, value: string,
                    invoke: proc (cp: pointer) {.cdecl.}): ptr Button =
  ## Picker fields: clickable button showing current value, opens a
  ## UIMenu popup auto-positioned below the button.
  addTitle(parent, title)
  let btn = buttonCreate(parent, 0, value.cstring, value.len)
  btn.invoke = invoke
  addSeparator(parent)
  btn

proc addTextField(parent: ptr Element, title, initial: string,
                  sideMargin: cint): ptr Textbox =
  ## `sideMargin` is the width of the spacers on each side of the
  ## textbox inside its row; the textbox itself gets
  ## `row.width - 2*sideMargin`. Larger margin = narrower textbox.
  addTitle(parent, title)
  let row = panelCreate(parent, PANEL_HORIZONTAL or ELEMENT_H_FILL)
  discard spacerCreate(addr row.e, sideMargin)
  let tb = textboxCreate(addr row.e, ELEMENT_H_FILL)
  tb.setText(initial)
  discard spacerCreate(addr row.e, sideMargin)
  addSeparator(parent)
  tb

proc addMaskedField(parent: ptr Element, title, initial: string,
                    sideMargin: cint): ptr MaskedTextbox =
  addTitle(parent, title)
  let row = panelCreate(parent, PANEL_HORIZONTAL or ELEMENT_H_FILL)
  discard spacerCreate(addr row.e, sideMargin)
  let mt = maskedTextboxCreate(addr row.e, ELEMENT_H_FILL)
  if initial.len > 0:
    mt.value = initial
    mt.caret = initial.len
  discard spacerCreate(addr row.e, sideMargin)
  addSeparator(parent)
  mt

proc addFsRadio(parent: ptr Element, active: string) =
  addTitle(parent, "Filesystem")
  let row = panelCreate(parent, PANEL_HORIZONTAL or ELEMENT_H_FILL)
  let ext4Flags  = if active == "ext4":  BUTTON_CHECKED else: 0'u32
  let btrfsFlags = if active == "btrfs": BUTTON_CHECKED else: 0'u32
  gFsExt4Btn  = buttonCreate(addr row.e, ext4Flags,  "ext4",  -1)
  gFsBtrfsBtn = buttonCreate(addr row.e, btrfsFlags, "btrfs", -1)
  gFsExt4Btn.invoke  = fsExt4Invoke
  gFsBtrfsBtn.invoke = fsBtrfsInvoke
  addSeparator(parent)

proc buildForm(parent: ptr Element) =
  buildHeading(parent, "=== unrawk installer ===")

  # Pickers — UIMenu auto-positions below the parent button.
  gKbdBtn = addPickerField(parent, "Keyboard", gForm.keyboard, kbdPickerInvoke)
  gTzBtn  = addPickerField(parent, "Timezone", gForm.timezone, tzPickerInvoke)

  # Side margins control textbox width. Window is 480 wide:
  #   hostname/user → ~1/3 of window → margin 160 (textbox ≈ 160)
  #   password      → ~1/2 of window → margin 120 (textbox ≈ 240)
  #   luks          → near-full       → margin 20  (textbox ≈ 440)
  gHostnameTb = addTextField(parent,   "Hostname", gForm.hostname,       160)
  gUserTb     = addTextField(parent,   "User",     gForm.user,           160)
  gPasswordTb = addMaskedField(parent, "Password", gForm.password,       120)

  gDiskBtn = addPickerField(parent, "Disk", gForm.disk, diskPickerInvoke)

  gLuksTb     = addMaskedField(parent, "LUKS",     gForm.luksPassphrase, 20)

  addFsRadio(parent, gForm.filesystem)

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

  discard labelCreate(parent, 0, "WARNING: this wipes the disk above.".cstring, -1)
  discard labelCreate(parent, 0, "There is no undo.".cstring, -1)
  discard labelCreate(parent, 0, separator.cstring, separator.len)

  let back = buttonCreate(parent, 0, "Back", -1)
  back.invoke = backInvoke
  let wipe = buttonCreate(parent, 0, "Wipe and install", -1)
  wipe.invoke = wipeInvoke

proc executeTickerMessage(e: ptr Element, m: Message, di: cint, dp: pointer): cint {.cdecl.}

proc wrapLogLine(line: string, width: int): seq[string] =
  ## Word-boundary wrap so long [exec]/[write] entries (the xbps-install
  ## one is ~90 chars) become multiple UI rows instead of overflowing.
  ## Continuation lines get two-space indent so they read as continued.
  ## The on-disk transcript / headless golden is unaffected; this is
  ## purely a UI concern.
  if line.len <= width:
    return @[line]
  var cur = ""
  var first = true
  for word in line.split(' '):
    let prefix = if first or cur.len == 0: "" else: " "
    if cur.len + prefix.len + word.len <= width:
      cur.add(prefix)
      cur.add(word)
    else:
      if cur.len > 0:
        result.add(cur)
        first = false
      cur = "  " & word
  if cur.len > 0: result.add(cur)

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
    for piece in wrapLogLine(line, uiLineCharLimit):
      discard labelCreate(addr gLogParentPanel.e, 0, piece.cstring, piece.len)
    inc gShownLogCount

  if gInstallState.finished:
    # On success: reveal both Reboot and Shell. On failure: Shell only —
    # disk is half-written, no clean reboot, drop the user into a
    # terminal to investigate / fix / re-run.
    if gShellBtn != nil and (gShellBtn.e.flags and ELEMENT_HIDE) != 0:
      gShellBtn.e.flags = gShellBtn.e.flags and not ELEMENT_HIDE
    if gInstallState.failedStep.isNone and
       gRebootBtn != nil and (gRebootBtn.e.flags and ELEMENT_HIDE) != 0:
      gRebootBtn.e.flags = gRebootBtn.e.flags and not ELEMENT_HIDE

  elementRefresh(addr gScreenPanel.e)

proc initExecute() =
  gInstallState = newInstallState(gForm)
  gInstallLogBuf = new(seq[string])
  gInstallLogBuf[] = @[]
  gInstallLogger = newBufferLogger(gInstallLogBuf, redactSecrets = true)
  # Interactive Execute always uses the dry-run Runner for now —
  # for-real interactive UI lands in a later step once the form has
  # real inputs and the confirm screen owns the disk-arming click.
  gInstallRunner = newDryRunner(gInstallLogger)
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
    # Children are about to be marked for destroy. Clear globals that
    # point into the outgoing screen's tree so later code (callbacks,
    # refresh procs) can't dereference torn-down elements.
    gHostnameTb = nil
    gUserTb     = nil
    gPasswordTb = nil
    gLuksTb     = nil
    gFsExt4Btn  = nil
    gFsBtrfsBtn = nil
    gKbdBtn     = nil
    gTzBtn      = nil
    gDiskBtn    = nil
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

proc snapshotForm() =
  ## Copy current widget values into gForm. Called before any screen
  ## transition out of the form, including picker open (so when the
  ## form rebuilds after a selection, textbox state isn't wiped).
  if gHostnameTb != nil: gForm.hostname       = readText(gHostnameTb)
  if gUserTb     != nil: gForm.user           = readText(gUserTb)
  if gPasswordTb != nil: gForm.password       = gPasswordTb.value
  if gLuksTb     != nil: gForm.luksPassphrase = gLuksTb.value
  # Radio + picker values are already in gForm — radio invokes update
  # immediately, pickers update in pickerItemInvoke before the rebuild.

proc installInvoke(cp: pointer) {.cdecl.} =
  snapshotForm()
  switchScreen(scConfirm)

# ---------- picker invokes ----------

proc openPicker(parentBtn: ptr Button, field: PickerField,
                items: seq[PickerItem]) =
  ## Build a UIMenu below the parent button and show it. luigi
  ## auto-positions menus under their parent element (see
  ## luigi.h:10234) — exactly the dropdown affordance we want.
  if parentBtn == nil or items.len == 0: return
  gPickerField = field
  gPickerItems = items
  let menu = menuCreate(addr parentBtn.e, 0'u32)
  for i, item in items:
    menuAddItem(menu, 0,
      item.display.cstring, item.display.len,
      pickerItemInvoke, cast[pointer](i))
  menuShow(menu)

proc kbdPickerInvoke(cp: pointer) {.cdecl.} =
  openPicker(gKbdBtn, pkfKeyboard, keyboardItems())

proc tzPickerInvoke(cp: pointer) {.cdecl.} =
  openPicker(gTzBtn, pkfTimezone, timezoneItems())

proc diskPickerInvoke(cp: pointer) {.cdecl.} =
  openPicker(gDiskBtn, pkfDisk, detectDisks())

proc pickerItemInvoke(cp: pointer) {.cdecl.} =
  let idx = cast[int](cp)
  if idx < 0 or idx >= gPickerItems.len: return
  let value = gPickerItems[idx].value
  # Snapshot first so any in-progress typing in hostname/user/password
  # textboxes survives the form rebuild.
  snapshotForm()
  case gPickerField
  of pkfKeyboard: gForm.keyboard = value
  of pkfTimezone: gForm.timezone = value
  of pkfDisk:     gForm.disk     = value
  of pkfNone:     return
  switchScreen(scForm)

proc setFsChecked(active: string) =
  ## Toggle BUTTON_CHECKED on the two filesystem radio buttons so the
  ## visual reflects which is active. Mutating flags + repainting works
  ## for in-place state changes (no layout shift, no re-create needed).
  if gFsExt4Btn == nil or gFsBtrfsBtn == nil: return
  if active == "ext4":
    gFsExt4Btn.e.flags  = gFsExt4Btn.e.flags  or BUTTON_CHECKED
    gFsBtrfsBtn.e.flags = gFsBtrfsBtn.e.flags and not BUTTON_CHECKED
  else:
    gFsExt4Btn.e.flags  = gFsExt4Btn.e.flags  and not BUTTON_CHECKED
    gFsBtrfsBtn.e.flags = gFsBtrfsBtn.e.flags or BUTTON_CHECKED
  elementRepaint(addr gFsExt4Btn.e,  nil)
  elementRepaint(addr gFsBtrfsBtn.e, nil)

proc fsExt4Invoke(cp: pointer) {.cdecl.} =
  gForm.filesystem = "ext4"
  setFsChecked("ext4")

proc fsBtrfsInvoke(cp: pointer) {.cdecl.} =
  gForm.filesystem = "btrfs"
  setFsChecked("btrfs")

proc backInvoke(cp: pointer) {.cdecl.} =
  switchScreen(scForm)

proc wipeInvoke(cp: pointer) {.cdecl.} =
  switchScreen(scExecute)

# ---------- execute ticker body ----------

proc executeTickerMessage(e: ptr Element, m: Message, di: cint, dp: pointer): cint {.cdecl.} =
  if m == msgAnimate:
    if not gInstallState.finished:
      tick(gInstallState, gInstallRunner)
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
  ## is skipped (host-variable; would flake goldens). Mode comes from
  ## the CLI: dry-run by default, for-real iff --for-real passed AND
  ## the live-ISO marker exists (already enforced by parseCli +
  ## enforceForRealMarker before we get here).
  let l = newFileLogger(stdout, redactSecrets = true)
  let form = if cfg.seedPath.len > 0: cfg.seed else: defaultForm
  if cfg.seedPath.len > 0:
    l.logUserInput(seedKvs(cfg.seed))
  let runner = case cfg.mode
    of rmDryRun:  newDryRunner(l)
    of rmForReal: newForRealRunner(l)
  var state = newInstallState(form)
  state.drainSync(runner)

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
