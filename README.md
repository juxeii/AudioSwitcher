# Audio Switcher

A tiny Windows tray app that switches your default **audio output device** with a global hotkey.

It ships as **one `.bat` file**. There is nothing to install and no SDK to download: the first time you run it, it compiles itself using the C# compiler that is already built into Windows.

<!-- Add a screenshot here, e.g. ![Tray menu and popup](docs/screenshot.png) -->

## Features

- **Global hotkey** (default `Ctrl + Alt + S`) cycles through the playback devices you picked. Left-clicking the tray icon does the same.
- **Pick your devices** from the tray menu: tick the ones you want in the cycle.
- **On-screen popup** shows the device you switched to. It never steals focus and doesn't depend on Windows notification settings (Focus Assist, Do Not Disturb, ...).
- **Sets all three default roles** (Console, Multimedia, Communications), so apps like Teams or Zoom follow the switch too.
- **Remembers your selection reliably.** Devices are stored by Windows ID *and* by a name-based fingerprint, so a selection survives most ID changes (driver updates, other USB port, ...). Devices that are unplugged stay ticked and show as "(not connected)" instead of being forgotten.
- **Change the hotkey** from the tray menu.
- **Start with Windows** toggle in the tray menu.
- **Start Menu shortcut** is created automatically, so you can launch it by pressing the Windows key and typing "Audio Switcher".
- Local only: no network access, no telemetry.

## Requirements

- Windows 10 or 11
- .NET Framework 4.x (already included with Windows; the app only needs its `csc.exe` compiler)

## Quick start

1. Download `AudioSwitcher.bat` (see [Releases](../../releases)) and put it anywhere.
2. Double-click it. The first run compiles the app, which takes a few seconds, then starts it.
3. Find the speaker icon in the system tray (it may be under the `^` arrow). Right-click it and tick the devices you want to cycle through.
4. Press `Ctrl + Alt + S` to switch to the next device.

Windows may show a SmartScreen prompt for a downloaded `.bat` file. See [Security notes](#security-notes) below.

## Usage

| Action | How |
| --- | --- |
| Switch to the next device | Hotkey, or left-click the tray icon |
| Choose which devices are in the cycle | Right-click the tray icon, tick/untick devices |
| Forget an unplugged device | Click its "(not connected)" entry in the tray menu |
| Change the hotkey | Tray menu > **Change hotkey...** |
| Turn the popup on/off | Tray menu > **Show popup when switching** |
| Launch at login | Tray menu > **Start with Windows** |
| Quit | Tray menu > **Exit** |

Hotkeys need at least one modifier (Ctrl, Alt or Shift), except F-keys. Note that a bare `Alt + <letter>` hotkey blocks that shortcut in every other program.

To remove everything (app, settings, Start Menu shortcut, autostart entry), run from a command prompt:

```
AudioSwitcher.bat /uninstall
```

## How it works

- The C# source code is embedded at the end of the `.bat` file, after the `::CSHARP_BEGIN` line.
- On first run the script extracts it to `%APPDATA%\AudioSwitcher\`, compiles it with `csc.exe` from `C:\Windows\Microsoft.NET\Framework64\v4.0.30319\`, and starts the resulting `AudioSwitcher.exe`.
- Later runs just start the compiled app. If the `.bat` is newer than the `.exe` (for example after you edit it), it rebuilds automatically.
- The tray icon, the `.exe` icon and the shortcut icon are all drawn by the same code.
- Settings live in `%APPDATA%\AudioSwitcher\config.txt` (plain text).
- Device switching uses the Windows Core Audio API for listing devices and the `IPolicyConfig` COM interface for setting the default device.

The compiler built into Windows only understands C# 5, so the source is written in that older syntax.

## Troubleshooting

- **Nothing happens when I press the hotkey.** Another program probably owns that combination. The app shows a popup in that case. Pick another one via **Change hotkey...**
- **"No devices selected" popup.** Right-click the tray icon and tick at least two devices.
- **A device I ticked disappeared from the list.** If it is unplugged or disabled it shows as "(not connected)". If a driver update renamed it, tick the renamed device once and forget the old entry.
- **I can't see the tray icon.** Look under the `^` arrow, or drag the icon onto the taskbar.
- **Build fails.** The compiler messages are shown in the console window. Please open an issue and paste them.
- **Odd icon after an update.** Windows caches icons. Restart Explorer or sign out and back in.

## Known limitations

- **Playback devices only.** Recording devices are not supported.
- **Undocumented API.** Setting the default device relies on `IPolicyConfig`, which Microsoft does not officially document. It is used by many audio tools and has been stable for years, but a future Windows update could change it.
- **Device matching is name-based as a fallback.** If an update changes a device's name, or you have two identical devices, the app can't re-link it automatically and leaves your selection alone instead of guessing.
- **The popup can't draw over exclusive-fullscreen apps** (some games). Borderless and maximized windows are fine.
- **Lightly tested.** It was developed and tested on a small number of Windows machines. Bug reports are welcome.

## Security notes

A script that compiles and launches an `.exe` can look suspicious to antivirus software or SmartScreen, so here is exactly what it does: it reads its own text, writes a `.cs` file, a `.ico` file and the compiled `.exe` to `%APPDATA%\AudioSwitcher\`, creates a Start Menu shortcut, and starts the app. It makes no network connections and needs no administrator rights. The whole source is in the file, so you can read it before running it.

## Credits

Completely vibe coded with Sonnet 5.5 High in 10 minutes!

## License

See the [LICENSE](LICENSE) file.
