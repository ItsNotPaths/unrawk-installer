## iwd shell-out helpers for the scNetwork preamble screen.
##
## All iwctl interaction lives here. The screen layer in
## unrawk_installer.nim only sees plain Nim types — it doesn't shell out
## itself. Three operations:
##
##   - detectWirelessDevice — find the first powered station interface
##   - scanNetworks         — `iwctl station <dev> get-networks` + parse
##   - connect              — `iwctl station <dev> connect` with optional
##                            --passphrase
##
## iwctl auto-detects the AP's security type from the scan — the user
## never picks it. We parse it out of the listing so the UI can label
## rows and so we know whether to pass --passphrase, but it's
## informational, not a control.

import std/[options, os, osproc, strformat, strutils, times]
import logger

type
  Security* = enum
    secOpen   = "open"
    secPsk    = "psk"
    sec8021x  = "8021x"
    secUnknown

  Network* = object
    ssid*:      string
    security*:  Security
    signalDbm*: int       ## 0 if unparseable

  ConnectResult* = object
    ok*:           bool
    profilePath*:  string   ## /var/lib/iwd/<encoded>.<type> if connected
    error*:        string

# ---------- ANSI stripping ----------

proc stripAnsi(s: string): string =
  ## iwctl pretty-prints with CSI sequences (colors + cursor moves).
  ## Drop everything between ESC[ and the final byte in [@-~]. Keeps the
  ## rest of the bytes verbatim so SSID column alignment survives.
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if s[i] == '\x1b' and i + 1 < s.len and s[i + 1] == '[':
      i += 2
      while i < s.len and not (s[i] in {'@' .. '~'}):
        inc i
      if i < s.len: inc i  # consume final byte
    else:
      result.add(s[i])
      inc i

# ---------- device detection ----------

proc parseDeviceList(text: string): string =
  ## `iwctl device list` prints rows like:
  ##   wlan0   aa:bb:..   on   phy0   station
  ## We want the first row whose Powered==on and Mode==station. The
  ## column order is fixed (luaclient iwd reorder-station upstream).
  for raw in text.splitLines():
    let line = stripAnsi(raw).strip()
    if line.len == 0: continue
    let parts = line.splitWhitespace()
    # Header rows have "Name" / "Devices" etc — skip anything that
    # doesn't have 5 columns and a recognisable Powered value.
    if parts.len < 5: continue
    if parts[2] != "on": continue
    if parts[4] != "station": continue
    return parts[0]
  return ""

proc detectWirelessDevice*(l: Logger): string =
  ## Returns the interface name (e.g. "wlan0") or "" if no powered
  ## station is found. iwd's device names vary by hardware; we don't
  ## hardcode wlan0. iwctl is in iwd-pkg, present on every live ISO via
  ## defaults/INSTALL enabling iwd.
  l.logExec("iwctl device list")
  try:
    let (output, code) = execCmdEx("iwctl device list")
    if code != 0:
      l.logNote(&"iwctl device list: exit={code}")
      return ""
    let dev = parseDeviceList(output)
    if dev.len == 0:
      l.logNote("no powered station device found")
    return dev
  except CatchableError as e:
    l.logNote("iwctl device list failed: " & e.msg)
    return ""

# ---------- scan + parse ----------

proc parseSecurity(s: string): Security =
  case s.toLowerAscii()
  of "open":   secOpen
  of "psk":    secPsk
  of "8021x":  sec8021x
  else:        secUnknown

proc parseGetNetworks*(text: string): seq[Network] =
  ## `iwctl station <dev> get-networks rssi-dbms` output looks like:
  ##
  ##                  Available networks
  ##   -------------------------------------------------
  ##                  Network name   Security   Signal
  ##   -------------------------------------------------
  ##     >            MyHomeAP       psk        -52
  ##                  Coffee Shop    open       -68
  ##
  ## The `>` marks the currently-connected network; column boundaries
  ## are whitespace runs but SSIDs can contain spaces. Parse from the
  ## right: last token is signal (signed int dBm), second-to-last is
  ## security keyword, everything before that is the SSID.
  for raw in text.splitLines():
    let line = stripAnsi(raw).strip()
    if line.len == 0: continue
    # Skip separators ('---'), title row, and the column header itself.
    # We key on whether the *second-to-last* whitespace-token is a known
    # security keyword — a robust positive signal that this row is data.
    let parts = line.splitWhitespace()
    if parts.len < 3: continue
    let secWord = parts[^2]
    let sec = parseSecurity(secWord)
    if sec == secUnknown: continue
    # Signal: signed integer in dBm. iwctl may render asterisks instead
    # when get-networks is run WITHOUT `rssi-dbms`; tolerate either.
    var signal = 0
    try:
      signal = parseInt(parts[^1])
    except ValueError:
      signal = 0
    # SSID is everything left of security. Strip the leading `>` marker
    # if present; trim. We rejoin with single spaces — that loses
    # internal whitespace runs (rare) but keeps comparison stable for
    # the connect call.
    var ssidParts = parts[0 .. parts.len - 3]
    if ssidParts.len > 0 and ssidParts[0] == ">":
      ssidParts = ssidParts[1 .. ^1]
    if ssidParts.len == 0: continue
    let ssid = ssidParts.join(" ")
    result.add(Network(ssid: ssid, security: sec, signalDbm: signal))

