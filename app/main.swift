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

    /// Install the privileged helper via the macOS admin prompt (no Terminal needed).
    func installPrivileged() {
        guard !busy else { return }
        busy = true
        lastAction = "install privileged helper"
        let user = NSUserName()
        let shellCmd = "/bin/bash \(pkgDir)/bin/install-helper-root \(user) \(pkgDir)"
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "do shell script " + self.asQuote(shellCmd) + " with administrator privileges"]
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = pipe
            var out = ""
            do {
                try p.run()
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                out = String(data: d, encoding: .utf8) ?? ""
                if p.terminationStatus != 0 { out += "\n(exit \(p.terminationStatus))" }
            } catch { out = "failed: \(error.localizedDescription)" }
            let mods = self.parse(self.exec(["status"]))
            let helper = FileManager.default.fileExists(atPath: "/usr/local/sbin/devstack-web")
            DispatchQueue.main.async {
                self.output = out; self.apply(mods); self.helperReady = helper; self.busy = false
            }
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
    @StateObject private var help = HelpState()
    private let timer = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
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

// MARK: - Help

struct HelpView: View {
    var onClose: () -> Void

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
                VStack(alignment: .leading, spacing: 18) {
                    HelpSection(title: "Quick start") {
                        HelpText("Start or stop everything — or a single module — with the buttons in the main window, or from a terminal:")
                        HelpCode("devstack status\ndevstack start | stop | restart [module]\ndevstack doctor")
                    }
                    HelpSection(title: "Add a new project") {
                        HelpText("1. Put the project anywhere (e.g. ~/Sites/myapp).")
                        HelpText("2. Register it — interactively, or add one line to ~/.config/devstack/sites.conf:")
                        HelpCode("devstack add-site\n\n# host | docroot | php | kind | aliases\nmyapp.test | ~/Sites/myapp/public | 8.5 | laravel")
                        HelpText("3. Apply and verify:")
                        HelpCode("devstack sync\ndevstack doctor")
                    }
                    HelpSection(title: "Point an existing project here") {
                        HelpText("Nothing is moved or copied. Add one line pointing at its document root and run devstack sync — that is all. That is exactly how the sites below are configured.")
                    }
                    HelpSection(title: "Which folder is the document root?") {
                        HelpRow("Laravel / Symfony", "<project>/public")
                        HelpRow("WordPress", "the folder containing wp-config.php")
                        HelpRow("Plain PHP / legacy", "the folder containing index.php")
                        HelpRow("Root .htaccess forwarding to public/", "the project root")
                        HelpText("The “kind” column only controls what SSL toggling rewrites: Laravel APP_URL, WordPress siteurl/home.")
                    }
                    HelpSection(title: "Commands") {
                        HelpRow("devstack status", "every module and its state")
                        HelpRow("devstack start | stop | restart [module]", "control all modules, or one")
                        HelpRow("devstack sites", "list configured sites")
                        HelpRow("devstack add-site", "add a site interactively")
                        HelpRow("devstack sync", "regenerate vhosts + /etc/hosts, reload")
                        HelpRow("devstack composer --site HOST", "run Composer with the site's PHP")
                        HelpRow("devstack ssl enable | disable", "trusted HTTPS for all sites")
                        HelpRow("devstack doctor", "verify services, configs, sites")
                    }
                    HelpSection(title: "Looks broken?") {
                        HelpRow("502 Bad Gateway", "Apache is down → devstack start apache")
                        HelpRow("404 on :80 but works on :8081", "stale vhosts → devstack sync")
                        HelpRow("Site name doesn't resolve", "hosts entry missing → devstack sync")
                        HelpRow("Wrong PHP version", "fix the php column, then devstack sync")
                        HelpRow("A module won't start", "the console shows the underlying brew error")
                    }
                    HelpSection(title: "Where things live") {
                        HelpRow("sites", "~/.config/devstack/sites.conf")
                        HelpRow("settings", "~/.config/devstack/config")
                        HelpRow("activity log", "~/.local/share/devstack/devstack.log")
                        HelpRow("config backups", "~/.local/share/devstack/backups/")
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 660, minHeight: 620)
    }
}

struct HelpSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 14, weight: .semibold))
            content
        }
    }
}

struct HelpText: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct HelpCode: View {
    let code: String
    init(_ c: String) { code = c }
    var body: some View {
        Text(code)
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct HelpRow: View {
    let key: String
    let value: String
    init(_ k: String, _ v: String) { key = k; value = v }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(key)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .frame(width: 250, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - App

@main
struct DevStackApp: App {
    @StateObject private var ctl = StackController()
    var body: some Scene {
        WindowGroup("Dev Stack") {
            ContentView().environmentObject(ctl)
        }
    }
}
