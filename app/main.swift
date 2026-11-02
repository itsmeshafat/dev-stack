import SwiftUI
import AppKit
import Foundation
import Combine

// MARK: - Model

struct ModuleStatus: Identifiable {
    let id: String
    let state: String
    let detail: String
    var isRunning: Bool { state == "running" }
    var isPartial: Bool { state == "partial" }
}

struct UpdateInfo {
    let current: String
    let latest: String
    let url: String
}

// MARK: - Controller
// Talks to the installed CLI at ~/.local/bin/devstack (single source of truth).

final class StackController: ObservableObject {
    @Published var modules: [ModuleStatus] = []
    @Published var busy: Bool = false
    @Published var output: String = ""
    @Published var summary: String = "Loading…"
    @Published var lastAction: String = ""
    @Published var helperReady: Bool = false
    @Published var cliReady: Bool = false
    @Published var update: UpdateInfo?
    @Published var updateDismissed: Bool = false
    @Published var updatedTo: String?

    let home: String
    let cliPath: String
    let pkgDir: String

    init() {
        home = FileManager.default.homeDirectoryForCurrentUser.path
        cliPath = home + "/.local/bin/devstack"
        pkgDir  = home + "/.local/share/devstack/pkg"
        cliReady = FileManager.default.isExecutableFile(atPath: cliPath)
        loadStatus()
        checkHelper()
        checkForUpdates()
    }

    private func exec(_ args: [String]) -> String {
        guard cliReady else { return "devstack CLI not found at \(cliPath)\nRun the installer first." }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [cliPath] + args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return "failed to run: \(error.localizedDescription)" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func parse(_ out: String) -> [ModuleStatus] {
        out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, !parts[0].contains(" ") else { return nil }
            return ModuleStatus(id: parts[0], state: parts[1], detail: parts.count >= 3 ? parts[2] : "")
        }
    }

    private func apply(_ mods: [ModuleStatus]) {
        modules = mods
        let running = mods.filter { $0.isRunning }.count
        summary = "\(running) of \(mods.count) modules running"
    }

    func loadStatus() {
        if busy { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let mods = self.parse(self.exec(["status"]))
            DispatchQueue.main.async { self.apply(mods) }
        }
    }

    func checkHelper() {
        DispatchQueue.global(qos: .utility).async {
            let exists = FileManager.default.fileExists(atPath: "/usr/local/sbin/devstack-web")
            DispatchQueue.main.async { self.helperReady = exists }
        }
    }

    func refreshAll() {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let mods = self.parse(self.exec(["status"]))
            DispatchQueue.main.async { self.apply(mods); self.busy = false }
        }
    }

    // MARK: updates

    func checkForUpdates(force: Bool = false) {
        guard cliReady else { return }
        var args = ["update", "--check", "--json"]
        if force { args.append("--refresh") }
        DispatchQueue.global(qos: .utility).async {
            let out = self.exec(args)
            guard let data = out.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let available = obj["available"] as? Bool, available,
                  let latest = obj["latest"] as? String else { return }
            let info = UpdateInfo(current: obj["current"] as? String ?? "",
                                  latest: latest,
                                  url: obj["url"] as? String ?? "")
            DispatchQueue.main.async {
                if self.updatedTo == nil {
                    self.update = info
                    self.updateDismissed = false
                }
            }
        }
    }

    func dismissUpdate() { updateDismissed = true }

    /// Runs `devstack update` (app + CLI). The helper is updated through the admin prompt only if it changed.
    func performUpdate() {
        guard !busy, cliReady else { return }
        busy = true
        lastAction = "update"
        let target = update?.latest ?? ""
        DispatchQueue.global(qos: .userInitiated).async {
            var out = self.exec(["update", "--yes", "--no-helper"])
            if out.contains("HELPER_UPDATE_REQUIRED") {
                out += "\n\nUpdating the privileged helper (admin prompt)…\n"
                out += self.adminHelperInstall()
            }
            let mods = self.parse(self.exec(["status"]))
            let ver = self.exec(["version"]).trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "devstack ", with: "")
            DispatchQueue.main.async {
                self.output = out
                self.apply(mods)
                self.busy = false
                if out.contains("updated ") {
                    self.updatedTo = target.isEmpty ? ver : target
                    self.update = nil
                    self.helperReady = FileManager.default.fileExists(atPath: "/usr/local/sbin/devstack-web")
                }
            }
        }
    }

    func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", "/Applications/Dev Stack.app"]
        try? p.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: privileged helper

    /// Install the privileged helper via the macOS admin prompt (no Terminal needed).
    func installPrivileged() {
        guard !busy else { return }
        busy = true
        lastAction = "install privileged helper"
        DispatchQueue.global(qos: .userInitiated).async {
            let out = self.adminHelperInstall()
            let mods = self.parse(self.exec(["status"]))
            let helper = FileManager.default.fileExists(atPath: "/usr/local/sbin/devstack-web")
            DispatchQueue.main.async {
                self.output = out; self.apply(mods); self.helperReady = helper; self.busy = false
            }
        }
    }

    private func adminHelperInstall() -> String {
        let user = NSUserName()
        let shellCmd = "/bin/bash \(pkgDir)/bin/install-helper-root \(user) \(pkgDir)"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "do shell script " + asQuote(shellCmd) + " with administrator privileges"]
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        do {
            try p.run()
            let d = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            var out = String(data: d, encoding: .utf8) ?? ""
            if p.terminationStatus != 0 { out += "\n(exit \(p.terminationStatus))" }
            return out
        } catch {
            return "failed: \(error.localizedDescription)"
        }
    }

    func perform(_ args: [String]) {
        guard !busy else { return }
        busy = true
        lastAction = args.joined(separator: " ")
        DispatchQueue.global(qos: .userInitiated).async {
            let out = self.exec(args)
            let mods = self.parse(self.exec(["status"]))
            DispatchQueue.main.async { self.output = out; self.apply(mods); self.busy = false }
        }
    }

    func startAll()   { perform(["start"]) }
    func stopAll()    { perform(["stop"]) }
    func restartAll() { perform(["restart"]) }
    func start(_ id: String)   { perform(["start", id]) }
    func stop(_ id: String)    { perform(["stop", id]) }
    func restart(_ id: String) { perform(["restart", id]) }

    private func asQuote(_ s: String) -> String {
        let e = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + e + "\""
    }
}

