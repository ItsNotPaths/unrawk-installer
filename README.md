# unrawk-installer

TUI-on-Wayland installer for the unrawk distro. Hand-rolled in Nim on
[wayluigi](https://github.com/ItsNotPaths/wayluigi) /
[rawk-luigi](https://github.com/ItsNotPaths/rawk-luigi). Ships in the
unrawk live ISO; drives the install via a floating-centered form pane
(see [installer-spec.md](installer-spec.md) for UI shape and
[installer-overview.md](installer-overview.md) for the partition / LUKS /
xbps-install / chroot steps).

## Build

```
./download-deps.sh
nim c -d:wayland -d:release -o:./unrawk_installer src/unrawk_installer.nim
```

Or use `./release.sh --local` to build into `../unrawk-installer-release/`.

## Sway integration

Add this to `~/.config/sway/config` so the window lands floating-centered
at map time, with no tile-then-float flash:

```
for_window [title="^unrawk-installer$"] \
    floating enable, resize set width 480 height 800, move position center
```

Title-match (not `app_id`) is used because wayluigi sets the window title
unconditionally before the first surface commit, while `app_id` arrives
after. Reload with `swaymsg reload`. The shipped live-ISO sway config will
include this rule pre-baked. The installer also self-floats via swaymsg
IPC at startup as a fallback — but that path is post-map and produces a
visible jolt, so the `for_window` rule is the real fix.

Dimensions must match across:

- `windowW` / `windowH` in `src/unrawk_installer.nim`
- the `for_window` rule above
- the `selfFloat` swaymsg in the same source file

Pick once, change in lockstep.

## Theming

Reads `~/.config/unrawk/active.theme` (whatever Thrawk last wrote). Falls
back to a baked-in gruvbox material dark palette if missing or unparseable.

## License

GPL-3.0-only.
