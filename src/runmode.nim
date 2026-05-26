## CLI parsing, run-mode resolution, and seed-file loading.
##
## Three orthogonal axes resolve to a `RunConfig` the rest of the
## installer reads from:
##
##   - Dry-run vs `--for-real`
##       Default is dry-run. `--for-real` requires `/etc/unrawk-live-iso`
##       to be present (the live ISO marker); without it, refuse so a
##       dev box can never wipe itself by accident.
##
##   - Interactive (window) vs `--headless`
##       Headless skips wayluigi entirely. Drives the flow from a seed
##       file and writes the structured log to stdout, for golden tests.
##
##   - `--gates` (pre-flight check) on/off
##       Independent of mode. Useful for visualising the error screen
##       on a dev box. Step 4 deliberately keeps it independent;
##       step 5+ may tie `--for-real` to imply `--gates`.
##
## Seed file format: one `key=value` line per field. Unknown keys are
## ignored, blank lines and `#` comments are skipped. See
## `tests/seeds/basic.seed` for the canonical example.

import std/[os, strutils]

const
  liveIsoMarker* = "/etc/unrawk-live-iso"

  # Offline repo bundled into the live ISO by
  # Unrawk/scripts/bundle-offline-repo.sh (mklive -x postsetup). Contains
  # every .xbps mklive cached + our local-repo packages, signed by the
  # dev key already trusted in /var/db/xbps/keys on the live rootfs.
  # install.nim's xbps-install -R picks up from here without network.
  # preflight.nim's gateNetwork detects the leading '/' and switches to
  # a filesystem-existence check instead of curl.
  repoUrl*       = "/var/lib/unrawk-repo"
  repoProbePath* = "/x86_64-repodata"

type
  RunMode* = enum
    rmDryRun     ## default — no destructive actions
    rmForReal    ## actually partition / mkfs / install

  FormData* = object
    keyboard*:       string
    timezone*:       string
    hostname*:       string
    # `password` is now ROOT's password — see install.nim runChroot.
    # The previous model created a wheel-group user + locked root;
    # unrawk's design intent is pure-root single-user, no doas/sudo,
    # so the user-creation step was removed and this field sets
    # /etc/shadow's root entry via `passwd root` in xchroot.
    password*:       string
    luksPassphrase*: string
    disk*:           string
    filesystem*:     string
    # Populated by scNetwork when a wifi connection succeeded on the
    # live ISO. Empty string = preamble skipped or no connection. The
    # isSeedNetwork install step copies the corresponding iwd profile
    # into /mnt/var/lib/iwd/ so the installed system boots online.
    seededProfile*:  string

  RunConfig* = object
    mode*:      RunMode
    headless*:  bool      ## true → no UI, drive from seed, log to stdout
    runGates*:  bool      ## --gates: run pre-flight before showing UI
    seedPath*:  string    ## empty if no --seed given
    seed*:      FormData  ## populated when seedPath.len > 0

  CliError* = object of CatchableError

proc parseSeed*(path: string): FormData =
  if not fileExists(path):
    raise newException(CliError, "seed file not found: " & path)
  for rawLine in readFile(path).splitLines():
    let line = rawLine.strip()
    if line.len == 0 or line.startsWith('#'): continue
    let eq = line.find('=')
    if eq < 0: continue
    let key = line[0 ..< eq].strip()
    let value = line[eq+1 .. ^1].strip()
    case key
    of "keyboard":        result.keyboard       = value
    of "timezone":        result.timezone       = value
    of "hostname":        result.hostname       = value
    of "password":        result.password       = value
    of "luks_passphrase": result.luksPassphrase = value
    of "disk":            result.disk           = value
    of "filesystem":      result.filesystem     = value
    of "seeded_profile":  result.seededProfile  = value
    else: discard  # forward-compatible: unknown keys ignored

proc parseCli*(args: openArray[string]): RunConfig =
  ## Minimal hand-parser — small surface, no parseopt dependency. Flags:
  ##   --for-real
  ##   --headless
  ##   --gates
  ##   --seed=<path>  or  --seed <path>
  var i = 0
  while i < args.len:
    let a = args[i]
    case a
    of "--for-real":
      result.mode = rmForReal
    of "--headless":
      result.headless = true
    of "--gates":
      result.runGates = true
    of "--seed":
      if i + 1 >= args.len:
        raise newException(CliError, "--seed requires a path argument")
      result.seedPath = args[i + 1]
      inc i
    else:
      if a.startsWith("--seed="):
        result.seedPath = a[len("--seed=") .. ^1]
      else:
        raise newException(CliError, "unknown flag: " & a)
    inc i

  if result.seedPath.len > 0:
    result.seed = parseSeed(result.seedPath)

proc enforceForRealMarker*(cfg: RunConfig) =
  ## Bulletproof guard: `--for-real` is only legal when the live-ISO
  ## marker exists. On a dev box the marker is absent, so the installer
  ## cannot be tricked into doing destructive work even if `--for-real`
  ## is passed by accident.
  if cfg.mode == rmForReal and not fileExists(liveIsoMarker):
    stderr.writeLine("unrawk-installer: --for-real requires " &
                     liveIsoMarker & " (live-ISO marker).")
    stderr.writeLine("                  refusing to run; this is not the live ISO.")
    quit(1)

proc seedKvs*(s: FormData): seq[(string, string, bool)] =
  ## Convert seed into the (key, value, isSecret) form Logger.logUserInput
  ## expects. Order is stable so golden files don't churn.
  @[
    ("keyboard",        s.keyboard,       false),
    ("timezone",        s.timezone,       false),
    ("hostname",        s.hostname,       false),
    ("password",        s.password,       true),
    ("luks_passphrase", s.luksPassphrase, true),
    ("disk",            s.disk,           false),
    ("filesystem",      s.filesystem,     false),
    ("seeded_profile",  s.seededProfile,  false),
  ]
