# Package
version = "0.1.0"
author = "Roni Hokkanen"
description = "Simple multiplayer Pong game using Naylib and replay system"
srcDir = "src"
binDir = "bin"
namedBin["Pong"] = "pong"
backend = "c"
license = "MIT"

# Dependencies
requires "nim >= 2.2.10"
requires "naylib >= 26.8.0"
requires "confutils"
requires "flatty"
requires "vmath"

requires "https://github.com/status-im/nim-unittest2"

task test, "Run the multiplayer replay tests":
  exec "nim c --hints:off --outdir:bin -r tests/MultiplayerReplayTests.nim"