// MARK: - Views

struct ModuleRow: View {
    let module: ModuleStatus
    let busy: Bool
    let onStart: () -> Void
    let onStop: () -> Void
    let onRestart: () -> Void

    private var color: Color {
        if module.isRunning { return .green }
        if module.isPartial { return .orange }
        return Color(nsColor: .tertiaryLabelColor)
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(color).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(module.id).font(.system(size: 13, weight: .semibold, design: .monospaced))
                Text(module.detail).font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer(minLength: 10)
            Text(module.state.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(color)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(color.opacity(0.12)).clipShape(Capsule())
            HStack(spacing: 6) {
                Button("Start") { onStart() }.disabled(busy || module.isRunning)
                Button("Stop") { onStop() }.disabled(busy || !module.isRunning)
                Button("Restart") { onRestart() }.disabled(busy)
            }.controlSize(.small)
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
    }
}

final class HelpState: ObservableObject {
    @Published var show = false
}

struct ContentView: View {
    @EnvironmentObject var ctl: StackController
    @EnvironmentObject var help: HelpState
    private let timer = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            if let u = ctl.update, !ctl.updateDismissed {
                Divider()
                updateBanner(u)
            }
            if let v = ctl.updatedTo {
                Divider()
                updatedBanner(v)
            }
            Divider()
            list
            Divider()
            console
        }
        .frame(minWidth: 660, minHeight: 600)
        .onReceive(timer) { _ in if !ctl.busy { ctl.loadStatus() } }
        .sheet(isPresented: $help.show) {
            HelpView(onClose: { help.show = false })
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Dev Stack").font(.system(size: 20, weight: .bold))
                    Text(ctl.summary).font(.system(size: 12)).foregroundColor(.secondary)
                }
                Spacer()
                if ctl.busy { ProgressView().scaleEffect(0.7) }
            }
            HStack(spacing: 8) {
                Button(action: { ctl.startAll() })   { Label("Start All", systemImage: "play.fill") }.disabled(ctl.busy)
                Button(action: { ctl.stopAll() })    { Label("Stop All", systemImage: "stop.fill") }.disabled(ctl.busy)
                Button(action: { ctl.restartAll() }) { Label("Restart All", systemImage: "arrow.clockwise") }.disabled(ctl.busy)
                Spacer()
                Button(action: { help.show = true }) { Label("Help", systemImage: "questionmark.circle") }
                Button(action: { ctl.refreshAll() }) { Label("Refresh", systemImage: "arrow.triangle.2.circlepath") }.disabled(ctl.busy)
            }
        }
        .padding(16)
    }

    private func updateBanner(_ u: UpdateInfo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle.fill").foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Update available — v\(u.current) → v\(u.latest)")
                    .font(.system(size: 12, weight: .medium))
                Text("Only app code is replaced. Sites, config, certificates and services are untouched.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            if let url = URL(string: u.url), !u.url.isEmpty {
                Button("Release notes") { NSWorkspace.shared.open(url) }
            }
            Button("Dismiss") { ctl.dismissUpdate() }
            Button(action: { ctl.performUpdate() }) { Label("Update now", systemImage: "arrow.down.app") }
                .disabled(ctl.busy)
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08))
    }

    private func updatedBanner(_ v: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            Text("Updated to v\(v). Relaunch to use it.")
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Button("Relaunch") { ctl.relaunch() }
            Button("Later") { ctl.updatedTo = nil }
        }
        .padding(12)
        .background(Color.green.opacity(0.10))
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(ctl.modules) { m in
                    ModuleRow(module: m, busy: ctl.busy,
                              onStart: { ctl.start(m.id) },
                              onStop: { ctl.stop(m.id) },
                              onRestart: { ctl.restart(m.id) })
                    Divider()
                }
                if !ctl.helperReady {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                        VStack(alignment: .leading, spacing: 8) {
                            Text("The 'web' module (nginx) needs a one-time privileged helper.")
                                .font(.system(size: 11, weight: .medium))
                            Text("It also adds the *.test entries to /etc/hosts. macOS will ask for your password once.")
                                .font(.system(size: 10)).foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button(action: { ctl.installPrivileged() }) {
                                Label("Install privileged helper…", systemImage: "lock.shield")
                            }.disabled(ctl.busy)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(16)
                }
            }
        }
    }

    private var console: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(ctl.lastAction.isEmpty ? "Console" : "Last action: \(ctl.lastAction)")
                    .font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
                Spacer()
                Text("log: ~/.local/share/devstack/devstack.log")
                    .font(.system(size: 9)).foregroundColor(.secondary)
            }
            ScrollView {
                Text(ctl.output.isEmpty ? "—" : ctl.output)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 92)
        }
        .padding(12)
    }
}

