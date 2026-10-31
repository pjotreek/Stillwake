# Stillwake

Keep your MacBook running with the lid closed — and the screen actually off.

Stillwake is a small menu bar app. Hold **fn** while you close the lid and your Mac keeps working: builds, downloads, AI agents, anything. The built-in display goes to sleep and the session locks, so a closed-lid Mac idles at well under a watt.

## Features

- **Hold fn, close the lid.** A full-screen depth animation follows the lid as it closes. Once the ring turns green (around 40°) you can let go of fn — the Mac stays on until you open the lid again.
- **Timers.** Turn it on indefinitely or for 15 minutes to 8 hours, like a classic keep-awake app.
- **AI agents.** While Claude Code, Codex or OpenCode is working on a task, closing the lid won't stop it. When the last agent finishes, Stillwake lets the Mac sleep.
- **Screen off, session locked.** When the lid shuts, the built-in display is put to sleep and the screen is locked. The backlight is what makes other closed-lid setups expensive.
- **Safeguards.** Stops at a battery level you choose (10% by default) and when the Mac gets too hot with the lid closed.
- **Nothing left behind.** Sleep is restored whenever Stillwake stops holding the Mac — on quit, on crash (a tiny watchdog process handles that) and on the next launch.

## Power

Measured on a MacBook Pro (M3 Pro), lid closed, display asleep, everyday apps still open and Wi-Fi on:

| | Average | Lowest |
|---|---|---|
| Stillwake | 2.64 W | 0.64 W |

Stillwake itself uses 0% CPU and no timer wakeups while idle; the lid sensor is only read while fn is held. Measure your own Mac with `tools/powertest.sh <label> [seconds]`.

## Install

1. Download `Stillwake-<version>.dmg` from [Releases](../../releases) and drag **Stillwake** to **Applications**.
2. The app is not notarized. On first launch macOS will block it: open **System Settings → Privacy & Security** and click **Open Anyway**. Or run:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Stillwake.app
   ```
3. Allow **Input Monitoring** when asked. Stillwake only listens for the fn key.
4. Optional: in the menu, choose **Show Live Screen in Lid Animation…** to allow Screen Recording. Without it the animation uses a plain backdrop.

Requires macOS 14 or later. The lid animation needs a MacBook with a lid angle sensor (most recent models); on other Macs the fn hold still works, without the animation.

## Lid-closed mode

macOS normally sleeps the moment the lid closes. Stillwake can stop that in two ways:

- **Without a password** it uses the same internal power management switch macOS uses for closed-lid operation. This works on many setups but not on every macOS version.
- **Lid-Closed Mode** (recommended): choose **Set Up Lid-Closed Mode…** in the menu and enter your password once. Stillwake adds `/etc/sudoers.d/stillwake`, which allows exactly these two commands without a password and nothing else:
  ```
  /usr/bin/pmset -a disablesleep 1
  /usr/bin/pmset -a disablesleep 0
  ```
  Remove it any time from the menu, or with `sudo rm /etc/sudoers.d/stillwake`.

Never run a closed Mac in a bag or on a soft surface. The thermal safeguard is a stop condition, not a guarantee.

## AI agents

Open **Connected Agents** in the menu and tick the tools you use. Stillwake adds small hooks to:

- Claude Code — `~/.claude/settings.json`
- Codex — `~/.codex/hooks.json` (Codex may ask you to trust the new hooks)
- OpenCode — `~/.config/opencode/plugins/stillwake.js`

A backup of each config is saved next to it the first time. The hooks only report "working" and "finished" with a session id — no prompts, code or output leave the agent.

## Uninstall

1. Untick every agent under **Connected Agents**, and remove Lid-Closed Mode if you set it up.
2. Quit Stillwake and move it to the Trash.
3. Optionally delete `~/Library/Application Support/Stillwake`.

## Build from source

```sh
./build.sh      # builds build/Stillwake.app (universal, ad-hoc signed)
./release.sh    # builds dist/Stillwake-<version>.dmg
```

Only the Xcode Command Line Tools are needed.

## Credits

The closing-lid depth effect is adapted from [Mac Duo](https://github.com/sumimakito/Mac-Duo) by Makito, licensed under Apache-2.0. See [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt).

## License

[Apache-2.0](LICENSE)
