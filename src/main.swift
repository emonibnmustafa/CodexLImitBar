import Cocoa
import Foundation

// MARK: - Data Models

struct AuthConfig: Codable {
    struct Tokens: Codable {
        let access_token: String?
        let account_id: String?
    }
    let tokens: Tokens?
}

struct UsageResponse: Codable {
    struct RateLimitWindow: Codable {
        let used_percent: Double?
        let limit_window_seconds: Int?
        let reset_after_seconds: Int?
        let reset_at: Int?
    }
    struct RateLimit: Codable {
        let allowed: Bool?
        let limit_reached: Bool?
        let primary_window: RateLimitWindow?
        let secondary_window: RateLimitWindow?
    }
    struct RateLimitWarning: Codable {
        let rate_limit: RateLimit?
    }
    let user_id: String?
    let email: String?
    let plan_type: String?
    let rate_limit: RateLimit?
    let rate_limit_warning: RateLimitWarning?
}

struct RateLimitData {
    let email: String
    let planType: String
    let allowed: Bool
    let fiveHPercentLeft: Int
    let fiveHUsedPercent: Double
    let weeklyPercentLeft: Int
    let weeklyUsedPercent: Double
    let fiveHResetAt: Date?
    let weeklyResetAt: Date?
    let lastUpdated: Date
}

// MARK: - Display Styles

enum DisplayStyle: String, CaseIterable {
    case standard
    case compact
    case emoji
    case minimal

    var title: String {
        switch self {
        case .standard: return "Standard (5HL=85% (4:30 PM)  We=90%)"
        case .compact:  return "Compact (5h: 85% (4:30 PM) | W: 90%)"
        case .emoji:    return "Emoji (⏱ 85% (4:30 PM) | 📅 90%)"
        case .minimal:  return "Minimal (85% (4:30 PM) / 90%)"
        }
    }

    func format(fiveH: Int, weekly: Int, resetTime: String?) -> String {
        let resetPart = (resetTime != nil && !resetTime!.isEmpty) ? " (\(resetTime!))" : ""
        switch self {
        case .standard:
            return "5HL=\(fiveH)%\(resetPart)  We=\(weekly)%"
        case .compact:
            return "5h: \(fiveH)%\(resetPart) | W: \(weekly)%"
        case .emoji:
            return "⏱ \(fiveH)%\(resetPart) | 📅 \(weekly)%"
        case .minimal:
            return "\(fiveH)%\(resetPart) / \(weekly)%"
        }
    }
}

// MARK: - Limit Fetcher