// MARK: - Help (rendered from the bundled docs/HELP.md)

enum HelpBlock {
    case title(String)
    case heading(String)
    case text(String)
    case bullet(String)
    case code(String)
    case row(String, String)
}

func parseHelp(_ md: String) -> [HelpBlock] {
    var out: [HelpBlock] = []
    var inCode = false
    var code: [String] = []

    for raw in md.components(separatedBy: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("```") {
            if inCode {
                out.append(.code(code.joined(separator: "\n")))
                code = []; inCode = false
            } else { inCode = true }
            continue
        }
        if inCode { code.append(raw); continue }
        if line.isEmpty { continue }

        if line.hasPrefix("### ") { out.append(.heading(String(line.dropFirst(4)))); continue }
        if line.hasPrefix("## ")  { out.append(.heading(String(line.dropFirst(3)))); continue }
        if line.hasPrefix("# ")   { out.append(.title(String(line.dropFirst(2)))); continue }

        if line.hasPrefix("|") {
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !cells.isEmpty, cells.allSatisfy({ $0.allSatisfy { ch in ch == "-" || ch == ":" } }) {
                continue   // table separator row
            }
            if cells.count >= 2 { out.append(.row(cells[0], cells[1...].joined(separator: " | "))); continue }
            if cells.count == 1 { out.append(.text(cells[0])); continue }
        }

        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            out.append(.bullet(String(line.dropFirst(2)))); continue
        }
        if let r = line.range(of: #"^[0-9]+\. "#, options: .regularExpression) {
            out.append(.bullet(String(line[r.upperBound...]))); continue
        }
        out.append(.text(line))
    }
    if inCode { out.append(.code(code.joined(separator: "\n"))) }
    return out
}

struct HelpView: View {
    var onClose: () -> Void
    private let blocks: [HelpBlock]

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        self.blocks = parseHelp(Self.loadMarkdown())
    }

    static func loadMarkdown() -> String {
        if let url = Bundle.main.url(forResource: "HELP", withExtension: "md"),
           let s = try? String(contentsOf: url, encoding: .utf8) {
            return s
        }
        return "# Dev Stack — Help\n\n## Documentation not found\nThe bundled HELP.md is missing — reinstall the app."
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Dev Stack — Help", systemImage: "questionmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(action: onClose) { Label("Close", systemImage: "xmark") }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(blocks.indices, id: \.self) { i in
                        blockView(blocks[i])
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 660, minHeight: 620)
    }

    @ViewBuilder
    private func blockView(_ b: HelpBlock) -> some View {
        switch b {
        case .title(let t):
            Text(t).font(.system(size: 20, weight: .bold))
        case .heading(let t):
            Text(t).font(.system(size: 14, weight: .semibold)).padding(.top, 8)
        case .text(let t):
            Text(t).font(.system(size: 12)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let t):
            HStack(alignment: .top, spacing: 8) {
                Text("•").font(.system(size: 12))
                Text(t).font(.system(size: 12)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .code(let c):
            Text(c)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        case .row(let k, let v):
            HStack(alignment: .top, spacing: 12) {
                Text(k).font(.system(size: 11, weight: .medium, design: .monospaced))
                    .frame(width: 260, alignment: .leading)
                Text(v).font(.system(size: 11)).foregroundColor(.secondary)
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - App

@main
struct DevStackApp: App {
    @StateObject private var ctl = StackController()
    @StateObject private var help = HelpState()

    var body: some Scene {
        WindowGroup("Dev Stack") {
            ContentView()
                .environmentObject(ctl)
                .environmentObject(help)
        }
        .commands {
            CommandGroup(replacing: .help) {
                Button("Dev Stack Help") { help.show = true }
                    .keyboardShortcut("?", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { ctl.checkForUpdates(force: true) }
                    .keyboardShortcut("u", modifiers: .command)
            }
        }
    }
}
