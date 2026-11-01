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

struct ContentView: View {
    @EnvironmentObject var ctl: StackController
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
