// SPDX-License-Identifier: MIT

import Foundation
import AutoSageCore

#if os(macOS)
import AppKit
import SwiftUI

enum ServerStatus: String {
    case stopped
    case starting
    case running
    case stopping

    var displayName: String {
        rawValue.capitalized
    }

    var symbolColor: Color {
        switch self {
        case .running:
            return .green
        case .starting, .stopping:
            return .orange
        case .stopped:
            return .red
        }
    }
}

final class ServerManager: ObservableObject {
    @Published private(set) var status: ServerStatus = .stopped
    @Published private(set) var logs: [String] = []

    let adminAPIBaseURL: URL

    private let fileManager: FileManager
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var pendingRestart = false
    private let maxLogLines = 4_000

    init(
        adminAPIBaseURL: URL = ServerManager.defaultAdminAPIBaseURL(),
        fileManager: FileManager = .default
    ) {
        self.adminAPIBaseURL = adminAPIBaseURL
        self.fileManager = fileManager
    }

    deinit {
        cleanupPipes()
        if let process, process.isRunning {
            process.terminate()
        }
    }

    func start() {
        if process?.isRunning == true || status == .starting {
            appendLog("[control] Server is already running.")
            return
        }

        let workingDirectory = resolveWorkingDirectoryURL()
        let launch = resolveLaunchCommand(workingDirectory: workingDirectory)

        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()

        process.standardOutput = outPipe
        process.standardError = errPipe
        process.currentDirectoryURL = workingDirectory
        process.environment = ProcessInfo.processInfo.environment
        process.executableURL = launch.executableURL
        process.arguments = launch.arguments

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.appendLogChunk(data)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.appendLogChunk(data)
        }

        process.terminationHandler = { [weak self] finishedProcess in
            DispatchQueue.main.async {
                guard let self else { return }
                self.cleanupPipes()
                self.process = nil
                self.status = .stopped
                let reason = finishedProcess.terminationReason == .exit ? "exit" : "signal"
                self.appendLog("[control] Server terminated (\(reason), code \(finishedProcess.terminationStatus)).")
                if self.pendingRestart {
                    self.pendingRestart = false
                    self.start()
                }
            }
        }

        status = .starting
        appendLog("[control] Starting AutoSageServer in \(workingDirectory.path)")
        appendLog("[control] Launch: \(launch.renderedCommand)")

