# PixyBar

Unofficial native macOS menu-bar controller for the EMEET PIXY camera.

PixyBar gives you quick access to camera power, AI tracking, pan/tilt movement, recentering, presets, launch at login, and global shortcuts without opening EMEET Studio.

```text
Platform: macOS 13+
Architecture: Native Apple Silicon when built on Apple Silicon
Language: Swift + C
License: MIT
```
<img width="272" height="552" alt="588055126-c0fa95ab-afb0-4307-8e93-76e825ed12fd" src="https://github.com/user-attachments/assets/f014584d-8bad-4d34-8172-2ca31b99a85d" />

## Features

- Camera on/off controls
- AI tracking mode toggle
- Directional pan/tilt buttons
- Recenter button
- 1, 3, and 10 degree movement steps
- Center, Desk, Stand, and Board presets
- Launch at Login toggle
- Global shortcuts
- Standalone `pixyctl` command-line helper
- No EMEET Studio install required

## Global Shortcuts

```text
Control-Option-Command + Arrow keys   Move camera
Control-Option-Command + C            Recenter
Control-Option-Command + T            Toggle tracking
```

## Apple Silicon

PixyBar is native on Apple Silicon when built on an Apple Silicon Mac. The build script uses `swiftc` and `clang` without forcing an Intel target, so the app and helper are built for the host architecture.

Verify the built binaries with:

```sh
file PixyBar.app/Contents/MacOS/PixyBar
file PixyBar.app/Contents/MacOS/pixyctl
```

On Apple Silicon, both should report `arm64`.

## Build

Requirements:

- macOS 13 or newer
- Xcode Command Line Tools
- EMEET PIXY connected over USB

Build the app:

```sh
./scripts/build.sh
```

Run it:

```sh
open ./PixyBar.app
```

## CLI

The menu-bar app calls the bundled `pixyctl` helper. You can also use it directly:

```sh
./PixyBar.app/Contents/MacOS/pixyctl status
./PixyBar.app/Contents/MacOS/pixyctl get-mode
./PixyBar.app/Contents/MacOS/pixyctl get-track
./PixyBar.app/Contents/MacOS/pixyctl mode tracking
./PixyBar.app/Contents/MacOS/pixyctl mode privacy
./PixyBar.app/Contents/MacOS/pixyctl move left
./PixyBar.app/Contents/MacOS/pixyctl recenter
./PixyBar.app/Contents/MacOS/pixyctl position 0 -12
```

## Tracking Note

AI tracking only visibly follows when another app has the camera video stream open. A normal camera app can keep the stream active; EMEET Studio is not required.

## Unofficial Project

PixyBar talks directly to the PIXY over macOS IOKit HID. This repository does not include EMEET binaries, libraries, source code, artwork, logos, or product assets.

PixyBar is not affiliated with, endorsed by, or supported by EMEET. EMEET and PIXY are trademarks of their respective owners.

## License

MIT. See [LICENSE](LICENSE).
