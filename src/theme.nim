## Palette loader for unrawk-installer.
##
## Reads `~/.config/unrawk/active.theme` (whatever Thrawk last wrote) and
## applies it to wayluigi's `ui.theme`. Falls back to the baked-in gruvbox
## material dark palette if active.theme is missing or unparseable.
##
## Format and keys match the shared rawk theme files — parsePalette here
## consumes the subset wayluigi's UITheme actually uses. Unknown keys are
## silently ignored so theme files stay forward-compatible.

import std/[os, strutils]
import rawk_luigi

type Palette* = object
  bg*, fg*, accent*, muted*, urgent*: uint32
  borderLight*, borderDark*, separator*: uint32

const gruvboxMaterialDark* = Palette(
  bg:          0x292828'u32,
  fg:          0xd4be98'u32,
  accent:      0x9253be'u32,
  muted:       0x928374'u32,
  urgent:      0xea6962'u32,
  borderLight: 0x504945'u32,
  borderDark:  0x32302f'u32,
  separator:   0x45403d'u32,
)

proc parseHex(s: string): uint32 =
  let t = s.strip().strip(chars = {'#'})
  if t.len == 6:
    result = uint32(parseHexInt(t))

proc parsePalette*(content: string, p: var Palette): bool =
  if content.len == 0: return false
  for rawLine in content.splitLines():
    let line = rawLine.strip()
    if line.len == 0 or line.startsWith('#'): continue
    let colon = line.find(':')
    if colon <= 0: continue
    let key = line[0 ..< colon].strip()
    let val = parseHex(line[colon+1 .. ^1])
    case key
    of "bg":           p.bg          = val
    of "fg":           p.fg          = val
    of "accent":       p.accent      = val
    of "muted":        p.muted       = val
    of "urgent":       p.urgent      = val
    of "border_light": p.borderLight = val
    of "border_dark":  p.borderDark  = val
    of "separator":    p.separator   = val
    else: discard
  true

proc apply*(p: Palette) =
  ui.theme.panel1         = p.bg
  ui.theme.panel2         = p.borderLight
  ui.theme.selected       = p.accent
  ui.theme.border         = p.borderDark
  ui.theme.text           = p.fg
  ui.theme.textDisabled   = p.muted
  ui.theme.textSelected   = p.bg
  ui.theme.buttonNormal   = p.borderLight
  ui.theme.buttonHovered  = p.separator
  ui.theme.buttonPressed  = p.accent
  ui.theme.buttonDisabled = p.borderDark
  ui.theme.textboxNormal  = p.borderLight
  ui.theme.textboxFocused = p.separator

proc globalThemePath*(): string =
  getHomeDir() / ".config" / "unrawk" / "active.theme"

proc loadInitialTheme*() =
  ## Tries Thrawk's active.theme; on any failure falls back to the baked-in
  ## gruvbox palette. Always succeeds.
  let path = globalThemePath()
  if fileExists(path):
    try:
      var p = gruvboxMaterialDark
      if parsePalette(readFile(path), p):
        apply(p)
        return
    except IOError:
      discard
  apply(gruvboxMaterialDark)
