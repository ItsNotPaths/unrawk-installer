## Pre-flight gates for unrawk-installer.
##
## Four refuse-to-start checks (root / UEFI / network / disk) plus one
## side-detection (nvidia GPU). Gates are pure data — they don't touch
## any UI; the installer's main module renders the error screen based on
## what runPreflight returns.
##
## See installer-spec.md "Pre-flight gates" for the contract.

import std/[os, osproc, strutils]
import std/posix
import runmode

type Gate* = object
  name*:   string   # short id used in logs (root / uefi / network / disk)
  ok*:     bool
  reason*: string   # empty when ok; one-line failure description otherwise

type Preflight* = object
  gates*:  seq[Gate]
  nvidia*: bool     # side-detection; not a gate

# repoUrl + repoProbePath now live in runmode.nim so install.nim can use
# the same constant without taking a preflight dependency.

proc gateRoot(): Gate =
  let uid = posix.getuid()
  if uid == 0.Uid:
    Gate(name: "root", ok: true)
  else:
    Gate(name: "root", ok: false,
         reason: "Not running as root (uid=" & $int(uid) & ")")

proc gateUefi(): Gate =
  if dirExists("/sys/firmware/efi"):
    Gate(name: "uefi", ok: true)
  else:
    Gate(name: "uefi", ok: false,
         reason: "Not booted in UEFI mode (no /sys/firmware/efi)")

proc gateDisk(): Gate =
  try:
    let (output, code) = execCmdEx("lsblk -dn -o NAME,SIZE,MODEL")
    if code == 0 and output.strip().len > 0:
      Gate(name: "disk", ok: true)
    else:
      Gate(name: "disk", ok: false,
           reason: "No disks visible via lsblk")
  except CatchableError as e:
    Gate(name: "disk", ok: false, reason: "lsblk failed: " & e.msg)

proc gateNetwork(): Gate =
  ## HEAD the repodata under the unrawk repo URL. 5s timeout so a dead
  ## network doesn't hang the gate check.
  try:
    let cmd = "curl -fsSI --max-time 5 " & quoteShell(repoUrl & repoProbePath) &
              " >/dev/null 2>&1"
    let code = execShellCmd(cmd)
    if code == 0:
      Gate(name: "network", ok: true)
    else:
      Gate(name: "network", ok: false,
           reason: "Cannot reach " & repoUrl)
  except CatchableError as e:
    Gate(name: "network", ok: false, reason: "curl failed: " & e.msg)

proc detectNvidia(): bool =
  ## Side-detection, not a gate — passed downstream so chroot config can
  ## conditionally install the nvidia pkg + set nvidia-drm.modeset=1.
  try:
    let (output, code) = execCmdEx("lspci -nn")
    if code != 0: return false
    let lc = output.toLowerAscii()
    return "nvidia" in lc and ("vga" in lc or "3d controller" in lc)
  except CatchableError:
    return false

proc runPreflight*(): Preflight =
  ## Runs every gate. Returns the full set (including passing ones) so
  ## the caller can render either the error screen or, eventually, a
  ## successful pre-flight summary in dry-run mode.
  result.gates = @[
    gateRoot(),
    gateUefi(),
    gateNetwork(),
    gateDisk(),
  ]
  result.nvidia = detectNvidia()

proc failed*(p: Preflight): seq[Gate] =
  for g in p.gates:
    if not g.ok: result.add(g)