class LimitFetcher {
    static let shared = LimitFetcher()
    private var isFetching = false

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 4.0
        return URLSession(configuration: config)
    }()

    /// Dynamically locate the official ChatGPT / Codex executable across standard and mounted locations.
    private func findCodexBinary() -> String? {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            let binary = appURL.appendingPathComponent("Contents/Resources/codex").path
            if FileManager.default.isExecutableFile(atPath: binary) {
                return binary
            }
        }

        let standardCandidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex").path
        ]
        for path in standardCandidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        if let volumeUrls = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes"), includingPropertiesForKeys: nil) {
            for vol in volumeUrls {
                let candidate = vol.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources/codex").path
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }

        return nil
    }

    func fetchLimits(completion: @escaping (Result<RateLimitData, Error>) -> Void) {
        if isFetching { return }
        isFetching = true

        let home = FileManager.default.homeDirectoryForCurrentUser
        let authPath = home.appendingPathComponent(".codex/auth.json")

        guard let authData = try? Data(contentsOf: authPath),
              let auth = try? JSONDecoder().decode(AuthConfig.self, from: authData),
              let token = auth.tokens?.access_token else {
            self.fetchFromCodexCli { [weak self] res in
                self?.isFetching = false
                completion(res)
            }
            return
        }

        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            self.isFetching = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let accountId = auth.tokens?.account_id {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-ID")
        }

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                self.fetchFromCodexCli { res in
                    self.isFetching = false
                    completion(res)
                }
                return
            }

            guard let data = data, error == nil else {
                self.fetchFromCodexCli { res in
                    self.isFetching = false
                    completion(res)
                }
                return
            }

            if let usage = try? JSONDecoder().decode(UsageResponse.self, from: data) {
                let rl = usage.rate_limit ?? usage.rate_limit_warning?.rate_limit
                if let rl = rl {
                    let pUsed = rl.primary_window?.used_percent ?? 0.0
                    let sUsed = rl.secondary_window?.used_percent ?? 0.0
                    let pLeft = max(0, min(100, Int(round(100.0 - pUsed))))
                    let sLeft = max(0, min(100, Int(round(100.0 - sUsed))))

                    var d1: Date? = nil
                    if let ts1 = rl.primary_window?.reset_at {
                        d1 = Date(timeIntervalSince1970: TimeInterval(ts1))
                    }
                    var d2: Date? = nil
                    if let ts2 = rl.secondary_window?.reset_at {
                        d2 = Date(timeIntervalSince1970: TimeInterval(ts2))
                    }

                    let plan = (usage.plan_type ?? "Plus").capitalized
                    let email = usage.email ?? "ChatGPT Account"
                    let allowed = rl.allowed ?? (pLeft > 0 && sLeft > 0)

                    let rateData = RateLimitData(
                        email: email,
                        planType: plan,
                        allowed: allowed,
                        fiveHPercentLeft: pLeft,
                        fiveHUsedPercent: pUsed,
                        weeklyPercentLeft: sLeft,
                        weeklyUsedPercent: sUsed,
                        fiveHResetAt: d1,
                        weeklyResetAt: d2,
                        lastUpdated: Date()
                    )
                    self.isFetching = false
                    completion(.success(rateData))
                    return
                }
            }

            self.fetchFromCodexCli { res in
                self.isFetching = false
                completion(res)
            }
        }.resume()
    }

    private func fetchFromCodexCli(completion: @escaping (Result<RateLimitData, Error>) -> Void) {
        guard let codexPath = findCodexBinary() else {
            completion(.failure(NSError(domain: "ChatGPTLimits", code: -1, userInfo: [NSLocalizedDescriptionKey: "No codex binary or auth session found"])))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: codexPath)
            process.arguments = ["app-server", "--stdio"]

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()

                let initMsg = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"limitsbar\",\"version\":\"1.0\"}}}\n"
                let rateMsg = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"account/rateLimits/read\",\"params\":{}}\n"

                stdinPipe.fileHandleForWriting.write(initMsg.data(using: .utf8)!)
                stdinPipe.fileHandleForWriting.write(rateMsg.data(using: .utf8)!)

                let reader = stdoutPipe.fileHandleForReading
                var buffer = Data()
                var rateLimitResponseData: Data? = nil
                let startTime = Date()

                while Date().timeIntervalSince(startTime) < 4.0 {
                    let available = reader.availableData
                    if available.isEmpty {
                        usleep(30000)
                        continue
                    }
                    buffer.append(available)

                    if let text = String(data: buffer, encoding: .utf8) {
                        let lines = text.components(separatedBy: "\n")
                        for line in lines {
                            if line.contains("\"id\":2") || line.contains("\"id\": 2") {
                                rateLimitResponseData = line.data(using: .utf8)
                                break
                            }
                        }
                    }
                    if rateLimitResponseData != nil { break }
                }

                process.terminate()

                guard let respData = rateLimitResponseData,
                      let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
                      let result = json["result"] as? [String: Any],
                      let rateLimits = result["rateLimits"] as? [String: Any] else {
                    completion(.failure(NSError(domain: "ChatGPTLimits", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to parse local CLI output"])))
                    return
                }

                let primary = rateLimits["primary"] as? [String: Any]
                let secondary = rateLimits["secondary"] as? [String: Any]

                let pUsed = (primary?["usedPercent"] as? Double) ?? Double((primary?["usedPercent"] as? Int) ?? 0)
                let sUsed = (secondary?["usedPercent"] as? Double) ?? Double((secondary?["usedPercent"] as? Int) ?? 0)

                let pLeft = max(0, min(100, Int(round(100.0 - pUsed))))
                let sLeft = max(0, min(100, Int(round(100.0 - sUsed))))

                var d1: Date? = nil
                if let r1 = primary?["resetsAt"] as? Int {
                    d1 = Date(timeIntervalSince1970: TimeInterval(r1))
                }
                var d2: Date? = nil
                if let r2 = secondary?["resetsAt"] as? Int {
                    d2 = Date(timeIntervalSince1970: TimeInterval(r2))
                }

                let plan = (rateLimits["planType"] as? String)?.capitalized ?? "Plus"
                let rateData = RateLimitData(
                    email: "ChatGPT Account",
                    planType: plan,
                    allowed: pLeft > 0 && sLeft > 0,
                    fiveHPercentLeft: pLeft,
                    fiveHUsedPercent: pUsed,
                    weeklyPercentLeft: sLeft,
                    weeklyUsedPercent: sUsed,
                    fiveHResetAt: d1,
                    weeklyResetAt: d2,
                    lastUpdated: Date()
                )
                completion(.success(rateData))
            } catch {
                completion(.failure(error))
            }
        }
    }
}

