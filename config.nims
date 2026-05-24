switch("mm", "arc")
switch("panics", "on")

# rawk-luigi looks for wayluigi at vendor/wayluigi relative to its own
# source dir. We vendor flat (no nested vendor/), so redirect it.
switch("define", "rawkLuigiVendor=" & thisDir() & "/vendor/wayluigi")

# Make src/ + vendored rawk-luigi visible so module imports work without
# --path on every invocation.
switch("path", thisDir() & "/src")
switch("path", thisDir() & "/vendor/rawk-luigi/src")

when defined(release):
  switch("opt", "size")
  switch("passC", "-Os -flto -ffunction-sections -fdata-sections -fno-strict-aliasing -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-stack-protector")
  switch("passL", "-flto -s -Wl,--gc-sections -Wl,--as-needed")
