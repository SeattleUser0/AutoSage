import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#else
#error("Unsupported C standard library")
#endif

public struct NgSpiceParsedRaw: Codable, Equatable, Sendable {
    public let vectorNames: [String]
    public let vectors: [String: [Double]]
    public let pointCount: Int

    public init(vectorNames: [String], vectors: [String: [Double]], pointCount: Int) {
        self.vectorNames = vectorNames
        self.vectors = vectors
        self.pointCount = pointCount
    }
}

public struct NgSpiceRunResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let logText: String
    public let rawPath: String
    public let parsed: NgSpiceParsedRaw?

    public init(
        exitCode: Int32,
        stdout: String,
        stderr: String,
        logText: String,
        rawPath: String,
        parsed: NgSpiceParsedRaw?
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.logText = logText
        self.rawPath = rawPath
        self.parsed = parsed
    }
}

public struct NgSpiceRunnerError: Error, Equatable, Sendable {
    public let code: String
    public let message: String
    public let details: [String: String]

    public init(code: String, message: String, details: [String: String] = [:]) {
        self.code = code
        self.message = message
        self.details = details
    }
}

public enum NgSpiceRunner {
    public static func runNetlist(
        netlist: String,
        workdir: URL? = nil,
        timeoutS: TimeInterval = 30
    ) throws -> NgSpiceRunResult {
        let trimmed = netlist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NgSpiceRunnerError(code: "invalid_input", message: "netlist must be non-empty.")
        }
        guard trimmed.lowercased().contains(".end") else {
            throw NgSpiceRunnerError(code: "invalid_input", message: "netlist must include .end.")
        }
        guard timeoutS > 0 else {
            throw NgSpiceRunnerError(code: "invalid_input", message: "timeout_s must be > 0.")
        }
        guard isNgspiceInstalled() else {
            throw NgSpiceRunnerError(
                code: "solver_not_installed",
                message: "ngspice is not installed. Install it with: brew install ngspice."
            )
        }

        let fileManager = FileManager.default
        let baseDirectory = workdir ?? fileManager.temporaryDirectory
        let runID = makeRunID()
        let runDirectory = baseDirectory.appendingPathComponent("ngspice_\(runID)", isDirectory: true)
        try fileManager.createDirectory(at: runDirectory, withIntermediateDirectories: true, attributes: nil)

        let keepArtifacts = ProcessInfo.processInfo.environment["AUTO_SAGE_KEEP_ARTIFACTS"] == "1"
        defer {
            if !keepArtifacts {
                try? fileManager.removeItem(at: runDirectory)
            }
        }

        let cirPath = runDirectory.appendingPathComponent("netlist.cir")
        let rawPath = runDirectory.appendingPathComponent("output.raw")
        let logPath = runDirectory.appendingPathComponent("ngspice.log")

        let prepared = prepareForMachineParsing(netlist: trimmed, rawFilename: rawPath.lastPathComponent)
        try prepared.write(to: cirPath, atomically: true, encoding: .utf8)

        let execution = try runProcess(
            executable: "/usr/bin/env",
            arguments: ["ngspice", "-b", "-r", rawPath.lastPathComponent, "-o", logPath.lastPathComponent, cirPath.lastPathComponent],
            currentDirectoryURL: runDirectory,
            timeoutS: timeoutS
        )

        let logText = (try? String(contentsOf: logPath, encoding: .utf8)) ?? ""
        let parsed = try? parseASCIIRaw(at: rawPath)
        let result = NgSpiceRunResult(
            exitCode: execution.exitCode,
            stdout: execution.stdout,
            stderr: execution.stderr,
            logText: logText,
            rawPath: rawPath.path,
            parsed: parsed
        )

        if execution.exitCode != 0 || hasLogError(logText) {
            throw NgSpiceRunnerError(
                code: "solver_failed",
                message: "ngspice failed.",
                details: [
                    "exit_code": String(execution.exitCode),
                    "log_excerpt": relevantLogExcerpt(from: logText, maxLines: 50)
                ]
            )
        }