proc scanNetworks*(device: string, l: Logger): seq[Network] =
  ## Triggers a fresh scan (best-effort — `iwctl station scan` is
  ## non-blocking; results stream into iwd's cache) then reads the
  ## current visible-network list. Returns an empty seq if either step
  ## fails — the screen layer renders that as "(no networks found)".
  if device.len == 0: return @[]
  let scanCmd = "iwctl station " & quoteShell(device) & " scan"
  l.logExec(scanCmd)
  discard execShellCmd(scanCmd & " >/dev/null 2>&1")
  # iwd needs a brief moment to populate the cache after the scan
  # request — without this the get-networks call usually returns the
  # pre-scan snapshot. 800ms matches iwd upstream's default scan
  # dwell time on a single 2.4GHz radio.
  sleep(800)
  let listCmd = "iwctl station " & quoteShell(device) & " get-networks rssi-dbms"
  l.logExec(listCmd)
  try:
    let (output, code) = execCmdEx(listCmd)
    if code != 0:
      l.logNote(&"get-networks: exit={code}")
      return @[]
    result = parseGetNetworks(output)
  except CatchableError as e:
    l.logNote("get-networks failed: " & e.msg)
    return @[]

# ---------- connect + profile lookup ----------

proc findProfileSince*(dir: string, since: Time): Option[string] =
  ## After a successful `iwctl connect`, iwd writes the profile to
  ## /var/lib/iwd/<encoded>.<type>. The encoding (hex-escape for chars
  ## outside iwd's safe set) is non-trivial; rather than recompute it,
  ## scan /var/lib/iwd/ for the file with the most recent mtime newer
  ## than `since`. Robust against SSIDs with spaces, non-ASCII, etc.
  if not dirExists(dir): return none(string)
  var best: string = ""
  var bestT: Time
  for kind, path in walkDir(dir):
    if kind != pcFile: continue
    let ext = path.splitFile().ext
    if ext notin [".psk", ".open", ".8021x"]: continue
    let mt = getLastModificationTime(path)
    if mt < since: continue
    if best.len == 0 or mt > bestT:
      best = path
      bestT = mt
  if best.len > 0: some(best) else: none(string)

proc connect*(device, ssid: string, security: Security,
              passphrase: string, l: Logger): ConnectResult =
  ## Returns {ok, profilePath, error}. 8021x is refused at this layer —
  ## the UI greys those rows out, this is the belt-and-braces refuse.
  if security == sec8021x:
    return ConnectResult(ok: false,
      error: "8021x (enterprise) networks need a provisioning file; " &
             "skip and configure post-install")
  if security == secUnknown:
    return ConnectResult(ok: false, error: "unsupported security type")

  let before = getTime()
  # iwctl's --passphrase flag takes the value inline. We pass it BEFORE
  # the `station` subcommand because iwctl's option parser is strictly
  # leading-flags-then-subcommand. For open networks we omit the flag
  # entirely — iwd would reject --passphrase on an open AP.
  let pwFlag =
    if security == secPsk and passphrase.len > 0:
      " --passphrase=" & quoteShell(passphrase)
    else:
      ""
  let cmd = "iwctl" & pwFlag &
            " station " & quoteShell(device) &
            " connect " & quoteShell(ssid)
  # Mask the passphrase in the log — same shape as the LUKS stdin
  # secret elsewhere in the install flow.
  let loggedCmd =
    if pwFlag.len > 0:
      "iwctl --passphrase=<wifi-passphrase> station " &
        quoteShell(device) & " connect " & quoteShell(ssid)
    else:
      cmd
  l.logExec(loggedCmd)
  try:
    let (output, code) = execCmdEx(cmd)
    if code != 0:
      let errMsg = output.strip().splitLines()[^1]
      l.logNote(&"connect failed: exit={code} {errMsg}")
      return ConnectResult(ok: false,
        error: if errMsg.len > 0: errMsg else: "connect failed")
    let profile = findProfileSince("/var/lib/iwd", before)
    return ConnectResult(
      ok: true,
      profilePath: if profile.isSome: profile.get else: "",
    )
  except CatchableError as e:
    l.logNote("iwctl connect raised: " & e.msg)
    return ConnectResult(ok: false, error: e.msg)
