import AppKit
import Foundation
import SwiftUI

// MARK: - Model

struct UsageWindow {
    let label: String      // e.g. "5h", "7d"
    let percent: Double
    let resetsAt: Date?
}

struct ServiceStatus {
    var indicator: String            // none / minor / major / critical / maintenance
    var description: String          // e.g. "All Systems Operational"
    var components: [(name: String, status: String)] = []
    var incidents: [String] = []
    let pageURL: URL
}

/// Reads a Statuspage-style summary.json and keeps only the components we care about.
func fetchStatus(_ base: String, components wanted: [String]) async -> ServiceStatus? {
    var req = URLRequest(url: URL(string: "\(base)/api/v2/summary.json")!)
    req.setValue("Mozilla/5.0 (Macintosh) AgentUsageMonitor", forHTTPHeaderField: "User-Agent")
    req.timeoutInterval = 20
    guard let j = try? await fetchJSON(req) else { return nil }
    let st = j["status"] as? [String: Any]
    var s = ServiceStatus(indicator: st?["indicator"] as? String ?? "none",
                          description: st?["description"] as? String ?? "Unknown",
                          pageURL: URL(string: base)!)
    let comps = (j["components"] as? [[String: Any]]) ?? []
    var seen = Set<String>()
    for w in wanted {
        if let c = comps.first(where: { ($0["name"] as? String ?? "").hasPrefix(w) }),
           let n = c["name"] as? String, !seen.contains(n) {
            seen.insert(n)
            s.components.append((n, c["status"] as? String ?? "unknown"))
        }
    }
    for i in (j["incidents"] as? [[String: Any]]) ?? [] {
        if let n = i["name"] as? String { s.incidents.append(n) }
    }
    return s
}

struct ProviderUsage {
    let name: String
    var windows: [UsageWindow] = []
    var plan: String? = nil
    var error: String? = nil
    var httpCode: Int? = nil
    var note: String? = nil      // shown under the card when data is stale
}

// MARK: - Helpers

func runSecurity(_ service: String) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", service, "-w"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

func fetchJSON(_ req: URLRequest) async throws -> [String: Any] {
    let (data, resp) = try await URLSession.shared.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200 else {
        if code == 401 || code == 403 { throw NSError(domain: "", code: code, userInfo: [NSLocalizedDescriptionKey: "Token expired – open the CLI once to refresh"]) }
        if code == 429 { throw NSError(domain: "", code: 429, userInfo: [NSLocalizedDescriptionKey: "Rate limited by the usage API"]) }
        throw NSError(domain: "", code: code, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"])
    }
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "Bad response"])
    }
    return obj
}

func windowLabel(seconds: Double) -> String {
    let h = seconds / 3600
    if h < 24 { return "\(Int(h.rounded()))h" }
    return "\(Int((h / 24).rounded()))d"
}

let isoFrac: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
let isoPlain = ISO8601DateFormatter()

func parseISO(_ s: String?) -> Date? {
    guard let s else { return nil }
    return isoFrac.date(from: s) ?? isoPlain.date(from: s)
}

func relative(_ d: Date?) -> String {
    guard let d else { return "" }
    let secs = Int(d.timeIntervalSinceNow)
    if secs <= 0 { return "resetting" }
    let days = secs / 86400, hrs = (secs % 86400) / 3600, mins = (secs % 3600) / 60
    if days > 0 { return "resets in \(days)d \(hrs)h" }
    if hrs > 0 { return "resets in \(hrs)h \(mins)m" }
    return "resets in \(mins)m"
}

func absolute(_ d: Date?) -> String {
    guard let d else { return "" }
    let f = DateFormatter()
    f.dateFormat = "EEE M/d HH:mm"
    return f.string(from: d)
}

// MARK: - Fetchers

func fetchClaude() async -> ProviderUsage {
    var u = ProviderUsage(name: "Claude")
    guard let raw = runSecurity("Claude Code-credentials"),
          let data = raw.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = obj["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String else {
        u.error = "Not logged in to Claude Code"
        return u
    }
    u.plan = oauth["subscriptionType"] as? String
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.timeoutInterval = 20
    do {
        let j = try await fetchJSON(req)
        for (key, label) in [("five_hour", "5h"), ("seven_day", "7d"), ("seven_day_opus", "7d Opus"), ("seven_day_sonnet", "7d Sonnet")] {
            if let w = j[key] as? [String: Any], let pct = w["utilization"] as? Double {
                u.windows.append(UsageWindow(label: label, percent: pct, resetsAt: parseISO(w["resets_at"] as? String)))
            }
        }
    } catch {
        u.error = error.localizedDescription
        u.httpCode = (error as NSError).code
    }
    return u
}

