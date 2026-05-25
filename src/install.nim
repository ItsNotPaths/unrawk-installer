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

proc lookupUuid(part: string, r: Runner): string =
  ## Read the filesystem (or LUKS container) UUID for a partition via
  ## `blkid -s UUID -o value`. In dry-run mode returns a stable
  ## placeholder so the transcript stays diffable across boots — the
  ## real partitions don't exist yet anyway. Empty string on failure
  ## (caller fails the step). Logs the lookup so the transcript shows
  ## what UUIDs got baked into /etc/fstab etc.
  if r.mode == rmDryRun:
    r.logger.logExec("blkid -s UUID -o value " & part & "  (dry-run)")
    return "DRY-RUN-UUID-" & part
  r.logger.logExec("blkid -s UUID -o value " & part)
  let (output, code) = execCmdEx("blkid -s UUID -o value " & part)
  if code != 0:
    r.logger.logNote(&"FAIL blkid {part}: exit={code}")
    return ""
  let uuid = output.strip()
  r.logger.logNote("> " & uuid)
  uuid

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

  # 3-partition LUKS-root layout:
  #   p1   1..513 MiB   FAT32 ESP            (mounted at /boot/efi)
  #   p2   513..1537 MiB ext4 /boot          (UNENCRYPTED — GRUB reads
  #                                           grub.cfg + kernel + initramfs
  #                                           from here, so no cryptodisk
  #                                           dance in the EFI binary.)
  #   p3   1537..end    LUKS-encrypted /     (cryptsetup open → /dev/mapper/cryptroot)
  #
  # Threat model: /boot is public (kernel binary, initramfs cpio,
  # grub.cfg with the LUKS UUID — none of these are secrets). All user
  # data, /etc/shadow, ssh host keys, dotfiles, etc. live on p3 and stay
  # encrypted. Evil-maid attacks on /boot need Secure Boot or TPM-sealing
  # to mitigate; encrypted /boot is not a meaningful defense against that
  # threat (the EFI binary remains unencrypted regardless).
  if not r.exec(&"parted -s {disk} mklabel gpt"): return false
  if not r.exec(&"parted -s {disk} mkpart ESP fat32 1MiB 513MiB"): return false
  if not r.exec(&"parted -s {disk} set 1 esp on"): return false
  if not r.exec(&"parted -s {disk} mkpart boot ext4 513MiB 1537MiB"): return false
  if not r.exec(&"parted -s {disk} mkpart cryptroot 1537MiB 100%"): return false

  # Force the kernel to re-read the new table, then wait for udev to
  # finish creating the partition device nodes before mkfs tries to
  # open them.
  if not r.exec(&"partprobe {disk}"): return false
  if not r.exec("udevadm settle"): return false
  true

proc runLuks(s: InstallState, r: Runner): bool =
  let pw = s.form.luksPassphrase
  let p3 = partDev(s.form.disk, 3)
  if not r.exec(&"cryptsetup luksFormat {p3}",
                "luks-passphrase", pw & "\n"): return false
  if not r.exec(&"cryptsetup open {p3} cryptroot",
                "luks-passphrase", pw & "\n"): return false
  true

proc runMkfs(s: InstallState, r: Runner): bool =
  let p1 = partDev(s.form.disk, 1)
  let p2 = partDev(s.form.disk, 2)
  if not r.exec(&"mkfs.fat -F32 {p1}"): return false
  # -F forces mkfs.ext4 over a partition that may still have a stale
  # signature from a previous install (the disk-level wipefs only nuked
  # the GPT, not the inside-partition fs signatures).
  if not r.exec(&"mkfs.ext4 -F {p2}"): return false
  let mk = if s.form.filesystem == "btrfs": "mkfs.btrfs -f" else: "mkfs.ext4 -F"
  if not r.exec(&"{mk} /dev/mapper/cryptroot"): return false
  true

proc runMount(s: InstallState, r: Runner): bool =
  let p1 = partDev(s.form.disk, 1)
  let p2 = partDev(s.form.disk, 2)
  # Order matters: root first, then /boot inside it, then /boot/efi
  # inside that. xbps-install -r /mnt later writes packages into /mnt and
  # everything below it; with the mounts already in place, kernel files
  # land on p2 and the EFI binary lands on p1 automatically.
  if not r.exec("mount /dev/mapper/cryptroot /mnt"): return false
  if not r.exec("mkdir -p /mnt/boot"): return false
  if not r.exec(&"mount {p2} /mnt/boot"): return false
  if not r.exec("mkdir -p /mnt/boot/efi"): return false
  if not r.exec(&"mount {p1} /mnt/boot/efi"): return false
  true

proc runXbps(s: InstallState, r: Runner): bool =
  # -C /tmp/unrawk-xbpsd points xbps at an empty confdir so the install
  # is hermetic: only the -R repo is consulted, regardless of what the
  # live env (or, later, anything pre-staged on /mnt) has in xbps.d.
  # Today /mnt is empty at this step so the isolation is implicit; the
  # explicit form survives future changes (e.g. rsync-copy install).
  #
  # Only unrawk-base — NOT base-system. build_iso.sh passes `-b unrawk-base`
  # to mklive, so the offline bundle has unrawk-base + its transitive
  # closure, and `base-system` itself is never downloaded. unrawk-base is
  # the curated replacement (see meta/build-meta.sh "Base subset").
  if not r.exec("mkdir -p /tmp/unrawk-xbpsd"): return false
  # `yes |` answers xbps's repo-key trust prompt. xbps-install -y skips
  # the transaction confirmation but NOT the per-repo XBPS_STATE_REPO_
  # KEY_IMPORT prompt (xbps/bin/xbps-install/state_cb.c:154-158 calls
  # yesno() unconditionally). Without a 'y' on stdin, fgetc() returns
  # EOF and yesno() defaults to false → xbps returns EAGAIN with the
  # message "failed to import pubkey: resource temporarily unavailable".
  # `yes` is in coreutils; SIGPIPE retires it when xbps-install exits.
  if not r.exec(&"yes | xbps-install -C /tmp/unrawk-xbpsd -Sy -R {repoUrl} -r /mnt unrawk-base"):
    return false
  true

