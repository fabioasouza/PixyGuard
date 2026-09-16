# PixyGuard

Native macOS menu-bar controller and privacy automation for the EMEET PIXY camera.

PixyGuard provides direct camera controls plus automatic privacy and tracking behavior without requiring EMEET Studio.

## Features

- Camera on / Privacy controls
- AI target tracking
- Pan / tilt movement and recentering
- 1°, 3°, and 10° movement steps
- Center, Desk, Stand, and Board presets
- Privacy automatically on Mac lock / sleep
- Automatic recovery on unlock
- Automatic tracking when PIXY video is in use
- Return to idle/normal behavior when the stream closes
- Launch at Login
- Global shortcuts
- Native Apple Silicon build

## Automation behavior

Validated dogfooding flow:

- Idle → Lock → Privacy
- Idle → Unlock → exits Privacy
- Video call → Tracking
- Video call → Lock → Privacy
- Video call → Unlock → Tracking resumes

## Build

```bash
./scripts/build.sh
```

## Release

```bash
./scripts/release.sh
```

Output is written to `dist/`.

## Distribution

Public releases are published as DMG installers so testers only need to download the DMG and follow the PixyGuard Setup wizard.

## Independence and trademarks

PixyGuard is an independent project and is not affiliated with, endorsed by, or supported by EMEET.

EMEET and PIXY are trademarks of their respective owners.

Open-source attribution and third-party notices are preserved in `Installer/THIRD-PARTY-NOTICES.txt`.

## License

See `LICENSE`.
