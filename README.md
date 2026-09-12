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
│ macOS Menu Bar: [ 5HL=85% (4:30 PM)  We=90%  Ctx=30% ]       │
└──────────────────────────────────────────────────────────────┘
```

</div>

---

## 🌟 Features

- **⚡️ Real-Time Rate Limit Monitoring**: See your **5-hour rolling limit** and **weekly limit** directly in your menu bar (`5HL=85% (4:30 PM)  We=90%`).
- **🧠 Active Chat Context Window Tracking**: Displays the current conversation's context window usage percentage (`Ctx=30%`) in real-time, extracted directly from local Codex session rollout logs with exact input token counts and total model headroom.
- **🚨 Smart Threshold Popups & Notifications**:
  - **5-Hour Limit**: Screen popup reminder at every 10% drop (90%, 80%, 70%, 60%, 50%, 40%, 30%, 20%, 10%).
  - **Weekly Limit**: Warning popups on the screen when reaching **70%**, **50%**, **30%**, and **10%**.
- **🔴 Red Zone Visual Alert**:
  - Whenever the 5-hour limit or weekly limit drops to **10% or less**, the menu bar turns into an eye-catching **bold red alert** (`🔴` or `⚠️`), returning to normal when reset or above 10%.
- **⏱ Live Countdown Timers**: View exact timestamps and ticking countdowns until limit resets.
- **🎨 Customizable Display Styles**:
  - `Standard`: `5HL=85% (4:30 PM)  We=90%  Ctx=30%` (Default)
  - `Compact`: `5h: 85% (4:30 PM) | W: 90% | C: 30%`
  - `Emoji`: `⏱ 85% (4:30 PM) | 📅 90% | 🧠 30%`
  - `Minimal`: `85% (4:30 PM) / 90% / 30%`
- **🔄 Configurable Refresh Intervals**: 5 seconds (Real-time), 15s, 30s, or 60s.
- **🛡 Privacy-First & 100% Local**: No telemetry, no external servers, no proxy.
- **🪶 Ultra Lightweight**: Native Swift & AppKit binary. Negligible CPU and memory footprint.
- **🚀 Zero Dock Footprint**: Configured with `LSUIElement` to run exclusively in the menu bar.
- **⚙️ Launch at Login**: Built-in 1-click toggle to automatically start on login.

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
  │ 🧠  Context Window: 30% full (76,000 / 258,400 tokens)   │
  │      Session: ...3d203d97 • 70% headroom                 │
  ├──────────────────────────────────────────────────────────┤
  │ Synced: 2:15:40 PM (every 5s)                            │
  ├──────────────────────────────────────────────────────────┤
  │ 🔄  Refresh Now                                       ⌘R │
  │ ✓ Show 5h Reset Time in Bar                              │
  │ ✓ Show Context Window % in Bar                           │
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
