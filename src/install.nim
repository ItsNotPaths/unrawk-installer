## Install state machine + Runner.
##
## Models the install flow from installer-overview.md "Does" as seven
## discrete steps. The `Runner` abstracts "log and maybe execute" so the
## per-step procs are mode-agnostic: dry-run only logs the intended
## action, for-real logs + actually runs it. Same code path either way.
##
## Each `runStep*` returns `bool`. False propagates up the tick loop and
## sets `state.failedStep` / `state.finished`; the UI then reveals the
## Shell button (not Reboot) and pinning the failure on the last step.
##
## In dry-run mode the produced transcript is the canonical "what the
## installer would do" record — committed under tests/golden/ and
## diff-checked. for-real mode adds `> stdout` log lines per command and
## `FAIL exit=N` annotations on non-zero exits.

import std/[os, osproc, options, strformat, strutils]
import logger, runmode

type
  InstallStep* = enum
    isPartition  = "Partition disk (GPT: ESP + LUKS container)"
    isLuks       = "LUKS format + open as cryptroot"
    isMkfs       = "mkfs (FAT on ESP, $1 on cryptroot)"
    isMount      = "Mount cryptroot at /mnt + ESP at /mnt/boot/efi"
    isXbps       = "xbps-install base-system + unrawk-base"
    isChroot     = "xchroot configure (hostname, fstab, users, grub, locale)"
    isUnmount    = "Unmount + sync"

  StepState* = enum
    ssPending, ssRunning, ssDone, ssFailed

  InstallState* = object
    form*:        FormData
    stepStates*:  array[InstallStep, StepState]
    currentStep*: InstallStep
    tickInStep*:  int
    finished*:    bool
    failedStep*:  Option[InstallStep]

  Runner* = object
    mode*:   RunMode
    logger*: Logger

const
  stepDurationTicks* = 50            # ~1s per step at wayluigi's animate
  diskDevice          = "/dev/sda"   # placeholder; real picker is step 7+

# ---------- runner ----------

proc newDryRunner*(l: Logger): Runner =
  Runner(mode: rmDryRun, logger: l)

proc newForRealRunner*(l: Logger): Runner =
  Runner(mode: rmForReal, logger: l)

proc exec*(r: Runner, cmd: string,
           stdinSecretName = "", stdinValue = ""): bool =
  ## Logs the command, then in for-real mode actually runs it. Non-zero
  ## exit returns false. Stdout/stderr are echoed line-by-line as
  ## `> ...` notes so the log tail mirrors what the user would see on a
  ## terminal.
  r.logger.logExec(cmd, stdinSecretName)
  if r.mode == rmDryRun: return true
  let (output, code) = execCmdEx(cmd, input = stdinValue)
  for line in output.splitLines:
    if line.len > 0:
      r.logger.logNote("> " & line)
  if code != 0:
    r.logger.logNote(&"FAIL exit={code}")
    return false
  true

proc place*(r: Runner, path: string, content: string): bool =
  ## "place" rather than "write" to avoid name collision with stdlib
  ## File.write / writeFile. Same semantics: log + (for-real) create
  ## parent dirs + write the file.
  r.logger.logWrite(path, content)
  if r.mode == rmDryRun: return true
  try:
    createDir(parentDir(path))
    writeFile(path, content)
    return true
  except CatchableError as e:
    r.logger.logNote("FAIL write: " & e.msg)
    return false

# ---------- per-step bodies ----------

proc runPartition(s: InstallState, r: Runner): bool =
  if not r.exec(&"parted -s {diskDevice} mklabel gpt"): return false
  if not r.exec(&"parted -s {diskDevice} mkpart ESP fat32 1MiB 513MiB"): return false
  if not r.exec(&"parted -s {diskDevice} set 1 esp on"): return false
  if not r.exec(&"parted -s {diskDevice} mkpart cryptroot 513MiB 100%"): return false
  true

proc runLuks(s: InstallState, r: Runner): bool =
  let pw = s.form.luksPassphrase
  if not r.exec(&"cryptsetup luksFormat {diskDevice}2",
                "luks-passphrase", pw & "\n"): return false
  if not r.exec(&"cryptsetup open {diskDevice}2 cryptroot",
                "luks-passphrase", pw & "\n"): return false
  true

proc runMkfs(s: InstallState, r: Runner): bool =
  if not r.exec(&"mkfs.fat -F32 {diskDevice}1"): return false
  let mk = if s.form.filesystem == "btrfs": "mkfs.btrfs" else: "mkfs.ext4"
  if not r.exec(&"{mk} /dev/mapper/cryptroot"): return false
  true