// MARK: - Menu Bar App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var currentData: RateLimitData?
    private let launchAgentIdentifier = "com.codexlimitbar.menubar"

    // User preferences
    private var currentInterval: TimeInterval {
        get {
            let val = UserDefaults.standard.double(forKey: "refresh_interval")
            return val > 0 ? val : 5.0
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "refresh_interval")
            restartTimer()
        }
    }

    private var currentStyle: DisplayStyle {
        get {
            let key = UserDefaults.standard.string(forKey: "display_style") ?? ""
            return DisplayStyle(rawValue: key) ?? .standard
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "display_style")
            updateTitle()
        }
    }

    private var showResetTimeInBar: Bool {
        get {
            return UserDefaults.standard.object(forKey: "show_reset_time") == nil ? true : UserDefaults.standard.bool(forKey: "show_reset_time")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "show_reset_time")
            updateTitle()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "5HL=...  We=..."
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        }

        buildMenu(loading: true)
        refresh()
        restartTimer()
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: currentInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    @objc func refresh() {
        LimitFetcher.shared.fetchLimits { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let data):
                    self.currentData = data
                    self.updateTitle()
                    self.buildMenu(loading: false)
                case .failure(let error):
                    NSLog("CodexLImitBar refresh error: \(error.localizedDescription)")
                    if self.currentData == nil, let button = self.statusItem.button {
                        button.title = "5HL=?  We=?"
                    }
                    self.buildMenu(loading: false, error: error.localizedDescription)
                }
            }
        }
    }

    private func formatShortResetTime(_ date: Date?) -> String? {
        guard let date = date else { return nil }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    private func updateTitle() {
        guard let data = currentData, let button = statusItem.button else { return }
        let resetStr = showResetTimeInBar ? formatShortResetTime(data.fiveHResetAt) : nil
        button.title = currentStyle.format(fiveH: data.fiveHPercentLeft, weekly: data.weeklyPercentLeft, resetTime: resetStr)
    }

    private func maskEmail(_ email: String) -> String {
        let parts = email.components(separatedBy: "@")
        guard parts.count == 2 else { return "Account" }
        let user = parts[0]
        let domain = parts[1]
        if user.count <= 2 {
            return "**@\(domain)"
        }
        let prefix = user.prefix(2)
        return "\(prefix)***@\(domain)"
    }

    private func formatResetDate(_ date: Date?) -> String {
        guard let date = date else { return "Unavailable" }
        let now = Date()
        let diff = Int(date.timeIntervalSince(now))
        let countdown: String
        if diff <= 0 {
            countdown = "just now"
        } else {
            let days = diff / 86400
            let hours = (diff % 86400) / 3600
            let minutes = (diff % 3600) / 60
            let seconds = diff % 60
            if days > 0 {
                countdown = "in \(days)d \(hours)h"
            } else if hours > 0 {
                countdown = "in \(hours)h \(minutes)m \(seconds)s"
            } else {
                countdown = "in \(minutes)m \(seconds)s"
            }
        }

        let cal = Calendar.current
        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short
        timeFormatter.dateStyle = .none

        if cal.isDateInToday(date) {
            return "\(timeFormatter.string(from: date)) (\(countdown))"
        } else {
            let df = DateFormatter()
            df.dateFormat = "MMM d, h:mm a"
            return "\(df.string(from: date)) (\(countdown))"
        }
    }

    private func buildMenu(loading: Bool, error: String? = nil) {
        let menu = NSMenu()

        if let data = currentData {
            let masked = maskEmail(data.email)
            let headerItem = NSMenuItem(title: "ChatGPT \(data.planType) • \(masked)", action: nil, keyEquivalent: "")
            headerItem.isEnabled = false
            menu.addItem(headerItem)

            let statusStr = data.allowed ? "🟢 Status: Active" : "🔴 Status: Limit Reached"
            let statusItem = NSMenuItem(title: statusStr, action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            menu.addItem(statusItem)

            menu.addItem(NSMenuItem.separator())

            // 5h Window
            let fiveHItem = NSMenuItem(title: "⏱  5-Hour Limit: \(data.fiveHPercentLeft)% left (\(Int(data.fiveHUsedPercent))% used)", action: nil, keyEquivalent: "")
            menu.addItem(fiveHItem)
            let fiveHResetItem = NSMenuItem(title: "     Resets: \(formatResetDate(data.fiveHResetAt))", action: nil, keyEquivalent: "")
            fiveHResetItem.isEnabled = false
            menu.addItem(fiveHResetItem)

            menu.addItem(NSMenuItem.separator())

            // Weekly Window
            let weeklyItem = NSMenuItem(title: "📅  Weekly Limit: \(data.weeklyPercentLeft)% left (\(Int(data.weeklyUsedPercent))% used)", action: nil, keyEquivalent: "")
            menu.addItem(weeklyItem)
            let weeklyResetItem = NSMenuItem(title: "     Resets: \(formatResetDate(data.weeklyResetAt))", action: nil, keyEquivalent: "")
            weeklyResetItem.isEnabled = false
            menu.addItem(weeklyResetItem)

            menu.addItem(NSMenuItem.separator())

            let timeFormatter = DateFormatter()
            timeFormatter.timeStyle = .medium
            let intvSec = Int(currentInterval)
            let updatedItem = NSMenuItem(title: "Synced: \(timeFormatter.string(from: data.lastUpdated)) (every \(intvSec)s)", action: nil, keyEquivalent: "")
            updatedItem.isEnabled = false
            menu.addItem(updatedItem)
        } else if loading {
            let item = NSMenuItem(title: "Fetching usage limits...", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else if let error = error {
            let item = NSMenuItem(title: "Error: \(error)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        // Refresh action
        let refreshItem = NSMenuItem(title: "🔄  Refresh Now", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        // Toggle: Show 5h Reset Time in Menu Bar
        let toggleTimeItem = NSMenuItem(title: "Show 5h Reset Time in Bar", action: #selector(toggleResetTimeDisplay), keyEquivalent: "")
        toggleTimeItem.target = self
        toggleTimeItem.state = showResetTimeInBar ? .on : .off
        menu.addItem(toggleTimeItem)

        // Submenu: Display Styles
        let styleMenuItem = NSMenuItem(title: "Display Style", action: nil, keyEquivalent: "")
        let styleSubmenu = NSMenu()
        for s in DisplayStyle.allCases {
            let sub = NSMenuItem(title: s.title, action: #selector(selectDisplayStyle(_:)), keyEquivalent: "")
            sub.target = self
            sub.representedObject = s
            sub.state = (s == currentStyle) ? .on : .off
            styleSubmenu.addItem(sub)
        }
        styleMenuItem.submenu = styleSubmenu
        menu.addItem(styleMenuItem)

        // Submenu: Refresh Interval
        let intervalMenuItem = NSMenuItem(title: "Refresh Interval", action: nil, keyEquivalent: "")
        let intervalSubmenu = NSMenu()
        let intervals: [(String, TimeInterval)] = [
            ("5 Seconds (Real-time)", 5.0),
            ("15 Seconds", 15.0),
            ("30 Seconds", 30.0),
            ("60 Seconds", 60.0)
        ]
        for (name, val) in intervals {
            let sub = NSMenuItem(title: name, action: #selector(selectInterval(_:)), keyEquivalent: "")
            sub.target = self
            sub.representedObject = val
            sub.state = (abs(currentInterval - val) < 0.1) ? .on : .off
            intervalSubmenu.addItem(sub)
        }
        intervalMenuItem.submenu = intervalSubmenu
        menu.addItem(intervalMenuItem)

        // Launch at Login
        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = isLaunchAtLoginEnabled() ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit CodexLImitBar", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func toggleResetTimeDisplay() {
        showResetTimeInBar = !showResetTimeInBar
        buildMenu(loading: false)
    }

    @objc private func selectDisplayStyle(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? DisplayStyle {
            currentStyle = s
            buildMenu(loading: false)
        }
    }

    @objc private func selectInterval(_ sender: NSMenuItem) {
        if let val = sender.representedObject as? TimeInterval {
            currentInterval = val
            buildMenu(loading: false)
        }
    }

    private var launchAgentPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("\(launchAgentIdentifier).plist")
    }

    private func isLaunchAtLoginEnabled() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentPlistURL.path)
    }

    @objc private func toggleLaunchAtLogin() {
        let fileManager = FileManager.default
        let plistURL = launchAgentPlistURL

        if isLaunchAtLoginEnabled() {
            try? fileManager.removeItem(at: plistURL)
        } else {
            let appPath = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/CodexLImitBar").path
            let dict: [String: Any] = [
                "Label": launchAgentIdentifier,
                "ProgramArguments": [appPath],
                "RunAtLoad": true,
                "KeepAlive": false
            ]
            let launchAgentsDir = plistURL.deletingLastPathComponent()
            try? fileManager.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
            if let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) {
                try? data.write(to: plistURL)
            }
        }
        buildMenu(loading: false)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