func fetchCodex() async -> ProviderUsage {
    var u = ProviderUsage(name: "Codex")
    let path = NSString(string: "~/.codex/auth.json").expandingTildeInPath
    guard let data = FileManager.default.contents(atPath: path),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tokens = obj["tokens"] as? [String: Any],
          let token = tokens["access_token"] as? String else {
        u.error = "Not logged in to Codex"
        return u
    }
    var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let acct = tokens["account_id"] as? String { req.setValue(acct, forHTTPHeaderField: "chatgpt-account-id") }
    req.setValue("codex_cli_rs", forHTTPHeaderField: "User-Agent")
    req.timeoutInterval = 20
    do {
        let j = try await fetchJSON(req)
        u.plan = j["plan_type"] as? String
        if let rl = j["rate_limit"] as? [String: Any] {
            for key in ["primary_window", "secondary_window"] {
                guard let w = rl[key] as? [String: Any] else { continue }
                let pct = (w["used_percent"] as? NSNumber)?.doubleValue ?? 0
                let secs = (w["limit_window_seconds"] as? NSNumber)?.doubleValue ?? 0
                let reset = (w["reset_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                u.windows.append(UsageWindow(label: windowLabel(seconds: secs), percent: pct, resetsAt: reset))
            }
        }
        // Shortest window first (5h before 7d)
        u.windows.sort { ($0.label.hasSuffix("h") ? 0 : 1) < ($1.label.hasSuffix("h") ? 0 : 1) }
    } catch {
        u.error = error.localizedDescription
        u.httpCode = (error as NSError).code
    }
    return u
}


// MARK: - Shared state

@MainActor
final class UsageStore: ObservableObject {
    @Published var claude: ProviderUsage?
    @Published var codex: ProviderUsage?
    @Published var claudeStatus: ServiceStatus?
    @Published var codexStatus: ServiceStatus?
    @Published var lastUpdated: Date?
    @Published var loading = false
    @Published var showClaude = UserDefaults.standard.object(forKey: "showClaude") as? Bool ?? true {
        didSet {
            guard showClaude != oldValue else { return }
            UserDefaults.standard.set(showClaude, forKey: "showClaude")
            restartRefresh()
        }
    }
    @Published var showCodex = UserDefaults.standard.object(forKey: "showCodex") as? Bool ?? true {
        didSet {
            guard showCodex != oldValue else { return }
            UserDefaults.standard.set(showCodex, forKey: "showCodex")
            restartRefresh()
        }
    }
    var visibleAgentNames: [String] {
        (showClaude ? ["Claude"] : []) + (showCodex ? ["Codex"] : [])
    }
    /// Opt-in. When false the app never reads any local login/credential – only public status pages are fetched.
    @Published var limitsEnabled: Bool = UserDefaults.standard.bool(forKey: "usageLimitsEnabled") {
        didSet {
            UserDefaults.standard.set(limitsEnabled, forKey: "usageLimitsEnabled")
            claude = nil; codex = nil
            claudeLastGood = nil; claudeLastGoodAt = nil
            claudeNextFetch = .distantPast; claudeBackoff = 0
            restartRefresh()
        }
    }
    var onChange: (() -> Void)?

    // Claude's usage endpoint rate-limits aggressively: poll it at most every 3 min,
    // and back off (5 → 10 → 20 → 30 min) after a 429, keeping the last good numbers.
    private var claudeNextFetch = Date.distantPast
    private var claudeBackoff: TimeInterval = 0
    private var claudeLastGood: ProviderUsage?
    private var claudeLastGoodAt: Date?
    private var refreshTask: Task<Void, Never>?

    private func restartRefresh() {
        // A settings change must not be dropped while an old request is in flight.
        // Cancelled tasks cannot restore hidden agents or data from the previous mode.
        refreshTask?.cancel()
        loading = false
        lastUpdated = nil
        onChange?()
        refresh()
    }

    func refresh() {
        guard !loading, showClaude || showCodex else { return }
        loading = true
        let enabled = limitsEnabled
        let includeClaude = showClaude, includeCodex = showCodex
        let fetchClaudeNow = includeClaude && enabled && Date() >= claudeNextFetch
        refreshTask = Task {
            guard !Task.isCancelled else { return }
            async let c: ProviderUsage? = fetchClaudeNow ? fetchClaude() : nil
            async let x: ProviderUsage? = includeCodex && enabled ? fetchCodex() : nil
            async let cs: ServiceStatus? = includeClaude ? fetchStatus("https://status.claude.com", components: ["Claude Code", "Claude API", "claude.ai"]) : nil
            async let xs: ServiceStatus? = includeCodex ? fetchStatus("https://status.openai.com", components: ["Codex", "Responses", "Login"]) : nil
            let (cr, xr, csr, xsr) = await (c, x, cs, xs)
            guard !Task.isCancelled else { return }
            if let cr { self.applyClaude(cr) }
            if includeCodex && enabled { self.codex = xr }
            if let csr { self.claudeStatus = csr }
            if let xsr { self.codexStatus = xsr }
            self.lastUpdated = Date()
            self.loading = false
            self.onChange?()
        }
    }

    private func applyClaude(_ r: ProviderUsage) {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        if r.error == nil {
            claudeLastGood = r
            claudeLastGoodAt = Date()
            claudeBackoff = 0
            claudeNextFetch = Date().addingTimeInterval(180)
            claude = r
            return
        }
        if r.httpCode == 429 {
            claudeBackoff = claudeBackoff == 0 ? 300 : min(claudeBackoff * 2, 1800)
        } else {
            claudeBackoff = 120
        }
        claudeNextFetch = Date().addingTimeInterval(claudeBackoff)
        let retry = "retry \(f.string(from: claudeNextFetch))"
        if var last = claudeLastGood, let at = claudeLastGoodAt {
            // Keep showing the last good numbers instead of an error
            let why = r.httpCode == 429 ? "API rate limited" : (r.error ?? "fetch failed")
            last.note = "Data from \(f.string(from: at)) · \(why), \(retry)"
            claude = last
        } else {
            var e = r
            if r.httpCode == 429 { e.error = "Usage API is rate limiting, \(retry)" }
            claude = e
        }
    }
}

// MARK: - Styling helpers

func levelColor(_ pct: Double) -> Color {
    switch pct {
    case 90...: return Color(red: 0.94, green: 0.27, blue: 0.27)
    case 70..<90: return Color(red: 0.96, green: 0.62, blue: 0.04)
    default: return Color(red: 0.13, green: 0.77, blue: 0.37)
    }
}

func levelNSColor(_ pct: Double) -> NSColor {
    switch pct {
    case 90...: return NSColor(red: 0.94, green: 0.27, blue: 0.27, alpha: 1)
    case 70..<90: return NSColor(red: 0.96, green: 0.62, blue: 0.04, alpha: 1)
    default: return NSColor(red: 0.13, green: 0.77, blue: 0.37, alpha: 1)
    }
}

func longName(_ label: String) -> String {
    switch label {
    case "5h": return "5-hour session"
    case "7d": return "Weekly · all models"
    case "7d Opus": return "Weekly · Opus"
    case "7d Sonnet": return "Weekly · Sonnet"
    default:
        if label.hasSuffix("h") { return "\(label.dropLast())-hour window" }
        if label == "7d" || label == "1w" { return "Weekly" }
        if label.hasSuffix("d") { return label == "7d" ? "Weekly" : "\(label.dropLast())-day window" }
        return label
    }
}

let claudeTint = Color(red: 0.85, green: 0.47, blue: 0.34)   // Claude terracotta
let codexTint = Color(red: 0.36, green: 0.42, blue: 0.95)    // indigo

// MARK: - SwiftUI views

struct ProgressCapsule: View {
    let pct: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [levelColor(pct).opacity(0.75), levelColor(pct)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, geo.size.width * min(pct, 100) / 100))
            }
        }
        .frame(height: 8)
        .animation(.easeOut(duration: 0.5), value: pct)
    }
}

