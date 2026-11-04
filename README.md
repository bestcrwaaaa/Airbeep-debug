# AirBeep

> 🌍 **Languages:** English | [简体中文 (Simplified Chinese)](./README_zh-CN.md)

AirBeep is an iOS utility that silences the built-in call-recording disclosure tones. Back up the original tones first, then silence the start and stop sounds with equal-length silence, and restore the originals from the backup whenever you want.


## Features

- Separate actions: back up the original tones, silence them, and restore them — no ambiguous switch state.
- The originals can be backed up before any change; the backup is kept and never overwritten.
- File read-back verification after every write.
- One-tap restoration from the local backup.
- Advanced settings with a custom device IP and a live network-interface table for the loopback connection.
- English and Simplified Chinese UI.

## Debug console (this fork)

This fork adds a **debug console** to AirBeep: a path field, a text editor and six
operations that turn one into the other, all riding the same AirLift escape the tone
tooling already uses. Open it with the terminal icon in the toolbar.

| Action | What it does |
|---|---|
| **Read** | Reads the file at the path through the AirLift escape and shows it in the editor. A binary file is shown as a hex dump. |
| **Write** | Writes the current payload to the path through the AirLift escape — the whole payload, or only the selected slice. |
| **Select content** | Picks a character range out of the editor: copy it, keep only it, or write only it to the device. |
| **Import** | Takes a file from the Files app and keeps its bytes. It can be written to the device as-is, or loaded into the editor. |
| **Export** | Prepares the current payload as a real file, then hands it to the share sheet (AirDrop, Save to Files) or to the Files app. |

The payload for a write or an export comes from one of three sources: the **editor**,
the **imported** file, or the bytes of the **device** file that was read last.

Implementation notes:

- The vendored `AirliftFFI.xcframework` already exposes `al_exploit_read_file` (one
  absolute path, raw bytes out) and `al_exploit_write_dir` (a staging directory into
  one target directory), so the console needs **no new native code** — it reuses
  `AirliftToneTransport` and only changes the paths.
- A single payload is capped at 8 MiB.
- The write confirmation is explicit on purpose: the write lands outside the app's
  sandbox, on the device, with no undo.

**Use it on a device you own.** A console that writes into the device filesystem is a
research instrument, not something to point at somebody else's phone.

## How it works

AirBeep requests scoped container access for these system files:

- `/var/mobile/Library/CallServices/Greetings/default/StartDisclosureWithTone.m4a`
- `/var/mobile/Library/CallServices/Greetings/default/StartDisclosure.caf` (not shipped on every iOS release — skipped when absent)
- `/var/mobile/Library/CallServices/Greetings/default/StopDisclosure.caf`

The replacement files are based on the silent assets from AirliftSilence and keep the original durations. Backups are stored in the app's Documents directory under `AirBeepBackups`.

## Requirements

- A physical iPhone or iPad running one of the supported iOS/iPadOS releases:
  - **iOS/iPadOS 18.0 – 27.2 B2** — later versions are not supported.
- Xcode 27 or newer for local builds.
- The provided GitHub Actions workflow builds an unsigned IPA in the cloud.

> AirBeep relies on non-public system behavior. Compatibility can change between iOS releases. Removing a recording disclosure can affect whether another party is notified that a call is being recorded. Use the app only where permitted by local law and with the required consent.

## Build

Open `airbeep.xcodeproj`, select the `airbeep` target, set your signing team, and build to a physical device.

For an unsigned IPA, run the `Release unsigned IPA` workflow in GitHub Actions. The artifact is named `airbeep-v<version>-unsigned.ipa`.

### Custom connection target

Set the `AIRLIFT_TARGET_HOST` build setting to LocalDevVPN's **Device IP** (default: `10.7.0.1`). The app configures the native library once at startup, so setup checks and tone operations use the same target without resetting it before each file operation.

First rebuild the patched native library with `scripts/build-airlift-xcframework.sh`, then build Release with `DEVELOPMENT_TEAM=<team> AIRLIFT_TARGET_HOST=<peer IP>`.

On iOS 26.4 and later, legacy Lockdown loopback connections also depend on the physical Wi-Fi subnet. Configure both LocalDevVPN addresses for the actual network, check for address conflicts, and use precise routes rather than changing an existing proxy configuration. Reconfigure after changing Wi-Fi subnets. Target selection alone does not guarantee system-file access or successful tone replacement.

## Credits

- [AirliftSilence](https://github.com/YiHoooong/AirliftSilence) for the silent tone assets and replacement research.
- [airlift](https://github.com/0xjohnnydev/airlift) by 0xjohnny for the AirTraffic and Airlock research retained in the project dependencies.
- [Placard](https://github.com/frs0n/placard) contributors for the original iOS project structure and container-access implementation.

## License

AirBeep is released under the [GNU General Public License v3.0](LICENSE).
# Airbeep-debug
