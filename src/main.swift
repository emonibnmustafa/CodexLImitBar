import Cocoa
import Foundation
import SQLite3


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

struct ContextWindowData {
    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
    let modelContextWindow: Int
    let percentFull: Int          // 0-100 (matches official Codex desktop formula: min(totalTokens, modelContextWindow) / modelContextWindow * 100)
    let threadName: String        // Human-friendly title of the active chat
    let sessionId: String         // Session UUID
    let eventTimestamp: Date?     // Exact timestamp of the latest token_count turn event
    let lastUpdated: Date         // App read timestamp
}

// MARK: - Display Styles

enum DisplayStyle: String, CaseIterable {
    case standard
    case compact
    case emoji
    case minimal

    var title: String {
        switch self {
        case .standard: return "Standard (5HL=85% (4:30 PM)  We=90%  Ctx=30%)"
        case .compact:  return "Compact (5h: 85% (4:30 PM) | W: 90% | C: 30%)"
        case .emoji:    return "Emoji (⏱ 85% (4:30 PM) | 📅 90% | 🧠 30%)"
        case .minimal:  return "Minimal (85% (4:30 PM) / 90% / 30%)"
        }
    }

    func format(fiveH: Int, weekly: Int, resetTime: String?, ctx: Int? = nil) -> String {
        let p = formatParts(fiveH: fiveH, weekly: weekly, resetTime: resetTime, ctx: ctx)
        return "\(p.fiveHPart)\(p.separator1)\(p.weeklyPart)\(p.ctxPart)"
    }