struct WindowRow: View {
    let w: UsageWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(longName(w.label))
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(Int(w.percent.rounded()))%")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(levelColor(w.percent))
                    .monospacedDigit()
                Text("used")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            ProgressCapsule(pct: w.percent)
            if let r = w.resetsAt {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise")
                    Text(relative(r).capitalized(firstOnly: true))
                    Text("·").foregroundStyle(.tertiary)
                    Text(absolute(r))
                    Spacer()
                    Text("\(max(0, 100 - Int(w.percent.rounded())))% left")
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            }
        }
    }
}

extension String {
    func capitalized(firstOnly: Bool) -> String { prefix(1).uppercased() + dropFirst() }
}

struct ProviderCard: View {
    @ObservedObject var store: UsageStore
    let name: String
    let icon: String
    let tint: Color
    let usage: ProviderUsage?
    let status: ServiceStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(tint.gradient)
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 26, height: 26)
                Text(name).font(.system(size: 14, weight: .semibold))
                if let plan = usage?.plan {
                    Text(plan.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(tint.opacity(0.15)))
                        .foregroundStyle(tint)
                }
                Spacer()
            }
            if !store.limitsEnabled {
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield")
                    Text("Usage limits are off (privacy mode)")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            } else if let u = usage {
                if let e = u.error {
                    Label(e, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                } else if u.windows.isEmpty {
                    Text("No limits reported").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    ForEach(u.windows, id: \.label) { WindowRow(w: $0) }
                    if let note = u.note {
                        Label(note, systemImage: "clock.arrow.circlepath")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack { ProgressView().controlSize(.small); Text("Loading…").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            Divider().opacity(0.6)
            StatusSection(status: status)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07))
        )
    }
}

