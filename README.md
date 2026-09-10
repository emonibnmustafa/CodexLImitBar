<div align="center">

# ⚡️ CodexLImitBar for macOS

**A native, ultra-lightweight macOS menu bar app that displays your ChatGPT 5-Hour rolling window and Weekly usage limits in real-time.**

[![macOS](https://img.shields.io/badge/macOS-12.0%2B-blue?logo=apple&style=flat-square)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6.0-orange?logo=swift&style=flat-square)](https://swift.org)
[![License](https://img.shields.io/badge/License-MIT-green.svg?style=flat-square)](LICENSE)
[![Zero Dependencies](https://img.shields.io/badge/Dependencies-0-brightgreen?style=flat-square)](#)

<br/>

```text
┌──────────────────────────────────────────────────────────────┐
│ macOS Menu Bar: [ 5HL=85% (4:30 PM)  We=90% ]                │
└──────────────────────────────────────────────────────────────┘
```

</div>

---

## 🌟 Features

- **⚡️ Real-Time Monitoring**: See both your **5-hour rolling limit** and **weekly limit** directly in your menu bar (`5HL=85% (4:30 PM)  We=90%`).
- **⏱ Live Countdown Timers**: Click the menu item to see the exact time and live ticking countdown until your limits reset.
- **🎨 Customizable Display Styles**:
  - `Standard`: `5HL=85% (4:30 PM)  We=90%` (Default)
  - `Compact`: `5h: 85% (4:30 PM) | W: 90%`
  - `Emoji`: `⏱ 85% (4:30 PM) | 📅 90%`
  - `Minimal`: `85% (4:30 PM) / 90%`
- **🔄 Configurable Refresh Intervals**: Choose between **5 seconds** (Real-time), 15s, 30s, or 60s directly from the dropdown.
- **🛡 Privacy-First & 100% Local**: No external analytics, no third-party servers, no proxy. Credentials never leave your machine.
- **🪶 Ultra Lightweight**: Native Swift & AppKit binary. Consumes **0.0% CPU** at idle and negligible memory.
- **🚀 Zero Dock Footprint**: Configured with `LSUIElement` so it lives quietly in your menu bar without cluttering your Dock or `⌘-Tab` switcher.
- **⚙️ Launch at Login**: Built-in 1-click toggle to automatically start whenever you log into macOS.

---

## 🖥 Menu Interface Preview

```text
  ┌──────────────────────────────────────────────────────────┐
  │ ChatGPT Plus • us***@example.com                         │
  │ 🟢 Status: Active                                        │
  ├──────────────────────────────────────────────────────────┤
  │ ⏱  5-Hour Limit: 85% left (15% used)                     │
  │      Resets: 4:30 PM (in 2h 14m 20s)                     │
  ├──────────────────────────────────────────────────────────┤
  │ 📅  Weekly Limit: 90% left (10% used)                     │
  │      Resets: Friday, 10:00 AM (in 4d 12h)                │
  ├──────────────────────────────────────────────────────────┤
  │ Synced: 2:15:40 PM (every 5s)                            │
  ├──────────────────────────────────────────────────────────┤
  │ 🔄  Refresh Now                                       ⌘R │
  │ ✓ Show 5h Reset Time in Bar                              │
  │ Display Style                                          > │
  │ Refresh Interval                                       > │
  │ ✓ Launch at Login                                        │
  ├──────────────────────────────────────────────────────────┤
  │ Quit CodexLImitBar                                 ⌘Q │
  └──────────────────────────────────────────────────────────┘
```

---

## 📋 Prerequisites

- **macOS 12.0 (Monterey)** or later (Apple Silicon or Intel).
- Official **ChatGPT macOS App** installed and logged into your account.
- Swift compiler (included by default on macOS with Command Line Tools: `xcode-select --install`).

---

## 🚀 Quick Start (1-Minute Installation)

### Option 1: Git Clone & Install

Open Terminal and run:

```bash
# 1. Clone this repository
git clone https://github.com/emonibnmustafa/CodexLImitBar.git
cd CodexLImitBar

# 2. Build and install
./scripts/install.sh
```

The script compiles the native Swift application, places `CodexLImitBar.app` in `~/Applications`, sets up auto-launch at login, and starts the app immediately.

---

### Option 2: Build Manually

```bash
./scripts/build.sh
open build/CodexLImitBar.app
```

---

## 🔍 How It Works Under the Hood

1. **Local Session Discovery**: The official ChatGPT macOS desktop app (`com.openai.codex`) manages authentication locally in `~/.codex/auth.json`.
2. **Real-time Capacity Queries**: The app connects directly to `https://chatgpt.com/backend-api/wham/usage` using ephemeral, cache-busting requests to fetch up-to-the-second window statistics:
   - `primary_window`: 5-hour rolling limit (`18000s`)
   - `secondary_window`: Weekly quota (`604800s`)
3. **Resilient Local Fallback**: If the web session token needs renewal, the app queries the local Codex CLI/IPC server (`account/rateLimits/read`), ensuring uninterrupted status monitoring.

---

## 🛠 Usage & Controls

Click the menu bar text (`5HL=... We=...`) to open the dropdown menu:

| Control | Description |
|---|---|
| **Usage Breakdown** | Shows current remaining percentage, used percentage, and reset timestamp. |
| **Show 5h Reset Time** | Toggle the reset timestamp in the menu bar on or off. |
| **Display Style** | Switch between Standard, Compact, Emoji, or Minimal formats on the fly. |
| **Refresh Interval** | Adjust polling frequency (5s real-time, 15s, 30s, or 60s). |
| **🔄 Refresh Now (`⌘R`)** | Immediately forces a cache-free sync. |
| **Launch at Login** | Toggle macOS LaunchAgent startup. |
| **Quit (`⌘Q`)** | Safely exits the application. |

---

## 🗑 Uninstallation

To remove the app completely from your Mac:

```bash
cd CodexLImitBar
./scripts/uninstall.sh
```

Or manually:
```bash
killall CodexLImitBar
rm -rf ~/Applications/CodexLImitBar.app
rm -f ~/Library/LaunchAgents/com.codexlimitbar.menubar.plist
```

---

## 🔒 Privacy & Security

- This app **never sends your credentials, tokens, or usage data to any third party**.
- All network requests go directly to `https://chatgpt.com` or communicate with the local ChatGPT desktop app via local Unix sockets.
- The source code is short, clean, and 100% auditable in [`src/main.swift`](src/main.swift).

---

## 🤝 Contributing

Contributions, feature suggestions, and pull requests are warmly welcome!
Feel free to open an issue or submit a PR.

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