        return result
    }

    public static func prepareForMachineParsing(netlist: String, rawFilename: String = "output.raw") -> String {
        var lines = netlist
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)

        while let last = lines.last, last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeLast()
        }

        while let last = lines.last, last.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == ".end" {
            lines.removeLast()
        }

        let hasControl = lines.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == ".control" }
        if !hasControl {
            lines.append(".control")
            lines.append("set filetype=ascii")
            lines.append("run")
            lines.append("write \(rawFilename)")
            lines.append("quit")
            lines.append(".endc")
        }
        lines.append(".end")
        return lines.joined(separator: "\n") + "\n"
    }

    public static func parseASCIIRaw(at path: URL) throws -> NgSpiceParsedRaw {
        let content = try String(contentsOf: path, encoding: .utf8)
        return try parseASCIIRaw(content: content)
    }

    public static func parseASCIIRaw(content: String) throws -> NgSpiceParsedRaw {
        let lines = content
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map(String.init)

        guard let variablesIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "variables:" }),
              let valuesIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "values:" }),
              valuesIndex > variablesIndex else {
            throw NgSpiceRunnerError(code: "parse_error", message: "ASCII raw file missing Variables/Values sections.")
        }

        let variableLines = lines[(variablesIndex + 1)..<valuesIndex]
        var vectorNames: [String] = []
        for line in variableLines {
            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            if tokens.count >= 2, Int(tokens[0]) != nil {
                vectorNames.append(tokens[1])
            }
        }
        guard !vectorNames.isEmpty else {
            throw NgSpiceRunnerError(code: "parse_error", message: "No vectors found in ASCII raw file.")
        }

        var vectors: [String: [Double]] = [:]
        for name in vectorNames {
            vectors[name] = []
        }

        var currentVectorIndex = 0
        for line in lines[(valuesIndex + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                continue
            }
            let tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
            if tokens.isEmpty {
                continue
            }

            if tokens.count >= 2, Int(tokens[0]) != nil {
                currentVectorIndex = 0
                appendRawToken(tokens[1], vectorNames: vectorNames, vectors: &vectors, currentVectorIndex: &currentVectorIndex)
                if tokens.count > 2 {
                    for token in tokens.dropFirst(2) {
                        appendRawToken(token, vectorNames: vectorNames, vectors: &vectors, currentVectorIndex: &currentVectorIndex)
                    }
                }
                continue
            }

            for token in tokens {
                appendRawToken(token, vectorNames: vectorNames, vectors: &vectors, currentVectorIndex: &currentVectorIndex)
            }
        }

        let pointCount = vectorNames.compactMap { vectors[$0]?.count }.min() ?? 0
        guard pointCount > 0 else {
            throw NgSpiceRunnerError(code: "parse_error", message: "No point data parsed from ASCII raw file.")
        }
        for name in vectorNames {
            vectors[name] = Array((vectors[name] ?? []).prefix(pointCount))
        }

        return NgSpiceParsedRaw(vectorNames: vectorNames, vectors: vectors, pointCount: pointCount)
    }

    public static func isNgspiceInstalled() -> Bool {
        do {
            let result = try runProcess(
                executable: "/usr/bin/env",
                arguments: ["ngspice", "-v"],
                currentDirectoryURL: nil,
                timeoutS: 5
            )
            return result.exitCode == 0
        } catch {
            return false
        }
    }

    public static func runSmokeTest(timeoutS: TimeInterval = 30) throws -> NgSpiceRunResult {
        let version = try runProcess(
            executable: "/usr/bin/env",
            arguments: ["ngspice", "-v"],
            currentDirectoryURL: nil,
            timeoutS: 5
        )
        guard version.exitCode == 0 else {
            throw NgSpiceRunnerError(code: "solver_not_installed", message: "ngspice -v failed.")
        }

        let previousKeep = ProcessInfo.processInfo.environment["AUTO_SAGE_KEEP_ARTIFACTS"]
        setenv("AUTO_SAGE_KEEP_ARTIFACTS", "1", 1)
        defer {
            if let previousKeep {
                setenv("AUTO_SAGE_KEEP_ARTIFACTS", previousKeep, 1)
            } else {
                unsetenv("AUTO_SAGE_KEEP_ARTIFACTS")
            }
        }

        let workdir = FileManager.default.temporaryDirectory
        let result = try runNetlist(netlist: smokeTestNetlist(), workdir: workdir, timeoutS: timeoutS)
        let rawExists = FileManager.default.fileExists(atPath: result.rawPath)
        let runDirectory = URL(fileURLWithPath: result.rawPath).deletingLastPathComponent()
        let logPath = runDirectory.appendingPathComponent("ngspice.log")
        let logExists = FileManager.default.fileExists(atPath: logPath.path)
        let parsed = result.parsed
        let hasTime = parsed?.vectors["time"] != nil
        let hasVout = parsed?.vectors.keys.contains(where: { $0.lowercased() == "v(out)" }) == true

        defer { try? FileManager.default.removeItem(at: runDirectory) }

        guard rawExists, logExists, hasTime, hasVout else {
            throw NgSpiceRunnerError(
                code: "smoketest_failed",
                message: "ngspice smoke test assertions failed.",
                details: [
                    "raw_exists": String(rawExists),
                    "log_exists": String(logExists),
                    "has_time": String(hasTime),
                    "has_v_out": String(hasVout)
                ]
            )
        }

        return result
    }

    private static func smokeTestNetlist() -> String {
        """
        * RC smoke test
        V1 in 0 PULSE(0 1 0 1n 1n 1m 2m)
        R1 in out 1000
        C1 out 0 1e-6
        .tran 100u 10m
        .end
        """
    }

    private static func hasLogError(_ logText: String) -> Bool {
        logText.split(whereSeparator: \.isNewline).contains { line in
            let lower = line.lowercased()
            return lower.contains("error:") || lower.contains("fatal")
        }
    }

    private static func relevantLogExcerpt(from logText: String, maxLines: Int) -> String {
        let lines = logText.split(whereSeparator: \.isNewline).map(String.init)
        let relevant = lines.filter { line in
            let lower = line.lowercased()
            return lower.contains("error:") || lower.contains("fatal")
        }
        if !relevant.isEmpty {
            return relevant.prefix(maxLines).joined(separator: "\n")
        }
        return lines.prefix(maxLines).joined(separator: "\n")
    }

    private static func appendRawToken(
        _ token: String,
        vectorNames: [String],
        vectors: inout [String: [Double]],
        currentVectorIndex: inout Int
    ) {
        guard currentVectorIndex < vectorNames.count, let value = parseRawValue(token) else {
            return
        }
        let name = vectorNames[currentVectorIndex]
        var data = vectors[name] ?? []
        data.append(value)
        vectors[name] = data
        currentVectorIndex += 1
        if currentVectorIndex >= vectorNames.count {
            currentVectorIndex = 0
        }
    }

    private static func parseRawValue(_ token: String) -> Double? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        if let value = Double(trimmed) {
            return value
        }
        let parts = trimmed.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 2, let real = Double(parts[0]), let imag = Double(parts[1]) {
            return (real * real + imag * imag).squareRoot()
        }
        return nil
    }

    private static func makeRunID() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "\(formatter.string(from: Date()))_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
    }

    private static func runProcess(
        executable: String,
        arguments: [String],
        currentDirectoryURL: URL?,
        timeoutS: TimeInterval
    ) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectoryURL {
            process.currentDirectoryURL = currentDirectoryURL
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw NgSpiceRunnerError(code: "process_launch_failed", message: "Failed to start process: \(arguments.joined(separator: " ")).")
        }

        let completed = waitForProcess(process, timeoutS: timeoutS)
        if !completed {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
            }
            throw NgSpiceRunnerError(code: "timeout", message: "Process timed out after \(timeoutS)s.")
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }

    private static func waitForProcess(_ process: Process, timeoutS: TimeInterval) -> Bool {
        if !process.isRunning {
            return true
        }
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        if !process.isRunning {
            return true
        }
        return semaphore.wait(timeout: .now() + timeoutS) == .success
    }
}