func statusColor(_ s: String) -> Color {
    switch s {
    case "none", "operational": return Color(red: 0.13, green: 0.77, blue: 0.37)
    case "minor", "degraded_performance", "maintenance", "under_maintenance": return Color(red: 0.96, green: 0.62, blue: 0.04)
    case "unknown": return .gray
    default: return Color(red: 0.94, green: 0.27, blue: 0.27)   // major / critical / outage
    }
}

func prettyStatus(_ s: String) -> String {
    switch s {
    case "operational": return "Operational"
    case "degraded_performance": return "Degraded"
    case "partial_outage": return "Partial outage"
    case "major_outage": return "Major outage"
    case "under_maintenance": return "Maintenance"
    default: return s.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

struct StatusSection: View {
    let status: ServiceStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor(status?.indicator ?? "unknown"))
                    .frame(width: 7, height: 7)
                    .shadow(color: statusColor(status?.indicator ?? "unknown").opacity(0.6), radius: 3)
                Text(status?.description ?? "Status unavailable")
                    .font(.system(size: 11.5, weight: .medium))
                Spacer()
                if let url = status?.pageURL {
                    Button { NSWorkspace.shared.open(url) } label: {
                        HStack(spacing: 2) {
                            Text("Status page")
                            Image(systemName: "arrow.up.right")
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            if let st = status {
                ForEach(st.incidents, id: \.self) { inc in
                    Label(inc, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(statusColor(st.indicator))
                        .lineLimit(2)
                }
                FlowChips(items: st.components)
            }
        }
    }
}

struct FlowChips: View {
    let items: [(name: String, status: String)]
    var body: some View {
        // Simple 2-column grid of component chips
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], alignment: .leading, spacing: 5) {
            ForEach(items, id: \.name) { c in
                HStack(spacing: 5) {
                    Circle().fill(statusColor(c.status)).frame(width: 5, height: 5)
                    Text(c.name.replacingOccurrences(of: #" \(.*\)"#, with: "", options: .regularExpression))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if c.status != "operational" {
                        Text(prettyStatus(c.status)).foregroundStyle(statusColor(c.status))
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .help("\(c.name): \(prettyStatus(c.status))")
            }
        }
    }
}

struct PopoverView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Usage Limits").font(.system(size: 15, weight: .bold))
                    Text(store.visibleAgentNames.isEmpty ? "Choose an agent in settings" : (store.lastUpdated.map { "Updated \($0.formatted(date: .omitted, time: .shortened)) · auto every 60s" } ?? "Fetching…"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { store.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .rotationEffect(.degrees(store.loading ? 360 : 0))
                        .animation(store.loading ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: store.loading)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.primary.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .disabled(store.visibleAgentNames.isEmpty)
                .help("Refresh now")
                Menu {
                    Section("Agents to show") {
                        Toggle("Claude", isOn: $store.showClaude)
                        Toggle("Codex", isOn: $store.showCodex)
                    }
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.primary.opacity(0.07)))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Agent settings")
                .help("Choose which agents to show")
            }

            if store.showClaude {
                ProviderCard(store: store, name: "Claude", icon: "sparkle", tint: claudeTint, usage: store.claude, status: store.claudeStatus)
            }
            if store.showCodex {
                ProviderCard(store: store, name: "Codex", icon: "chevron.left.forwardslash.chevron.right", tint: codexTint, usage: store.codex, status: store.codexStatus)
            }
            if store.visibleAgentNames.isEmpty {
                Text("No agents selected. Use the settings menu to show an agent’s usage and status.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 3) {
                Toggle(isOn: $store.limitsEnabled) {
                    Text("Show usage limits").font(.system(size: 11.5, weight: .medium))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                Text("Reads saved logins only for selected agents and sends them only to their official usage endpoints. Credentials are never stored or shared elsewhere.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 2)

            HStack {
                HStack(spacing: 10) {
                    legendDot(levelColor(0), "OK")
                    legendDot(levelColor(75), "≥70%")
                    legendDot(levelColor(95), "≥90%")
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
        }
        .padding(14)
        .frame(width: 330)
    }

    func legendDot(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(c).frame(width: 6, height: 6)
            Text(t).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Menu bar icon (drawn)

/// Draws "<name>" followed by up to two stacked mini bars with percentages.
func menuBarImage(claude: ProviderUsage?, codex: ProviderUsage?, claudeStatus: ServiceStatus?, codexStatus: ServiceStatus?, limits: Bool, showClaude: Bool, showCodex: Bool) -> NSImage {
    var groups: [(String, ProviderUsage?)] = []
    if showClaude { groups.append(("Claude", claude)) }
    if showCodex { groups.append(("Codex", codex)) }
    if groups.isEmpty {
        // Keep a menu bar entry so settings remain reachable with every agent hidden.
        let image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Agent usage monitor settings")!
        image.isTemplate = true
        return image
    }
    let alerts: [String: String] = ["Claude": claudeStatus?.indicator ?? "unknown", "Codex": codexStatus?.indicator ?? "unknown"]
    let nameFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    let pctFont = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .semibold)
    let barW: CGFloat = 22, barH: CGFloat = 3.5, pctW: CGFloat = 24, gap: CGFloat = 4, groupGap: CGFloat = 10
    let height: CGFloat = 22

    func nameWidth(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: nameFont]).width }
    var width: CGFloat = 0
    for (i, g) in groups.enumerated() {
        width += nameWidth(g.0) + gap + (limits ? barW + 3 + pctW : 7)
        if i < groups.count - 1 { width += groupGap }
    }

    let img = NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { _ in
        let fg = NSColor.labelColor
        var x: CGFloat = 0
        for (i, (name, u)) in groups.enumerated() {
            let nameSize = (name as NSString).size(withAttributes: [.font: nameFont])
            (name as NSString).draw(at: NSPoint(x: x, y: (height - nameSize.height) / 2),
                                    withAttributes: [.font: nameFont, .foregroundColor: fg])
            if !limits {
                // Privacy mode: just a status dot after the name
                let ind = alerts[name] ?? "none"
                NSColor(statusColor(ind)).setFill()
                NSBezierPath(ovalIn: NSRect(x: x + nameSize.width + gap, y: height / 2 - 3.5, width: 7, height: 7)).fill()
                x += nameSize.width + gap + 7
                if i < groups.count - 1 { x += groupGap }
                continue
            }
            if let ind = alerts[name], ind != "none", ind != "unknown" {
                // Small status dot at the top-right of the name when the service has issues
                NSColor(statusColor(ind)).setFill()
                NSBezierPath(ovalIn: NSRect(x: x + nameSize.width - 1, y: height - 7, width: 5, height: 5)).fill()
            }
            x += nameSize.width + gap

            let wins = Array((u?.windows ?? []).filter { !$0.label.contains(" ") }.prefix(2))
            let rows: [UsageWindow?] = wins.isEmpty ? [nil] : wins.map { $0 }
            let rowH: CGFloat = 10
            let totalH = rowH * CGFloat(rows.count)
            for (r, w) in rows.enumerated() {
                let cy = (height + totalH) / 2 - rowH * CGFloat(r) - rowH / 2
                let track = NSRect(x: x, y: cy - barH / 2, width: barW, height: barH)
                NSColor.labelColor.withAlphaComponent(0.2).setFill()
                NSBezierPath(roundedRect: track, xRadius: barH / 2, yRadius: barH / 2).fill()
                var label = "–"
                if let w {
                    let fillW = max(barH, barW * CGFloat(min(w.percent, 100)) / 100)
                    levelNSColor(w.percent).setFill()
                    NSBezierPath(roundedRect: NSRect(x: x, y: cy - barH / 2, width: fillW, height: barH),
                                 xRadius: barH / 2, yRadius: barH / 2).fill()
                    label = "\(Int(w.percent.rounded()))%"
                } else if u?.error != nil {
                    label = "!"
                }
                let s = label as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: pctFont, .foregroundColor: fg]
                let sz = s.size(withAttributes: attrs)
                s.draw(at: NSPoint(x: x + barW + 3, y: cy - sz.height / 2), withAttributes: attrs)
            }
            x += barW + 3 + pctW
            if i < groups.count - 1 { x += groupGap }
        }
        return true
    }
    return img
}

// MARK: - App

/// Borderless panel that hangs directly beneath the menu bar (no arrow, no gap).
final class DropdownPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var panel: DropdownPanel!
    var hosting: NSHostingView<PopoverView>!
    var clickMonitor: Any?
    let store = UsageStore()
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.action = #selector(togglePanel)
            b.target = self
        }
        buildPanel()

        store.onChange = { [weak self] in
            self?.updateIcon()
            self?.resizePanel()
        }
        updateIcon()
        store.refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.store.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.store.refresh() }
        }
    }

    func buildPanel() {
        panel = DropdownPanel(contentRect: NSRect(x: 0, y: 0, width: 330, height: 400),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.onEscape = { [weak self] in self?.closePanel() }

        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        // Rounded on all corners, like the system's own menu-bar popups
        effect.layer?.cornerRadius = 12
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        hosting = NSHostingView(rootView: PopoverView(store: store))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
    }

    func updateIcon() {
        statusItem.button?.image = menuBarImage(claude: store.claude, codex: store.codex, claudeStatus: store.claudeStatus, codexStatus: store.codexStatus, limits: store.limitsEnabled, showClaude: store.showClaude, showCodex: store.showCodex)
        statusItem.button?.title = ""
        let names = store.visibleAgentNames.joined(separator: " & ")
        statusItem.button?.toolTip = names.isEmpty ? "Agent usage monitor — choose agents in settings" :
            (store.limitsEnabled ? "\(names) usage — top bar = 5-hour, bottom bar = weekly" : "\(names) service status")
    }

    /// Place the panel so its top edge touches the bottom of the menu bar, left-aligned to the status item.
    func positionPanel() {
        guard let bw = statusItem.button?.window else { return }
        let size = hosting.fittingSize
        let barFrame = bw.frame                     // status item frame in screen coords
        let screen = bw.screen ?? NSScreen.main!
        let top = barFrame.minY                     // bottom edge of the menu bar
        var x = barFrame.minX
        let maxX = screen.frame.maxX - size.width - 6
        x = min(max(x, screen.frame.minX + 6), maxX)
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
        panel.invalidateShadow()
    }

    func resizePanel() {
        guard panel.isVisible else { return }
        DispatchQueue.main.async { self.positionPanel() }
    }

    @objc func togglePanel() {
        panel.isVisible ? closePanel() : openPanel()
    }

    func openPanel() {
        if store.lastUpdated.map({ Date().timeIntervalSince($0) > 10 }) ?? true { store.refresh() }
        statusItem.button?.highlight(true)
        positionPanel()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        // Close when clicking anywhere outside
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePanel() }
        }
    }

    func closePanel() {
        guard panel.isVisible else { return }
        statusItem.button?.highlight(false)
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.1; panel.animator().alphaValue = 0 }) {
            Task { @MainActor in if self.clickMonitor == nil { self.panel.orderOut(nil) } }
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
