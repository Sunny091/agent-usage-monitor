# Agent usage monitor

A tiny native macOS menu bar app that shows your **Claude** and **Codex** usage limits and service status at a glance.

```
Claude ▬▬░░ 2%    Codex ▬░░░ 7%
       ▬▬▬░ 18%
```

- **Menu bar:** each service gets mini bars. The top bar is the 5-hour session limit and the bottom bar is the weekly limit. Green means fine, orange is 70% or more, red is 90% or more. A small dot appears next to a name when that service is having an incident.
- **Click** to open a panel with progress bars, percent used and left, reset countdowns, plan badges, and live status from status.claude.com and status.openai.com.
- **Choose your agents:** open the panel’s gear menu to show Claude, Codex, or both. Your selection is saved on this Mac.
- **Starts automatically** at login.
- **No dependencies:** a single Swift file, compiled on your machine.

## Install

Requirements: macOS 14 or later, plus Xcode Command Line Tools. The installer offers to install the Command Line Tools if they're missing.

```bash
git clone https://github.com/Sunny091/agent-usage-monitor.git
cd agent-usage-monitor
./install.sh
```

The installer asks whether to enable usage limits (see [Privacy](#privacy)). You can also skip the question:

```bash
./install.sh --with-limits   # show usage limits
./install.sh --privacy       # status pages only, never reads any credentials
```

To update, run `git pull && ./install.sh`. To uninstall, run `./uninstall.sh`.

## Choose which agents appear

Click the menu bar app, then the **gear icon** beside Refresh. The **Visible agents** popover has a switch for each agent, with a label showing whether it appears in the menu bar. For a Codex-only setup, turn **Claude** off and leave **Codex** on. Changes apply immediately to both the menu bar and the detail panel, and persist after restarting or reinstalling the app.

Both agents are shown by default. Hidden agents are no longer polled, and their saved logins are not read for new requests. If you turn off both agents, a settings icon stays in the menu bar so you can turn them back on.

## Privacy

This repository contains **no keys, accounts or personal data**. The app has two modes:

| Mode | What it reads | What it sends, and to whom |
|---|---|---|
| **Privacy mode** (default) | Nothing on your Mac | Anonymous `GET` requests to the public status pages `status.claude.com` and `status.openai.com` |
| **Usage limits** (opt-in) | The login that **Claude Code** already saved (macOS Keychain item `Claude Code-credentials`) and that **Codex CLI** already saved (`~/.codex/auth.json`) | The access token, sent only to the official usage endpoints `api.anthropic.com/api/oauth/usage` and `chatgpt.com/backend-api/wham/usage` |

In usage-limits mode the app:

- never writes, stores, logs, or refreshes credentials, so it can't break your CLI logins;
- never sends anything to third-party servers, and has no analytics or telemetry;
- reads your password nowhere. The Keychain is accessed through Apple's `/usr/bin/security` tool.

You can switch modes at any time with the **Show usage limits** toggle at the bottom of the panel. All of the code is in [`Sources/main.swift`](Sources/main.swift), so you can audit it.

## How it works

- **Usage limits:** Claude is polled at most every 3 minutes, because its usage endpoint rate-limits aggressively. It backs off to 5–30 minutes after a `429` and keeps showing the last good numbers. Codex and the status pages refresh every 60 seconds, after waking from sleep, and when you open the panel.
- **Launch at login:** a user LaunchAgent at `~/Library/LaunchAgents/io.github.agent-usage-monitor.plist`.
- **The app** is installed to `~/Applications/AgentUsageMonitor.app`, ad-hoc signed, and runs without a Dock icon.

## Troubleshooting

| Message | Fix |
|---|---|
| `Not logged in to Claude Code` / `Codex` | Install the CLI and log in (`claude`, `codex login`). |
| `Token expired – open the CLI once to refresh` | Run `claude` or `codex` once. The CLI refreshes its own token. |
| `Usage API is rate limiting` | Wait. The app retries automatically. |
| Nothing in the menu bar | The menu bar may be full. Hide other icons, or hold ⌘ and drag icons to make room. |

The usage endpoints are undocumented and may change without notice.

## License

MIT
