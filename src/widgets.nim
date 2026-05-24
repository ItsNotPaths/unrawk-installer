## Form widgets for unrawk-installer.
##
## Two concerns:
##
##   1. FFI-bind UITextbox from luigi.h. rawk_luigi doesn't currently
##      expose it; rather than modify the vendored binding (and pollute
##      the wayluigi tree), we declare what we need here. Promote into
##      rawk_luigi on its next bump.
##
##   2. Provide a `MaskedTextbox` widget for password input. wayluigi
##      ships no password-mask flag (`luigi.h:1` TODO confirms it's not
##      there), so we build the widget locally: caret + char buffer +
##      paint-as-asterisks. Pure Nim; no edits to vendor/.

import std/strutils
import rawk_luigi

# ---------- UITextbox FFI ----------

type Textbox* {.bycopy, importc: "UITextbox", header: "luigi.h".} = object
  e*:             Element
  cString* {.importc: "string".}: cstring  # `string` is a Nim keyword
  bytes*:         int       # C: ptrdiff_t
  carets*:        array[2, cint]
  scroll*:        cint
  rejectNextKey*: bool

proc textboxCreate*(parent: ptr Element; flags: uint32): ptr Textbox
  {.cdecl, importc: "UITextboxCreate", header: "luigi.h".}

proc textboxReplace*(tb: ptr Textbox; text: cstring; bytes: int;
                     sendChangedMessage: bool)
  {.cdecl, importc: "UITextboxReplace", header: "luigi.h".}

proc readText*(tb: ptr Textbox): string =
  ## Snapshot the textbox's current contents into a Nim string.
  if tb.cString.isNil or tb.bytes == 0:
    return ""
  result = newString(tb.bytes)
  copyMem(addr result[0], tb.cString, tb.bytes)

proc setText*(tb: ptr Textbox, s: string) =
  textboxReplace(tb, s.cstring, s.len, false)

# ---------- MaskedTextbox (custom widget) ----------
#
# `e` must be the first field — luigi expects `ptr UIElement` to point at
# the start of the struct, and we routinely cast between `ptr Element`
# and `ptr MaskedTextbox`. Nim string fields are heap-managed; we
# rebuild them in place after `elementCreate` zero-fills the struct
# (same pattern Drawk uses for its custom element).

type MaskedTextbox* {.bycopy.} = object
  e*:        Element
  value*:    string
  caret*:    int
  focused*:  bool   # toggled via msgUpdate when window->focused changes

const
  maskedTextboxPadding = 6
  cursorText           = 1.cint   # UI_CURSOR_TEXT — rawk_luigi doesn't export

proc renderDisplay(mt: ptr MaskedTextbox, focused: bool): string =
  ## Asterisks for the real characters. When focused, splice a literal
  ## '|' at the caret position so the user can see where typing lands —
  ## same trick Drawk uses for its prompt cursor (monospace font keeps
  ## the column stable).
  result = newString(mt.value.len)
  for i in 0 ..< mt.value.len: result[i] = '*'
  if focused:
    let pos = clamp(mt.caret, 0, result.len)
    result.insert("|", pos)

proc maskedTextboxMessage(e: ptr Element, m: Message,
                          di: cint, dp: pointer): cint {.cdecl.} =
  let mt = cast[ptr MaskedTextbox](e)
  let focused = e.window != nil and e.window.focused == e
  case m
  of msgPaint:
    let p = cast[ptr Painter](dp)
    let bg = if focused: ui.theme.textboxFocused else: ui.theme.textboxNormal
    drawBlock(p, e.bounds, bg)
    let display = renderDisplay(mt, focused)
    drawString(p, e.bounds, display.cstring, display.len,
               ui.theme.text, ALIGN_LEFT)
    return 1
  of msgGetWidth:
    return 200
  of msgGetHeight:
    let gh = if ui.activeFont != nil: ui.activeFont.glyphHeight else: 16.cint
    return gh + maskedTextboxPadding * 2
  of msgGetCursor:
    return cursorText
  of msgLeftDown:
    elementFocus(e)
    return 1
  of msgUpdate:
    # Window-level update (focus changed, etc) — repaint so the bg color
    # + caret reflect the new state. Mirrors UITextbox's behavior.
    elementRepaint(e, nil)
    return 0
  of msgKeyTyped:
    let k = cast[ptr KeyTyped](dp)
    if k.code == int(KEYCODE_BACKSPACE):
      if mt.caret > 0:
        mt.value.delete((mt.caret - 1) .. (mt.caret - 1))
        dec mt.caret
        elementRepaint(e, nil)
      return 1
    if k.code == int(KEYCODE_DELETE):
      if mt.caret < mt.value.len:
        mt.value.delete(mt.caret .. mt.caret)
        elementRepaint(e, nil)
      return 1
    if k.code == int(KEYCODE_LEFT):
      if mt.caret > 0:
        dec mt.caret
        elementRepaint(e, nil)
      return 1
    if k.code == int(KEYCODE_RIGHT):
      if mt.caret < mt.value.len:
        inc mt.caret
        elementRepaint(e, nil)
      return 1
    if k.code == int(KEYCODE_HOME):
      mt.caret = 0
      elementRepaint(e, nil)
      return 1
    if k.code == int(KEYCODE_END):
      mt.caret = mt.value.len
      elementRepaint(e, nil)
      return 1
    if k.text != nil and k.textBytes > 0:
      # Accept printable ASCII only — UTF-8 handling is a TODO matching
      # luigi's own Textbox limitations.
      var typed = ""
      for i in 0 ..< int(k.textBytes):
        let b = byte(cast[ptr UncheckedArray[byte]](k.text)[i])
        if b >= 0x20'u8 and b != 0x7F'u8:
          typed.add(char(b))
      if typed.len > 0:
        mt.value.insert(typed, mt.caret)
        inc mt.caret, typed.len
        elementRepaint(e, nil)
      return 1
    return 0
  of msgDestroy:
    `=destroy`(mt[])
    return 0
  else:
    return 0

proc maskedTextboxCreate*(parent: ptr Element; flags: uint32): ptr MaskedTextbox =
  let raw = elementCreate(csize_t(sizeof(MaskedTextbox)), parent,
    flags or ELEMENT_TAB_STOP, maskedTextboxMessage, "MaskedTextbox")
  result = cast[ptr MaskedTextbox](raw)
  # elementCreate zeroed the bytes; Nim-managed fields need rebuilding
  # in place so ARC tracks them correctly.
  result.value = ""
  result.caret = 0
  result.focused = false

# ---------- Spacer (fixed-width invisible filler) ----------
#
# Used to constrain textbox width inside a PANEL_HORIZONTAL row: a
# spacer of width N on each side of a `ELEMENT_H_FILL` textbox makes
# the textbox occupy `parent.width - 2*N`. No paint handler; pure
# layout.

type Spacer* {.bycopy.} = object
  e*:     Element
  width*: cint

proc spacerMessage(e: ptr Element, m: Message, di: cint, dp: pointer): cint {.cdecl.} =
  let s = cast[ptr Spacer](e)
  case m
  of msgGetWidth:  return s.width
  of msgGetHeight: return 1
  else: return 0

proc spacerCreate*(parent: ptr Element; width: cint): ptr Spacer =
  let raw = elementCreate(csize_t(sizeof(Spacer)), parent, 0,
    spacerMessage, "Spacer")
  result = cast[ptr Spacer](raw)
  result.width = width
