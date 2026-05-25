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
    # Display strings deliberately short — they're prefixed with the
    # step-state marker ("[*] " etc) in the UI, and the 480px panel
    # only fits ~50 chars in the default font.
    isPartition  = "Partition disk"
    isLuks       = "LUKS format + open"
    isMkfs       = "mkfs ($1 on cryptroot)"
    isMount      = "Mount cryptroot + ESP"
    isXbps       = "xbps-install base + unrawk"
    isChroot     = "Configure system in chroot"
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

proc partDev(disk: string, n: int): string =
  ## Build a partition device path from a disk path + index. The naming
  ## convention forks on the base name's final char:
  ##   /dev/sda   -> /dev/sda1     (SCSI/SATA)
  ##   /dev/vda   -> /dev/vda1     (virtio block)
  ##   /dev/nvme0n1 -> /dev/nvme0n1p1   (NVMe — base ends in digit)
  ##   /dev/mmcblk0 -> /dev/mmcblk0p1   (SD/eMMC — base ends in digit)
  ##   /dev/loop0   -> /dev/loop0p1     (loop — base ends in digit)
  ## Rule: separator is 'p' iff the basename's last char is a digit,
  ## because that's where bare-digit concatenation would be ambiguous
  ## with the device name itself.
  if disk.len > 0 and disk[^1] in {'0' .. '9'}:
    disk & "p" & $n
  else:
    disk & $n

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
  let disk = s.form.disk
  # Stale-state cleanup. If anything on the target disk is in use (a
  # leftover mount from a previous boot, an active LUKS mapping, swap,
  # or just udev caching an old partition node), parted writes the new
  # GPT to disk but the kernel keeps the OLD layout — the BLKPG ioctl
  # fails with "unable to inform the kernel of the change". Downstream
  # mkfs steps then format whatever the old layout pointed at.
  #
  # Each cleanup line ends with `; true` so a "nothing to clean" exit
  # doesn't abort the install. execCmdEx runs via /bin/sh -c (per Nim
  # docs) so shell features (pipes, redir, ;) work without sh -c wrap.
  if not r.exec("swapoff -a 2>/dev/null; true"): return false
  # umount anything mounted from this disk. /proc/mounts field 1 is the
  # device; index($1, d)==1 catches /dev/<disk>, /dev/<disk>{1,p1}, etc.
  if not r.exec(&"awk -v d={disk} 'index($1, d)==1 {{print $2}}' /proc/mounts | xargs -r umount -R 2>/dev/null; true"): return false
  # Close a `cryptroot` mapping if one is left over from a previous
  # attempt on this disk. (Naming is fixed in runLuks below.)
  if not r.exec("cryptsetup status cryptroot >/dev/null 2>&1 && cryptsetup close cryptroot; true"): return false
  # wipefs zeroes existing filesystem signatures so udev/blkid drop
  # their cached labels — additional persuasion for the kernel to let go.
  if not r.exec(&"wipefs -a {disk}"): return false

  # Re-create the partition table.
  if not r.exec(&"parted -s {disk} mklabel gpt"): return false
  if not r.exec(&"parted -s {disk} mkpart ESP fat32 1MiB 513MiB"): return false
  if not r.exec(&"parted -s {disk} set 1 esp on"): return false
  if not r.exec(&"parted -s {disk} mkpart cryptroot 513MiB 100%"): return false

  # Force the kernel to re-read the new table, then wait for udev to
  # finish creating the partition device nodes before mkfs tries to
  # open them.
  if not r.exec(&"partprobe {disk}"): return false
  if not r.exec("udevadm settle"): return false
  true

proc runLuks(s: InstallState, r: Runner): bool =
  let pw = s.form.luksPassphrase
  let p2 = partDev(s.form.disk, 2)
  if not r.exec(&"cryptsetup luksFormat {p2}",
                "luks-passphrase", pw & "\n"): return false
  if not r.exec(&"cryptsetup open {p2} cryptroot",
                "luks-passphrase", pw & "\n"): return false
  true

proc runMkfs(s: InstallState, r: Runner): bool =
  let p1 = partDev(s.form.disk, 1)
  if not r.exec(&"mkfs.fat -F32 {p1}"): return false
  let mk = if s.form.filesystem == "btrfs": "mkfs.btrfs" else: "mkfs.ext4"
  if not r.exec(&"{mk} /dev/mapper/cryptroot"): return false
  true

proc runMount(s: InstallState, r: Runner): bool =
  let p1 = partDev(s.form.disk, 1)
  if not r.exec("mount /dev/mapper/cryptroot /mnt"): return false
  if not r.exec("mkdir -p /mnt/boot/efi"): return false
  if not r.exec(&"mount {p1} /mnt/boot/efi"): return false
  true

proc runXbps(s: InstallState, r: Runner): bool =
  # -C /tmp/unrawk-xbpsd points xbps at an empty confdir so the install
  # is hermetic: only the -R repo is consulted, regardless of what the
  # live env (or, later, anything pre-staged on /mnt) has in xbps.d.
  # Today /mnt is empty at this step so the isolation is implicit; the
  # explicit form survives future changes (e.g. rsync-copy install).
  if not r.exec("mkdir -p /tmp/unrawk-xbpsd"): return false
  if not r.exec(&"xbps-install -C /tmp/unrawk-xbpsd -Sy -R {repoUrl} -r /mnt base-system unrawk-base"):
    return false
  true

proc runChroot(s: InstallState, r: Runner): bool =
  if not r.place("/mnt/etc/hostname", s.form.hostname): return false
  if not r.place("/mnt/etc/fstab",
    "UUID=<esp-uuid>     /boot/efi  vfat  defaults  0 2\n" &
    "/dev/mapper/cryptroot  /  " & s.form.filesystem & "  defaults  0 1"): return false
  if not r.place("/mnt/etc/crypttab",
    "cryptroot  UUID=<luks-uuid>  none  luks"): return false
  # audio,video,input cover the standard Wayland desktop affordances —
  # pipewire/wireplumber audio access, drm/v4l device access, evdev
  # input for libinput. wheel gates su/doas. Match what mklive's live
  # adduser.sh hands the live user (modulo input which we add for sway
  # compositor permissions on seatd-less setups).
  if not r.exec(&"xchroot /mnt useradd -mG audio,video,input,wheel {s.form.user}"): return false
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
  # Recursive umount picks up nested mounts (/mnt/boot/efi, plus any
  # pseudo-fs xchroot left behind if it didn't clean up). Tolerates "no
  # mounts left" exits so a clean tear-down doesn't fail the step;
  # `sync` after is the data-durability safety net before reboot.
  if not r.exec("umount -R /mnt 2>/dev/null; true"): return false
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