proc runChroot(s: InstallState, r: Runner): bool =
  # Resolve real UUIDs for the ESP / /boot / LUKS partitions. The
  # initramfs (built by xbps-reconfigure below) and grub need real
  # values, not the literal "<luks-uuid>"-style placeholders the original
  # scaffold had.
  let p1 = partDev(s.form.disk, 1)
  let p2 = partDev(s.form.disk, 2)
  let p3 = partDev(s.form.disk, 3)
  let espUuid  = lookupUuid(p1, r)
  let bootUuid = lookupUuid(p2, r)
  let luksUuid = lookupUuid(p3, r)
  if r.mode == rmForReal and (espUuid.len == 0 or bootUuid.len == 0 or luksUuid.len == 0):
    r.logger.logNote("FAIL UUID lookup returned empty; refusing to write fstab")
    return false

  if not r.place("/mnt/etc/hostname", s.form.hostname): return false
  if not r.place("/mnt/etc/fstab",
    &"UUID={espUuid}   /boot/efi  vfat  defaults  0 2\n" &
    &"UUID={bootUuid}  /boot      ext4  defaults  0 2\n" &
    "/dev/mapper/cryptroot  /  " & s.form.filesystem & "  defaults  0 1\n"): return false
  if not r.place("/mnt/etc/crypttab",
    &"cryptroot  UUID={luksUuid}  none  luks\n"): return false

  # audio,video,input cover the standard Wayland desktop affordances —
  # pipewire/wireplumber audio access, drm/v4l device access, evdev
  # input for libinput. wheel gates su/doas. Match what mklive's live
  # adduser.sh hands the live user (modulo input which we add for sway
  # compositor permissions on seatd-less setups).
  if not r.exec(&"xchroot /mnt useradd -mG audio,video,input,wheel {s.form.user}"): return false
  if not r.exec(&"xchroot /mnt passwd {s.form.user}",
                "password", s.form.password & "\n" & s.form.password & "\n"): return false
  if not r.exec("xchroot /mnt passwd -l root"): return false

  # Hardcoded en_US.UTF-8 for now — proper timezone→locale derivation is
  # nontrivial (en_GB vs en_US for English speakers, fr_CA vs fr_FR for
  # French, etc.) and the form doesn't yet expose a locale picker.
  if not r.place("/mnt/etc/locale.conf", "LANG=en_US.UTF-8\n"): return false
  if not r.place("/mnt/etc/vconsole.conf", "KEYMAP=" & s.form.keyboard & "\n"): return false
  if not r.exec(&"ln -sf /usr/share/zoneinfo/{s.form.timezone} /mnt/etc/localtime"):
    return false

  # Force-include dracut's crypt module so the initramfs can unlock
  # LUKS at boot. Without this, dracut's auto-detection sometimes
  # leaves the module out (depends on whether dm-crypt is currently
  # loaded in the live env's kernel when xbps-reconfigure runs inside
  # the chroot), and the kernel boots without ever prompting for a
  # passphrase. Symptom: fsck.ext4 errors "No such file or directory"
  # on /dev/mapper/cryptroot because cryptroot was never opened.
  if not r.place("/mnt/etc/dracut.conf.d/10-unrawk-crypt.conf",
    "# unrawk: ensure crypt support is always built into initramfs.\n" &
    "add_dracutmodules+=\" crypt \"\n"): return false

  # rd.luks.name=<UUID>=<NAME> both activates the LUKS device AND maps
  # it to /dev/mapper/<NAME>. Using rd.luks.uuid alone would name the
  # device /dev/mapper/luks-<UUID>, which wouldn't match the
  # /dev/mapper/cryptroot path in /etc/fstab → fstab can't find root.
  # NO GRUB_ENABLE_CRYPTODISK: /boot is on the unencrypted p2
  # partition, so grub.cfg lives in plaintext and GRUB reads it
  # directly without any cryptomount dance.
  if not r.place("/mnt/etc/default/grub",
    &"GRUB_CMDLINE_LINUX=\"rd.luks.name={luksUuid}=cryptroot\"\n"): return false
  # No --modules needed: with /boot unencrypted, GRUB reads kernel +
  # initramfs + grub.cfg from a plain ext4 partition that the firmware
  # has handed it via UEFI block I/O services. The LUKS unlock happens
  # entirely in the initramfs after GRUB has already done its job.
  if not r.exec("xchroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=unrawk --recheck"):
    return false
  if not r.exec("xchroot /mnt grub-mkconfig -o /boot/grub/grub.cfg"): return false

  # -a reconfigures every installed package. This is the right hammer
  # here because (a) we just wrote /etc/fstab + /etc/crypttab + grub
  # cmdline that the kernel package's post-install hook needs to see in
  # order to bake the right initramfs, and (b) the actual kernel pkg
  # name is version-suffixed on Void (linux6.12 etc.) so we can't pin
  # `-f <pkgname>` without runtime detection.
  if not r.exec("xchroot /mnt xbps-reconfigure -a"): return false
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
