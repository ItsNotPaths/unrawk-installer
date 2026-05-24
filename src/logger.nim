## Structured log writer for unrawk-installer test mode.
##
## Every install-flow event goes through this so dry-run mode produces a
## deterministic, golden-diffable transcript. Secrets (passwords / LUKS
## passphrases) are masked when `redactSecrets` is true.
##
## Format mirrors installer-spec.md "Test mode — Output format". The
## column at byte 13 lines up across entry types:
##
##   [user_input] hostname=foo user=alice ...
##   [detect]     uefi=yes nvidia=no ...
##   [exec]       parted /dev/sda mklabel gpt
##   [write]      /mnt/etc/hostname:
##   foo
##
## The sink is a closure so the same logger code drives stdout in
## headless mode and an in-memory buffer in the interactive log-tail
## panel. No syscalls live here — wrappers in step 6 will call
## `logExec` / `logWrite` instead of the real syscall when the run is dry.

import std/[strutils]

type Logger* = object
  emit*:          proc(line: string)
  redactSecrets*: bool

const tagWidth = 12   # `[user_input]` is the longest; sets the column

proc newFileLogger*(f: File = stdout, redactSecrets = true): Logger =
  let ff = f
  Logger(
    emit: proc(line: string) =
      ff.writeLine(line)
      ff.flushFile(),
    redactSecrets: redactSecrets,
  )

proc newBufferLogger*(buf: ref seq[string], redactSecrets = true): Logger =
  Logger(
    emit: proc(line: string) =
      buf[].add(line),
    redactSecrets: redactSecrets,
  )

proc tagPrefix(tag: string): string =
  result = "[" & tag & "]"
  while result.len < tagWidth + 1:
    result.add(' ')

proc joinKvs(l: Logger, kvs: openArray[(string, string, bool)]): string =
  ## Tuple is (key, value, isSecret). Secret values render as <key> when
  ## redaction is on, so the golden file stays free of plaintext.
  var parts: seq[string] = @[]
  for (k, v, secret) in kvs:
    let shown = if secret and l.redactSecrets: "<" & k & ">" else: v
    parts.add(k & "=" & shown)
  parts.join(" ")

proc logUserInput*(l: Logger, kvs: openArray[(string, string, bool)]) =
  l.emit(tagPrefix("user_input") & joinKvs(l, kvs))

proc logDetect*(l: Logger, kvs: openArray[(string, string, bool)]) =
  l.emit(tagPrefix("detect") & joinKvs(l, kvs))

proc logExec*(l: Logger, cmd: string, stdinSecretName: string = "") =
  ## `stdinSecretName` names a piped secret if one was used (e.g.
  ## "luks-passphrase") — rendered as `(stdin: <luks-passphrase>)`.
  if stdinSecretName.len > 0:
    l.emit(tagPrefix("exec") & cmd & "  (stdin: <" & stdinSecretName & ">)")
  else:
    l.emit(tagPrefix("exec") & cmd)

proc logWrite*(l: Logger, path: string, content: string) =
  l.emit(tagPrefix("write") & path & ":")
  for line in content.splitLines():
    l.emit(line)

proc logNote*(l: Logger, note: string) =
  ## Free-form annotation (preflight gate failures, step transitions, …).
  l.emit(tagPrefix("note") & note)