    func formatParts(fiveH: Int, weekly: Int, resetTime: String?, ctx: Int? = nil) -> (fiveHPart: String, separator1: String, weeklyPart: String, ctxPart: String) {
        let resetPart = (resetTime != nil && !resetTime!.isEmpty) ? " (\(resetTime!))" : ""
        switch self {
        case .standard:
            let ctx = ctx != nil ? "  Ctx=\(ctx!)%" : ""
            return ("5HL=\(fiveH)%\(resetPart)", "  ", "We=\(weekly)%", ctx)
        case .compact:
            let ctx = ctx != nil ? " | C: \(ctx!)%" : ""
            return ("5h: \(fiveH)%\(resetPart)", " | ", "W: \(weekly)%", ctx)
        case .emoji:
            let ctx = ctx != nil ? " | 🧠 \(ctx!)%" : ""
            return ("⏱ \(fiveH)%\(resetPart)", " | ", "📅 \(weekly)%", ctx)
        case .minimal:
            let ctx = ctx != nil ? " / \(ctx!)%" : ""
            return ("\(fiveH)%\(resetPart)", " / ", "\(weekly)%", ctx)
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

// MARK: - Context Window Fetcher

struct ActiveThreadTarget {
    let rolloutURL: URL
    let threadId: String
    let title: String
    let updatedAt: Date?
}

class ContextWindowFetcher {
    static let shared = ContextWindowFetcher()

    /// Query ~/.codex/state_*.sqlite to find the most recent user-facing chat session (ignoring internal subagent threads)
    func findActiveUserThread() -> ActiveThreadTarget? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexDir = home.appendingPathComponent(".codex")

        if let contents = try? FileManager.default.contentsOfDirectory(at: codexDir, includingPropertiesForKeys: nil) {
            let stateDbs = contents
                .filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }

            for dbUrl in stateDbs {
                var db: OpaquePointer?
                let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
                if sqlite3_open_v2(dbUrl.path, &db, flags, nil) == SQLITE_OK {
                    defer { sqlite3_close(db) }

                    // Query the most recently updated non-subagent thread that is not archived
                    let query = """
                    SELECT rollout_path, id, COALESCE(NULLIF(name, ''), title), updated_at_ms, updated_at
                    FROM threads
                    WHERE archived = 0 AND (thread_source IS NULL OR thread_source != 'subagent')
                    ORDER BY COALESCE(updated_at_ms, updated_at * 1000) DESC
                    LIMIT 1;
                    """

                    var stmt: OpaquePointer?
                    if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
                        defer { sqlite3_finalize(stmt) }
                        if sqlite3_step(stmt) == SQLITE_ROW {
                            let path = String(cString: sqlite3_column_text(stmt, 0))
                            let id = String(cString: sqlite3_column_text(stmt, 1))
                            let title = sqlite3_column_text(stmt, 2) != nil ? String(cString: sqlite3_column_text(stmt, 2)) : ""
                            let ms = sqlite3_column_int64(stmt, 3)
                            let sec = sqlite3_column_int64(stmt, 4)
                            let date: Date? = ms > 0 ? Date(timeIntervalSince1970: Double(ms) / 1000.0) : (sec > 0 ? Date(timeIntervalSince1970: Double(sec)) : nil)

                            let fileUrl = URL(fileURLWithPath: path)
                            if FileManager.default.fileExists(atPath: fileUrl.path) {
                                return ActiveThreadTarget(rolloutURL: fileUrl, threadId: id, title: title, updatedAt: date)
                            }
                        }
                    }
                }
            }
        }

        // Fallback: directory mtime scan if SQLite was unavailable or empty
        guard let fallbackUrl = findLatestRolloutFileByMtime() else { return nil }
        let filename = fallbackUrl.deletingPathExtension().lastPathComponent
        let rawId = filename.replacingOccurrences(of: "rollout-", with: "")
        let sessionUuid = rawId.count >= 36 ? String(rawId.suffix(36)) : rawId
        let threadNames = fetchThreadNames()
        let title = threadNames[sessionUuid] ?? ""
        let modDate = (try? fallbackUrl.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return ActiveThreadTarget(rolloutURL: fallbackUrl, threadId: sessionUuid, title: title, updatedAt: modDate)
    }

    /// Fallback method to find rollout file purely by filesystem modification date
    func findLatestRolloutFileByMtime() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sessionsBase = home.appendingPathComponent(".codex/sessions")
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsBase,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var latestFile: URL? = nil
        var latestModDate = Date.distantPast

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" && fileURL.lastPathComponent.hasPrefix("rollout-") else { continue }
            if let attrs = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
               let modDate = attrs.contentModificationDate,
               modDate > latestModDate {
                latestModDate = modDate
                latestFile = fileURL
            }
        }
        return latestFile
    }

    /// Return latest rollout file URL of active user thread
    func findLatestRolloutFile() -> URL? {
        return findActiveUserThread()?.rolloutURL
    }

    /// Read thread names dictionary from ~/.codex/session_index.jsonl
    func fetchThreadNames() -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let indexPath = home.appendingPathComponent(".codex/session_index.jsonl")
        guard let data = try? Data(contentsOf: indexPath),
              let str = String(data: data, encoding: .utf8) else { return [:] }

        var map: [String: String] = [:]
        for line in str.components(separatedBy: "\n") {
            guard !line.isEmpty, let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let id = json["id"] as? String,
                  let name = json["thread_name"] as? String else { continue }
            map[id] = name
        }
        return map
    }

    /// Read the latest active Codex session rollout file and extract context window usage with exact Codex desktop logic.
    func fetchContextWindow() -> ContextWindowData? {
        guard let activeTarget = findActiveUserThread() else { return nil }
        let rolloutFile = activeTarget.rolloutURL
        let sessionUuid = activeTarget.threadId
        var chatTitle = activeTarget.title
        if chatTitle.isEmpty {
            let threadNames = fetchThreadNames()
            chatTitle = threadNames[sessionUuid] ?? ""
        }

        // Read file and find last token_count event (read backwards from end for efficiency)
        guard let fileData = try? Data(contentsOf: rolloutFile),
              let fileStr = String(data: fileData, encoding: .utf8) else { return nil }

        let lines = fileStr.components(separatedBy: "\n")

        // Scan backwards for the last token_count event
        for i in stride(from: lines.count - 1, through: max(0, lines.count - 500), by: -1) {
            let line = lines[i]
            guard line.contains("\"token_count\"") else { continue }
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let payload = json["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String,
                  payloadType == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let modelCtxWindow = info["model_context_window"] as? Int, modelCtxWindow > 0 else { continue }

            let lastUsage = info["last_token_usage"] as? [String: Any]
            let totalUsage = info["total_token_usage"] as? [String: Any]

            let inputTokens = (lastUsage?["input_tokens"] as? Int) ?? (totalUsage?["input_tokens"] as? Int) ?? 0
            let outputTokens = (lastUsage?["output_tokens"] as? Int) ?? (totalUsage?["output_tokens"] as? Int) ?? 0
            let totalTokens = (lastUsage?["total_tokens"] as? Int) ?? (inputTokens + outputTokens)

            // Exact calculation matching official ChatGPT desktop app:
            // used = min(totalTokens, modelContextWindow)
            // percent = round(used / modelContextWindow * 100)
            let usedTokens = min(totalTokens, modelCtxWindow)
            let pctFull = min(100, Int(round(Double(usedTokens) / Double(modelCtxWindow) * 100.0)))

            // Extract ISO8601 timestamp of this specific token_count turn event
            var eventDate: Date? = nil
            if let tsStr = json["timestamp"] as? String {
                let isoWithFrac = ISO8601DateFormatter()
                isoWithFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                eventDate = isoWithFrac.date(from: tsStr) ?? ISO8601DateFormatter().date(from: tsStr)
            }
            if eventDate == nil {
                eventDate = activeTarget.updatedAt
            }

            return ContextWindowData(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                totalTokens: totalTokens,
                modelContextWindow: modelCtxWindow,
                percentFull: pctFull,
                threadName: chatTitle,
                sessionId: sessionUuid,
                eventTimestamp: eventDate,
                lastUpdated: Date()
            )
        }

        return nil
    }

    /// Extract last active prompt, plan, and full work done to generate a handoff prompt for another AI
    func generateHandoffPrompt() -> String {
        guard let rolloutFile = findLatestRolloutFile(),
              let fileData = try? Data(contentsOf: rolloutFile),
              let fileStr = String(data: fileData, encoding: .utf8) else {
            return "Resume the previous work. My Codex 5-hour limit was reached."
        }

        let lines = fileStr.components(separatedBy: "\n")
        var lastUserPrompt = ""
        var planEntries: [String] = []
        var assistantSteps: [String] = []
        var executedCommands: [(cmd: String, status: String, output: String)] = []
        var activeCwd: String? = nil

        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }

            let type = json["type"] as? String
            let payload = json["payload"] as? [String: Any] ?? [:]
            let payloadType = payload["type"] as? String

            // 1. Detect active working directory
            if let item = payload["item"] as? [String: Any],
               let cwd = item["cwd"] as? String {
                activeCwd = cwd.replacingOccurrences(of: "file://", with: "")
            } else if type == "turn_context",
                      let cwd = (payload["cwd"] as? String) ?? (payload["working_directory"] as? String) {
                activeCwd = cwd.replacingOccurrences(of: "file://", with: "")
            }

            // 2. User Prompts
            if type == "response_item", payloadType == "message",
               let role = payload["role"] as? String, role == "user",
               let content = payload["content"] as? [[String: Any]] {
                let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty && !text.contains("<turn_aborted>") {
                    var cleaned = text
                    // Strip system wrapper tags
                    if let r = cleaned.range(of: "</environment_context>") {
                        cleaned = String(cleaned[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    if let r = cleaned.range(of: "</recommended_plugins>") {
                        cleaned = String(cleaned[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    if cleaned.contains("USER TASK:") {
                        let parts = cleaned.components(separatedBy: "USER TASK:")
                        if let lastPart = parts.last?.trimmingCharacters(in: .whitespacesAndNewlines), !lastPart.isEmpty {
                            cleaned = lastPart
                        }
                    }
                    if !cleaned.isEmpty {
                        lastUserPrompt = cleaned
                    }
                }
            }

            // 3. Assistant Messages (Plan vs Progress Notes)
            if type == "response_item", payloadType == "message",
               let role = payload["role"] as? String, role == "assistant",
               let content = payload["content"] as? [[String: Any]] {
                let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    if planEntries.count < 2 {
                        planEntries.append(text)
                    } else {
                        assistantSteps.append(text)
                    }
                }
            }

            // 4. Command Execution Records
            if payloadType == "item_completed",
               let item = payload["item"] as? [String: Any],
               let itemType = item["type"] as? String, itemType == "CommandExecution" {
                var cmdStr = ""
                if let cmdList = item["command"] as? [String] {
                    cmdStr = cmdList.joined(separator: " ")
                } else if let s = item["command"] as? String {
                    cmdStr = s
                }
                if cmdStr.hasPrefix("/bin/zsh -lc ") {
                    cmdStr = String(cmdStr.dropFirst(13)).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                }

                let status = (item["status"] as? String) ?? "unknown"
                let stdout = (item["stdout"] as? String) ?? ""
                let stderr = (item["stderr"] as? String) ?? ""
                let combined = (stdout.isEmpty ? stderr : stdout).trimmingCharacters(in: .whitespacesAndNewlines)

                executedCommands.append((cmd: cmdStr, status: status, output: combined))
            }
        }

        // Git status from active workspace if accessible
        var gitSummary = ""
        if let cwd = activeCwd, FileManager.default.fileExists(atPath: cwd) {
            let branchTask = Process()
            branchTask.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            branchTask.arguments = ["branch", "--show-current"]
            branchTask.currentDirectoryURL = URL(fileURLWithPath: cwd)
            let bPipe = Pipe()
            branchTask.standardOutput = bPipe
            try? branchTask.run()
            branchTask.waitUntilExit()
            let branch = String(data: bPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let statusTask = Process()
            statusTask.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            statusTask.arguments = ["status", "--short"]
            statusTask.currentDirectoryURL = URL(fileURLWithPath: cwd)
            let sPipe = Pipe()
            statusTask.standardOutput = sPipe
            try? statusTask.run()
            statusTask.waitUntilExit()
            let st = String(data: sPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            gitSummary = "• Workspace: \(cwd)\(branch.isEmpty ? "" : " (branch: \(branch))")\n"
            if !st.isEmpty {
                gitSummary += "• Uncommitted / Modified Files:\n\(st)\n"
            } else {
                gitSummary += "• Git Status: Clean (no uncommitted file modifications)\n"
            }
        }

        // Format Work Done section
        var workItems: [String] = []
        if !gitSummary.isEmpty {
            workItems.append(gitSummary)
        }

        if !assistantSteps.isEmpty {
            workItems.append("• Progress Notes & Analysis:")
            for (idx, step) in assistantSteps.suffix(6).enumerated() {
                workItems.append("  [\(idx + 1)] \(step)")
            }
        }

        if !executedCommands.isEmpty {
            workItems.append("\n• Recent Actions & Executed Commands:")
            for rec in executedCommands.suffix(8) {
                let icon = rec.status == "completed" ? "✅" : "❌"
                var line = "  \(icon) `\(rec.cmd)`"
                if rec.status != "completed" || rec.output.contains("FAIL") || rec.output.contains("Error") {
                    let preview = String(rec.output.prefix(350))
                    line += "\n     Result: \(preview)"
                }
                workItems.append(line)
            }
        }

        let promptText = lastUserPrompt.isEmpty ? "Continue previous task." : lastUserPrompt
        let planText = planEntries.isEmpty ? "No explicit initial plan recorded." : planEntries.joined(separator: "\n\n")
        let workDoneText = workItems.isEmpty ? "No execution history recorded." : workItems.joined(separator: "\n")

        return """
        ===============================================================
        ⚠️ CODEX AI HANDOFF PROMPT (5H Limit Warning)
        ===============================================================
        Context: The Codex 5-hour usage limit is almost exhausted (<= 3% remaining).
        Use the prompt, plan, and work history below to seamlessly continue the task.

        [1. LAST PROMPT GIVEN TO CODEX]
        \(promptText)

        [2. PLAN CODEX MADE FOR WORKING]
        \(planText)

        [3. FULL WORK DONE SO FAR]
        \(workDoneText)

        [4. INSTRUCTIONS FOR CONTINUING AI]
        Please pick up directly from where Codex left off:
        1. Review the original prompt requirements and Codex's plan above.
        2. Check the workspace files, git status, and the last executed command result / failure.
        3. Continue implementing and verifying the remaining steps without repeating already-completed work.
        ===============================================================
        """
    }
}

// MARK: - Menu Bar App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var currentData: RateLimitData?
    private var currentContextData: ContextWindowData?
    private let launchAgentIdentifier = "com.codexlimitbar.menubar"

    // Warning state tracking
    // 5h: alert at 50%, 20%, 10% (red alert zone), and 3% (critical alert)
    private var shown5hThresholds: Set<Int> = []
    private var shown3PercentAlert = false
    // Weekly: alert at 50%, 30%, and 10% (red alert zone)
    private var shownWeeklyThresholds: Set<Int> = []
    // Track previous values for detecting crossings
    private var prev5hLeft: Int = 100
    private var prevWeeklyLeft: Int = 100


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

    private var showContextWindowInBar: Bool {
        get {
            return UserDefaults.standard.object(forKey: "show_context_in_bar") == nil ? true : UserDefaults.standard.bool(forKey: "show_context_in_bar")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "show_context_in_bar")
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
                    self.checkWarningThresholds(data)
                case .failure(let error):
                    NSLog("CodexLImitBar refresh error: \(error.localizedDescription)")
                    if self.currentData == nil, let button = self.statusItem.button {
                        button.title = "5HL=?  We=?"
                    }
                    self.buildMenu(loading: false, error: error.localizedDescription)
                }
            }
        }

        // Fetch context window usage from latest Codex session rollout
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ctxData = ContextWindowFetcher.shared.fetchContextWindow()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.currentContextData = ctxData
                self.updateTitle()
                if self.currentData != nil {
                    self.buildMenu(loading: false)
                }
            }
        }
    }

    private func checkWarningThresholds(_ data: RateLimitData) {
        let fiveH = data.fiveHPercentLeft
        let weekly = data.weeklyPercentLeft

        // --- 5h thresholds: popup at 50%, 20%, 10% (red alert zone), and 3% (critical alert) ---
        // Reset all shown thresholds when limit recovers above 55%
        if fiveH > 55 {
            shown5hThresholds.removeAll()
            shown3PercentAlert = false
        } else if fiveH > 10 {
            shown3PercentAlert = false
        }

        // 3% CHECK: Warning popup on screen (non-intrusive, no action taken on Codex)
        if fiveH <= 3 && fiveH >= 1 && !shown3PercentAlert {
            shown3PercentAlert = true
            showWarningPopup(
                category: "5-Hour",
                pctLeft: fiveH,
                threshold: 3,
                severity: .critical
            )
            prev5hLeft = fiveH
            prevWeeklyLeft = weekly
            return
        }

        let fiveHCheckpoints = [50, 20, 10]
        for threshold in fiveHCheckpoints {
            // Crossed below this threshold (was above, now at or below)
            if fiveH <= threshold && prev5hLeft > threshold && !shown5hThresholds.contains(threshold) {
                shown5hThresholds.insert(threshold)
                let severity: PopupSeverity = threshold <= 10 ? .critical : (threshold <= 20 ? .warning : .info)
                showWarningPopup(
                    category: "5-Hour",
                    pctLeft: fiveH,
                    threshold: threshold,
                    severity: severity
                )
                break  // only show one popup per refresh cycle
            }
        }

        // --- Weekly thresholds: popup at 50%, 30%, and 10% (red alert zone) ---
        // Reset all shown thresholds when limit recovers above 55%
        if weekly > 55 {
            shownWeeklyThresholds.removeAll()
        }

        let weeklyCheckpoints = [50, 30, 10]
        for threshold in weeklyCheckpoints {
            if weekly <= threshold && prevWeeklyLeft > threshold && !shownWeeklyThresholds.contains(threshold) {
                shownWeeklyThresholds.insert(threshold)
                let severity: PopupSeverity = threshold <= 10 ? .critical : .warning
                // Delay weekly popup slightly if a 5h popup was just shown
                let delay: TimeInterval = shown5hThresholds.count > 0 ? 1.5 : 0.0
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.showWarningPopup(
                        category: "Weekly",
                        pctLeft: weekly,
                        threshold: threshold,
                        severity: severity
                    )
                }
                break
            }
        }

        prev5hLeft = fiveH
        prevWeeklyLeft = weekly
    }

    private enum PopupSeverity {
        case info, warning, critical
    }

    private func showWarningPopup(category: String, pctLeft: Int, threshold: Int, severity: PopupSeverity) {
        let alert = NSAlert()

        switch severity {
        case .critical:
            alert.messageText = "🔴 CodexLImitBar CRITICAL"
            if threshold == 3 {
                alert.informativeText = "⚠️ 5-Hour limit has dropped to \(pctLeft)%!\n\nYour 5-hour Codex limit is almost finished. You can copy the AI handoff prompt below to continue in another AI if needed."
                alert.addButton(withTitle: "Got it")
                alert.addButton(withTitle: "Copy AI Handoff Prompt")
            } else {
                alert.informativeText = "\(category) limit is critically low!\n\nOnly \(pctLeft)% remaining (crossed \(threshold)% threshold).\n\n⚠️ Slow down or risk hitting the limit!"
                alert.addButton(withTitle: "Got it")
            }
            alert.alertStyle = .critical
        case .warning:
            alert.messageText = "⚠️ CodexLImitBar Warning"
            alert.informativeText = "\(category) limit is getting low.\n\n\(pctLeft)% remaining (crossed \(threshold)% threshold).\n\nConsider pacing your usage."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Got it")
        case .info:
            alert.messageText = "ℹ️ CodexLImitBar Notice"
            alert.informativeText = "\(category) limit update: \(pctLeft)% remaining.\n\nCrossed the \(threshold)% threshold."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Got it")
        }

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if threshold == 3 && response == .alertSecondButtonReturn {
            copyHandoffPromptNow()
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
        let ctxVal = showContextWindowInBar ? currentContextData?.percentFull : nil

        let fiveHDanger = data.fiveHPercentLeft >= 1 && data.fiveHPercentLeft <= 10
        let weeklyDanger = data.weeklyPercentLeft >= 1 && data.weeklyPercentLeft <= 10

        let parts = currentStyle.formatParts(
            fiveH: data.fiveHPercentLeft,
            weekly: data.weeklyPercentLeft,
            resetTime: resetStr,
            ctx: ctxVal
        )

        let normalFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let boldFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)

        if !fiveHDanger && !weeklyDanger {
            // Both normal
            button.attributedTitle = NSAttributedString(string: "")
            button.title = "\(parts.fiveHPart)\(parts.separator1)\(parts.weeklyPart)\(parts.ctxPart)"
            button.font = normalFont
            return
        }

        // At least one metric is in red zone (1-10% remaining)
        // Color each component INDEPENDENTLY so one red zone does not turn the other metric red
        let result = NSMutableAttributedString()

        // 5-Hour portion
        if fiveHDanger {
            let fiveHAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.red,
                .font: boldFont
            ]
            result.append(NSAttributedString(string: "🔴 \(parts.fiveHPart)", attributes: fiveHAttrs))
        } else {
            let normalAttrs: [NSAttributedString.Key: Any] = [
                .font: normalFont
            ]
            result.append(NSAttributedString(string: parts.fiveHPart, attributes: normalAttrs))
        }

        // Separator between 5h and weekly
        result.append(NSAttributedString(string: parts.separator1, attributes: [.font: normalFont]))

        // Weekly portion
        if weeklyDanger {
            let weeklyAttrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.red,
                .font: boldFont
            ]
            result.append(NSAttributedString(string: "🔴 \(parts.weeklyPart)", attributes: weeklyAttrs))
        } else {
            let normalAttrs: [NSAttributedString.Key: Any] = [
                .font: normalFont
            ]
            result.append(NSAttributedString(string: parts.weeklyPart, attributes: normalAttrs))
        }

        // Context Window portion (if visible)
        if !parts.ctxPart.isEmpty {
            result.append(NSAttributedString(string: parts.ctxPart, attributes: [.font: normalFont]))
        }

        button.attributedTitle = result
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

            // Context Window (if available)
            if let ctx = currentContextData {
                menu.addItem(NSMenuItem.separator())
                let numFormatter = NumberFormatter()
                numFormatter.numberStyle = .decimal
                let usedStr = numFormatter.string(from: NSNumber(value: ctx.totalTokens)) ?? "\(ctx.totalTokens)"
                let maxStr = numFormatter.string(from: NSNumber(value: ctx.modelContextWindow)) ?? "\(ctx.modelContextWindow)"
                let headroomTokens = max(0, ctx.modelContextWindow - ctx.totalTokens)
                let headroomStr = numFormatter.string(from: NSNumber(value: headroomTokens)) ?? "\(headroomTokens)"

                let ctxItem = NSMenuItem(title: "🧠  Context Window: \(ctx.percentFull)% full (\(usedStr) / \(maxStr) tokens)", action: nil, keyEquivalent: "")
                menu.addItem(ctxItem)

                let chatLabel = ctx.threadName.isEmpty ? "Active Session (...\(ctx.sessionId.suffix(8)))" : "\"\(ctx.threadName)\""
                let chatItem = NSMenuItem(title: "     Chat: \(chatLabel)", action: nil, keyEquivalent: "")
                chatItem.isEnabled = false
                menu.addItem(chatItem)

                var turnDateStr = ""
                if let eventDate = ctx.eventTimestamp {
                    let df = DateFormatter()
                    df.doesRelativeDateFormatting = true
                    df.dateStyle = .short
                    df.timeStyle = .short
                    turnDateStr = " • Updated: \(df.string(from: eventDate))"
                }

                let ctxSub = NSMenuItem(title: "     \(headroomStr) headroom (\(100 - ctx.percentFull)% left)\(turnDateStr)", action: nil, keyEquivalent: "")
                ctxSub.isEnabled = false
                menu.addItem(ctxSub)
            }

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

        // Toggle: Show Context Window in Menu Bar
        let toggleCtxItem = NSMenuItem(title: "Show Context Window % in Bar", action: #selector(toggleContextDisplay), keyEquivalent: "")
        toggleCtxItem.target = self
        toggleCtxItem.state = showContextWindowInBar ? .on : .off
        menu.addItem(toggleCtxItem)

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

        // Action: Copy AI Handoff Prompt Now
        let copyPromptItem = NSMenuItem(title: "📋 Copy Current AI Handoff Prompt", action: #selector(copyHandoffPromptNow), keyEquivalent: "")
        copyPromptItem.target = self
        menu.addItem(copyPromptItem)

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

    @objc private func toggleContextDisplay() {
        showContextWindowInBar = !showContextWindowInBar
        buildMenu(loading: false)
    }

    @objc private func copyHandoffPromptNow() {
        let prompt = ContextWindowFetcher.shared.generateHandoffPrompt()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(prompt, forType: .string)

        let alert = NSAlert()
        alert.messageText = "📋 AI Handoff Prompt Copied!"
        alert.informativeText = "The handoff prompt for your current session was successfully copied to your clipboard.\n\nYou can now paste it directly into Claude, Gemini, or any other AI model."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
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