proc runMount(s: InstallState, r: Runner): bool =
  if not r.exec("mount /dev/mapper/cryptroot /mnt"): return false
  if not r.exec("mkdir -p /mnt/boot/efi"): return false
  if not r.exec(&"mount {diskDevice}1 /mnt/boot/efi"): return false
  true

proc runXbps(s: InstallState, r: Runner): bool =
  if not r.exec(&"xbps-install -Sy -R {repoUrl} -r /mnt base-system unrawk-base"):
    return false
  true

proc runChroot(s: InstallState, r: Runner): bool =
  if not r.place("/mnt/etc/hostname", s.form.hostname): return false
  if not r.place("/mnt/etc/fstab",
    "UUID=<esp-uuid>     /boot/efi  vfat  defaults  0 2\n" &
    "/dev/mapper/cryptroot  /  " & s.form.filesystem & "  defaults  0 1"): return false
  if not r.place("/mnt/etc/crypttab",
    "cryptroot  UUID=<luks-uuid>  none  luks"): return false
  if not r.exec(&"xchroot /mnt useradd -mG wheel {s.form.user}"): return false
  if not r.exec(&"xchroot /mnt passwd {s.form.user}",
                "password", s.form.password & "\n" & s.form.password & "\n"): return false
  if not r.exec("xchroot /mnt passwd -l root"): return false
  if not r.place("/mnt/etc/locale.conf",
    "LANG=<derived-from-timezone-country>"): return false
  if not r.place("/mnt/etc/vconsole.conf",
    "KEYMAP=" & s.form.keyboard): return false
  if not r.exec(&"ln -sf /usr/share/zoneinfo/{s.form.timezone} /mnt/etc/localtime"):
    return false
  if not r.place("/mnt/etc/default/grub",
    "GRUB_ENABLE_CRYPTODISK=y\n" &
    "GRUB_CMDLINE_LINUX=\"rd.luks.uuid=<luks-uuid>\""): return false
  if not r.exec("xchroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=unrawk"):
    return false
  if not r.exec("xchroot /mnt grub-mkconfig -o /boot/grub/grub.cfg"): return false
  if not r.exec("xchroot /mnt xbps-reconfigure -f linux<v>"): return false
  true

proc runUnmount(s: InstallState, r: Runner): bool =
  if not r.exec("umount /mnt/boot/efi"): return false
  if not r.exec("umount /mnt"): return false
  if not r.exec("sync"): return false
  true

proc runStep(s: InstallState, r: Runner): bool =
  case s.currentStep
  of isPartition: runPartition(s, r)
  of isLuks:      runLuks(s, r)
  of isMkfs:      runMkfs(s, r)
  of isMount:     runMount(s, r)
  of isXbps:      runXbps(s, r)
  of isChroot:    runChroot(s, r)
  of isUnmount:   runUnmount(s, r)

# ---------- public API ----------

proc stepDisplay*(step: InstallStep, fs: string): string =
  result = $step
  if "$1" in result:
    result = result.replace("$1", fs)

proc newInstallState*(form: FormData): InstallState =
  result.form = form
  result.currentStep = isPartition

proc tick*(state: var InstallState, r: Runner) =
  ## One frame's advance. UI calls this from msgAnimate; headless calls
  ## it in a tight loop until `state.finished` flips.
  if state.finished: return

  if state.tickInStep == 0:
    state.stepStates[state.currentStep] = ssRunning
    r.logger.logNote("start: " & stepDisplay(state.currentStep, state.form.filesystem))
    let ok = runStep(state, r)
    if not ok:
      state.stepStates[state.currentStep] = ssFailed
      state.failedStep = some(state.currentStep)
      state.finished = true
      r.logger.logNote("FAILED at step: " &
                       stepDisplay(state.currentStep, state.form.filesystem))
      return

  inc state.tickInStep

  if state.tickInStep >= stepDurationTicks:
    state.stepStates[state.currentStep] = ssDone
    state.tickInStep = 0
    if state.currentStep == InstallStep.high:
      state.finished = true
      r.logger.logNote("install complete")
    else:
      state.currentStep = succ(state.currentStep)

proc drainSync*(state: var InstallState, r: Runner) =
  ## Synchronously drain the tick loop to completion. Used by headless
  ## mode and the golden test harness — produces the same transcript
  ## bytes either way.
  while not state.finished:
    tick(state, r)
