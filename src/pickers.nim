## Curated option lists + disk detection for installer dropdowns.
##
## Keyboard and timezone are curated short lists — luigi's UIMenu is
## fine up to ~50 items but unusable at 400. A search-modal widget for
## the full tz database is a future-step item; for now this covers the
## practical default cases. Users on layouts/tz outside the curated set
## edit `/etc/vconsole.conf` and `/etc/localtime` post-install.
##
## Disk options come from `lsblk` — three columns (NAME / SIZE / MODEL)
## with the path returned as `/dev/<name>`.

import std/[osproc, strutils]

type
  PickerField* = enum
    pkfNone, pkfKeyboard, pkfTimezone, pkfDisk

  PickerItem* = object
    display*: string  ## menu label shown to the user
    value*:   string  ## what lands in gForm

# ---------- keyboard layouts ----------

const keyboardLayoutCodes* = [
  "us",  "us-dvorak", "us-colemak",
  "gb",  "ie",
  "de",  "de-nodeadkeys", "ch", "at",
  "fr",  "fr-bepo",  "be",  "ca-fr",
  "es",  "it",  "pt",  "br",
  "nl",
  "se",  "no",  "dk",  "fi",  "is",
  "pl",  "cz",  "sk",  "hu",  "ro",  "gr",
  "ru",  "ua",
  "jp",
]

proc keyboardItems*(): seq[PickerItem] =
  for code in keyboardLayoutCodes:
    result.add(PickerItem(display: code, value: code))

# ---------- timezones ----------

const commonTimezones* = [
  "UTC",
  # Americas
  "America/New_York", "America/Chicago", "America/Denver",
  "America/Los_Angeles", "America/Phoenix", "America/Anchorage",
  "America/Honolulu", "America/Toronto", "America/Vancouver",
  "America/Mexico_City", "America/Sao_Paulo", "America/Buenos_Aires",
  # Europe
  "Europe/London", "Europe/Dublin", "Europe/Paris", "Europe/Berlin",
  "Europe/Amsterdam", "Europe/Brussels", "Europe/Rome", "Europe/Madrid",
  "Europe/Lisbon", "Europe/Vienna", "Europe/Zurich", "Europe/Prague",
  "Europe/Warsaw", "Europe/Stockholm", "Europe/Oslo", "Europe/Copenhagen",
  "Europe/Helsinki", "Europe/Athens", "Europe/Bucharest", "Europe/Moscow",
  "Europe/Istanbul",
  # Asia
  "Asia/Jerusalem", "Asia/Dubai", "Asia/Mumbai", "Asia/Bangkok",
  "Asia/Singapore", "Asia/Hong_Kong", "Asia/Shanghai", "Asia/Tokyo",
  "Asia/Seoul",
  # Africa
  "Africa/Cairo", "Africa/Lagos", "Africa/Johannesburg",
  # Oceania
  "Australia/Perth", "Australia/Sydney", "Pacific/Auckland",
]

proc timezoneItems*(): seq[PickerItem] =
  for tz in commonTimezones:
    result.add(PickerItem(display: tz, value: tz))

# ---------- disk detection ----------

proc detectDisks*(): seq[PickerItem] =
  ## Parses `lsblk -dn -o NAME,SIZE,MODEL`. NAME is required; MODEL is
  ## optional (some virtual disks have none). Returns at most ~6 entries
  ## in practice — popup menu is the right widget.
  try:
    let (output, code) = execCmdEx("lsblk -dn -o NAME,SIZE,MODEL")
    if code != 0: return @[]
    for raw in output.splitLines:
      let line = raw.strip()
      if line.len == 0: continue
      let parts = line.splitWhitespace()
      if parts.len < 2: continue
      let name = parts[0]
      let size = parts[1]
      let model =
        if parts.len >= 3: parts[2 .. ^1].join(" ") else: ""
      let display =
        "/dev/" & name & "  " & size &
        (if model.len > 0: "  " & model else: "")
      result.add(PickerItem(display: display, value: "/dev/" & name))
  except CatchableError:
    discard
  if result.len == 0:
    # Always offer at least one entry so the menu is never empty —
    # falls back to the spec default. On a real install where lsblk
    # works this branch never fires.
    result.add(PickerItem(display: "/dev/sda (fallback)", value: "/dev/sda"))