        do {
            try process.run()
            self.process = process
            self.stdoutPipe = outPipe
            self.stderrPipe = errPipe
            status = .running
            appendLog("[control] AutoSageServer started.")
        } catch {
            status = .stopped
            appendLog("[control] Failed to start server: \(error.localizedDescription)")
            cleanupPipes()
        }
    }

    func stop() {
        pendingRestart = false

        guard let process else {
            status = .stopped
            appendLog("[control] Server is not running.")
            return
        }

        guard process.isRunning else {
            status = .stopped
            self.process = nil
            appendLog("[control] Server is already stopped.")
            return
        }

        status = .stopping
        appendLog("[control] Stopping AutoSageServer...")
        process.terminate()
    }

    func reset() {
        appendLog("[control] Reset requested.")
        if process?.isRunning == true || status == .starting || status == .stopping {
            pendingRestart = true
            stop()
        } else {
            start()
        }
    }

    func clearJobs() {
        let endpoint = adminAPIBaseURL.appendingPathComponent("v1/admin/clear-jobs")
        appendLog("[control] Requesting cleanup via \(endpoint.absoluteString)")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            DispatchQueue.main.async {
                if let error {
                    self.appendLog("[control] Clear jobs request failed: \(error.localizedDescription)")
                    return
                }

                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                let body = data ?? Data()

                if (200..<300).contains(statusCode) {
                    if let payload = try? JSONCoding.makeDecoder().decode(AdminClearJobsResponse.self, from: body) {
                        self.appendLog("[control] \(payload.message)")
                    } else {
                        self.appendLog("[control] Clear jobs succeeded (HTTP \(statusCode)).")
                    }
                    return
                }

                if let payload = try? JSONCoding.makeDecoder().decode(ErrorResponse.self, from: body) {
                    self.appendLog("[control] Clear jobs failed: \(payload.error.code) - \(payload.error.message)")
                } else {
                    self.appendLog("[control] Clear jobs failed with HTTP \(statusCode).")
                }
            }
        }.resume()
    }

    private func appendLogChunk(_ data: Data) {
        guard let chunk = String(data: data, encoding: .utf8) else { return }
        let lines = chunk
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return }
        DispatchQueue.main.async {
            for line in lines {
                self.appendLog(line)
            }
        }
    }

    private func appendLog(_ line: String) {
        logs.append(line)
        let overflow = logs.count - maxLogLines
        if overflow > 0 {
            logs.removeFirst(overflow)
        }
    }

    private func cleanupPipes() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil
    }

    private static func defaultAdminAPIBaseURL() -> URL {
        if let configured = ProcessInfo.processInfo.environment["AUTOSAGE_CONTROL_API_BASE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty,
           let url = URL(string: configured) {
            return url
        }
        return URL(string: "http://127.0.0.1:8080")!
    }

    private func resolveWorkingDirectoryURL() -> URL {
        if let configured = ProcessInfo.processInfo.environment["AUTOSAGE_CONTROL_WORKDIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }

        var current = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        while true {
            let marker = current.appendingPathComponent("Package.swift")
            if fileManager.fileExists(atPath: marker.path) {
                return current
            }

            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                break
            }
            current = parent
        }

        return URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
    }

    private func resolveLaunchCommand(workingDirectory: URL) -> LaunchCommand {
        if let configured = ProcessInfo.processInfo.environment["AUTOSAGE_SERVER_EXECUTABLE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            let configuredURL = URL(fileURLWithPath: configured)
            return LaunchCommand(
                executableURL: configuredURL,
                arguments: [],
                renderedCommand: configuredURL.path
            )
        }

        let builtExecutable = workingDirectory
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("debug", isDirectory: true)
            .appendingPathComponent("AutoSageServer")
        if fileManager.isExecutableFile(atPath: builtExecutable.path) {
            return LaunchCommand(
                executableURL: builtExecutable,
                arguments: [],
                renderedCommand: builtExecutable.path
            )
        }

        let envURL = URL(fileURLWithPath: "/usr/bin/env")
        let args = ["swift", "run", "AutoSageServer"]
        return LaunchCommand(
            executableURL: envURL,
            arguments: args,
            renderedCommand: ([envURL.path] + args).joined(separator: " ")
        )
    }

    private struct LaunchCommand {
        let executableURL: URL
        let arguments: [String]
        let renderedCommand: String
    }
}

struct ContentView: View {
    @ObservedObject var manager: ServerManager
    @State private var showClearConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            logView
        }
        .frame(minWidth: 900, minHeight: 560)
        .alert(isPresented: $showClearConfirmation) {
            Alert(
                title: Text("Clear All Sessions?"),
                message: Text("This calls POST /v1/admin/clear-jobs on \(manager.adminAPIBaseURL.absoluteString) and permanently deletes session folders."),
                primaryButton: .destructive(Text("Clear Jobs")) {
                    manager.clearJobs()
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "circle.fill")
                    .foregroundColor(manager.status.symbolColor)
                    .font(.system(size: 12))
                Text("Server: \(manager.status.displayName)")
                    .font(.headline)

                Spacer()

                Button("Start") {
                    manager.start()
                }
                .disabled(manager.status == .running || manager.status == .starting)

                Button("Stop") {
                    manager.stop()
                }
                .disabled(manager.status == .stopped || manager.status == .stopping)

                Button("Reset") {
                    manager.reset()
                }
                .disabled(manager.status == .starting || manager.status == .stopping)

                Button("Clear Jobs") {
                    showClearConfirmation = true
                }
            }

            Text("Admin API: \(manager.adminAPIBaseURL.absoluteString)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(12)
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(manager.logs.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(12)
            }
            .background(Color(NSColor.textBackgroundColor))
            .onReceive(manager.$logs) { _ in
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.08)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let manager = ServerManager()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let view = ContentView(manager: manager)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "AutoSageControl"
        window.contentView = NSHostingView(rootView: view)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.setActivationPolicy(.regular)
application.delegate = delegate
application.activate(ignoringOtherApps: true)
application.run()
#else
print("AutoSageControl is only available on macOS.")
#endif
