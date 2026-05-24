## Install state machine + dry-run tick.
##
## Models the install flow from installer-overview.md "Does" as seven
## discrete steps. Each tick of `dryRunTick` advances state by one frame
## (roughly 1/50s under wayluigi's animate cadence) and may emit log
## entries via the supplied Logger.
##
## In dry-run, the emitted entries are the canonical fake transcript:
## what the real installer *would* call, formatted exactly as step 6's
## real execution path will format it. The two paths share this module;
## step 6 swaps the `dryRunTick` body to actually shell out + write
## files, keyed off the `RunMode`.

import std/[strformat, strutils]
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

const
  stepDurationTicks* = 50   # ~1s per step at wayluigi's ~50Hz animate
  diskDevice          = "/dev/sda"   # placeholder — real disk picker lands later

proc stepDisplay*(step: InstallStep, fs: string): string =
  ## Human-readable label, with `$1` in the enum string replaced by the
  ## chosen filesystem. ext4/btrfs split is the only formatting variable
  ## right now; expand as more steps grow params.
  result = $step
  if "$1" in result:
    result = result.replace("$1", fs)

proc newInstallState*(form: FormData): InstallState =
  result.form = form
  result.currentStep = isPartition
  # all steps default to ssPending via array zero-init

# ---------- per-step fake transcripts ----------
#
# Each proc emits the [exec]/[write] entries that the real installer
# will produce in step 6. Keeping them in one spot makes the golden diff
# the source of truth for "what does this installer actually do".

proc emitPartition(s: InstallState, l: Logger) =
  l.logExec(&"parted -s {diskDevice} mklabel gpt")
  l.logExec(&"parted -s {diskDevice} mkpart ESP fat32 1MiB 513MiB")
  l.logExec(&"parted -s {diskDevice} set 1 esp on")
  l.logExec(&"parted -s {diskDevice} mkpart cryptroot 513MiB 100%")

proc emitLuks(s: InstallState, l: Logger) =
  l.logExec(&"cryptsetup luksFormat {diskDevice}2", "luks-passphrase")
  l.logExec(&"cryptsetup open {diskDevice}2 cryptroot", "luks-passphrase")

proc emitMkfs(s: InstallState, l: Logger) =
  l.logExec(&"mkfs.fat -F32 {diskDevice}1")
  let mk = if s.form.filesystem == "btrfs": "mkfs.btrfs" else: "mkfs.ext4"
  l.logExec(&"{mk} /dev/mapper/cryptroot")

proc emitMount(s: InstallState, l: Logger) =
  l.logExec("mount /dev/mapper/cryptroot /mnt")
  l.logExec("mkdir -p /mnt/boot/efi")
  l.logExec(&"mount {diskDevice}1 /mnt/boot/efi")

proc emitXbps(s: InstallState, l: Logger) =
  l.logExec(&"xbps-install -Sy -R {repoUrl} -r /mnt base-system unrawk-base")

proc emitChroot(s: InstallState, l: Logger) =
  l.logWrite("/mnt/etc/hostname", s.form.hostname)
  l.logWrite("/mnt/etc/fstab",
    "UUID=<esp-uuid>     /boot/efi  vfat  defaults  0 2\n" &
    "/dev/mapper/cryptroot  /  " & s.form.filesystem & "  defaults  0 1")
  l.logWrite("/mnt/etc/crypttab",
    "cryptroot  UUID=<luks-uuid>  none  luks")
  l.logExec(&"xchroot /mnt useradd -mG wheel {s.form.user}")
  l.logExec(&"xchroot /mnt passwd {s.form.user}", "password")
  l.logExec("xchroot /mnt passwd -l root")
  l.logWrite("/mnt/etc/locale.conf",
    "LANG=<derived-from-timezone-country>")
  l.logWrite("/mnt/etc/vconsole.conf",
    "KEYMAP=" & s.form.keyboard)
  l.logExec(&"ln -sf /usr/share/zoneinfo/{s.form.timezone} /mnt/etc/localtime")
  l.logWrite("/mnt/etc/default/grub",
    "GRUB_ENABLE_CRYPTODISK=y\n" &
    "GRUB_CMDLINE_LINUX=\"rd.luks.uuid=<luks-uuid>\"")
  l.logExec("xchroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=unrawk")
  l.logExec("xchroot /mnt grub-mkconfig -o /boot/grub/grub.cfg")
  l.logExec("xchroot /mnt xbps-reconfigure -f linux<v>")

proc emitUnmount(s: InstallState, l: Logger) =
  l.logExec("umount /mnt/boot/efi")
  l.logExec("umount /mnt")
  l.logExec("sync")

proc emitStep(s: InstallState, step: InstallStep, l: Logger) =
  case step
  of isPartition: emitPartition(s, l)
  of isLuks:      emitLuks(s, l)
  of isMkfs:      emitMkfs(s, l)
  of isMount:     emitMount(s, l)
  of isXbps:      emitXbps(s, l)
  of isChroot:    emitChroot(s, l)
  of isUnmount:   emitUnmount(s, l)

# ---------- the tick ----------

proc dryRunTick*(state: var InstallState, l: Logger) =
  ## One frame's worth of advance. Called by the UI ticker and (without
  ## delays) by the headless driver until `state.finished` is true.
  if state.finished: return

  if state.tickInStep == 0:
    # Step just transitioned to running. Emit its log block all at once;
    # in dry-run the "step duration" is purely cosmetic so the user can
    # see the step-list state change before the next one runs.
    state.stepStates[state.currentStep] = ssRunning
    l.logNote("start: " & stepDisplay(state.currentStep, state.form.filesystem))
    emitStep(state, state.currentStep, l)

  inc state.tickInStep

  if state.tickInStep >= stepDurationTicks:
    state.stepStates[state.currentStep] = ssDone
    state.tickInStep = 0
    if state.currentStep == InstallStep.high:
      state.finished = true
      l.logNote("install complete")
    else:
      state.currentStep = succ(state.currentStep)

proc runHeadless*(state: var InstallState, l: Logger) =
  ## Drains the whole tick loop synchronously — no animation, just the
  ## transcript. Used by both the headless CLI mode and the golden test
  ## harness; produces the same bytes either way.
  while not state.finished:
    dryRunTick(state, l)
