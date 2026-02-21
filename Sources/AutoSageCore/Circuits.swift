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

public enum CircuitsAnalysis: String, Codable, Equatable, Sendable {
    case op
    case dc
    case ac
    case tran
}

public struct CircuitsTranOptions: Codable, Equatable, Sendable {
    public let tstop: Double
    public let step: Double?

    public init(tstop: Double, step: Double?) {
        self.tstop = tstop
        self.step = step
    }
}

public struct CircuitsACOptions: Codable, Equatable, Sendable {
    public let fstart: Double
    public let fstop: Double
    public let points: Int

    public init(fstart: Double, fstop: Double, points: Int) {
        self.fstart = fstart
        self.fstop = fstop
        self.points = points
    }
}

public struct CircuitsDCOptions: Codable, Equatable, Sendable {
    public let source: String
    public let start: Double
    public let stop: Double
    public let step: Double

    public init(source: String, start: Double, stop: Double, step: Double) {
        self.source = source
        self.start = start
        self.stop = stop
        self.step = step
    }
}

public struct CircuitsSimulationOptions: Codable, Equatable, Sendable {
    public let tran: CircuitsTranOptions?
    public let ac: CircuitsACOptions?
    public let dc: CircuitsDCOptions?

    public init(tran: CircuitsTranOptions?, ac: CircuitsACOptions?, dc: CircuitsDCOptions?) {
        self.tran = tran
        self.ac = ac
        self.dc = dc
    }
}

public struct CircuitsSimulateInput: Codable, Equatable, Sendable {
    public let netlist: String
    public let analysis: CircuitsAnalysis
    public let probes: [String]
    public let options: CircuitsSimulationOptions?

    public init(netlist: String, analysis: CircuitsAnalysis, probes: [String], options: CircuitsSimulationOptions?) {
        self.netlist = netlist
        self.analysis = analysis
        self.probes = probes
        self.options = options
    }
}

public struct CircuitsSeries: Codable, Equatable, Sendable {
    public let probe: String
    public let x: [Double]
    public let y: [Double]

    public init(probe: String, x: [Double], y: [Double]) {
        self.probe = probe
        self.x = x
        self.y = y
    }
}

public struct CircuitsSimulateOutput: Codable, Equatable, Sendable {
    public let status: String
    public let solver: String
    public let summary: String
    public let series: [CircuitsSeries]

    public init(status: String, solver: String, summary: String, series: [CircuitsSeries]) {
        self.status = status
        self.solver = solver
        self.summary = summary
        self.series = series
    }
}

public struct CircuitsCommandResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let elapsedMS: Int

    public init(exitCode: Int32, stdout: String, stderr: String, elapsedMS: Int) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.elapsedMS = elapsedMS
    }
}

public typealias CircuitsCommandRunner = @Sendable (
    _ executable: String,
    _ arguments: [String],
    _ currentDirectoryURL: URL,
    _ timeoutMS: Int,
    _ maxStdoutBytes: Int,
    _ maxStderrBytes: Int
) throws -> CircuitsCommandResult

public struct CircuitsSimulateTool: Tool {
    public let name: String = "circuits.simulate"
    public let version: String
    public let description: String = "Circuit simulation with ngspice."
    public let jsonSchema: JSONValue = CircuitsSimulationRunner.schema
    private let commandRunner: CircuitsCommandRunner
    private let ngspiceInstalled: @Sendable () -> Bool

    public init(
        version: String = "0.1.0",
        commandRunner: @escaping CircuitsCommandRunner = CircuitsSimulationRunner.defaultRunner,
        ngspiceInstalled: @escaping @Sendable () -> Bool = CircuitsSimulationRunner.defaultInstalledCheck
    ) {
        self.version = version
        self.commandRunner = commandRunner
        self.ngspiceInstalled = ngspiceInstalled
    }

    public func run(input: JSONValue?, context: ToolExecutionContext) throws -> JSONValue {
        try CircuitsSimulationRunner.run(
            input: input,
            context: context,
            commandRunner: commandRunner,
            ngspiceInstalled: ngspiceInstalled
        )
    }
}

public enum CircuitsSimulationRunner {
    private static let pointCap = 2_000

    public static let defaultRunner: CircuitsCommandRunner = { executable, arguments, currentDirectoryURL, timeoutMS, maxStdoutBytes, maxStderrBytes in
        try defaultCommandRunner(
            executable: executable,
            arguments: arguments,
            currentDirectoryURL: currentDirectoryURL,
            timeoutMS: timeoutMS,
            maxStdoutBytes: maxStdoutBytes,
            maxStderrBytes: maxStderrBytes
        )
    }

    public static let defaultInstalledCheck: @Sendable () -> Bool = {
        isNgspiceInstalled()
    }

    private struct MinimalInput: Equatable {
        let netlist: String
        let controlCommands: [String]
    }

    private enum DecodedInput {
        case minimal(MinimalInput)
        case legacy(CircuitsSimulateInput)
    }

    public static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "netlist": .object([
                "type": .string("string"),
                "description": .string("SPICE netlist text. Required.")
            ]),
            "control": .object([
                "description": .string("Optional ngspice control commands. String or string array."),
                "oneOf": .array([
                    .object(["type": .string("string")]),
                    .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")])
                    ])
                ])
            ]),
            "analysis": .object([
                "type": .string("string"),
                "enum": .stringArray(["op", "dc", "ac", "tran"]),
                "description": .string("Legacy mode selector. Requires probes and options where needed.")
            ]),
            "probes": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string("Legacy mode probes for data.csv export.")
            ]),
            "options": .object([
                "type": .string("object")
            ])
        ]),
        "required": .stringArray(["netlist"])
    ])

    public static func run(input: JSONValue?, jobDirectoryURL: URL) throws -> JSONValue {
        let context = ToolExecutionContext(jobID: "adhoc", jobDirectoryURL: jobDirectoryURL, limits: .default)
        return try run(input: input, context: context, commandRunner: defaultRunner, ngspiceInstalled: defaultInstalledCheck)
    }

    public static func run(
        input: JSONValue?,
        context: ToolExecutionContext,
        commandRunner: @escaping CircuitsCommandRunner,
        ngspiceInstalled: @escaping @Sendable () -> Bool
    ) throws -> JSONValue {
        let decoded = try decodeInput(from: input)
        guard ngspiceInstalled() else {
            throw AutoSageError(
                code: "missing_dependency",
                message: "ngspice is not installed or not on PATH. Checked PATH for ngspice.",
                details: ["search": .string("PATH")]
            )
        }

        let startedAt = Date()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: context.jobDirectoryURL, withIntermediateDirectories: true, attributes: nil)

        let netlistURL = context.jobDirectoryURL.appendingPathComponent("circuit.cir")
        let logURL = context.jobDirectoryURL.appendingPathComponent("ngspice.log")
        let rawURL = context.jobDirectoryURL.appendingPathComponent("ngspice.raw")
        let dataURL = context.jobDirectoryURL.appendingPathComponent("data.csv")

        let netlistText = try makeFinalNetlist(from: decoded)
        try netlistText.write(to: netlistURL, atomically: true, encoding: .utf8)

        let command = [
            "ngspice",
            "-b",
            "-o", logURL.lastPathComponent,
            "-r", rawURL.lastPathComponent,
            "-a",
            netlistURL.lastPathComponent
        ]
        let commandResult = try commandRunner(
            "/usr/bin/env",
            command,
            context.jobDirectoryURL,
            context.limits.timeoutMS,
            context.limits.maxStdoutBytes,
            context.limits.maxStderrBytes
        )

        let logText = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        if commandResult.exitCode != 0 {
            throw AutoSageError(
                code: "solver_failed",
                message: "ngspice exited with status \(commandResult.exitCode).",
                details: [
                    "exit_code": .number(Double(commandResult.exitCode)),
                    "stdout_tail": .string(lastLines(in: commandResult.stdout, count: 30, maxCharacters: 4_000)),
                    "stderr_tail": .string(lastLines(in: commandResult.stderr, count: 30, maxCharacters: 4_000)),
                    "log_tail": .string(lastLines(in: logText, count: 30, maxCharacters: 4_000))
                ]
            )
        }

        let series: [CircuitsSeries]
        let summary: String
        switch decoded {
        case .minimal:
            series = []
            summary = "Ran ngspice batch simulation."
        case .legacy(let legacyInput):
            guard fileManager.fileExists(atPath: dataURL.path) else {
                throw AutoSageError(
                    code: "solver_failed",
                    message: "ngspice did not produce data.csv.",
                    details: ["log_tail": .string(lastLines(in: logText, count: 30, maxCharacters: 4_000))]
                )
            }
            let parsed = try parseSeries(from: dataURL, probes: legacyInput.probes, analysis: legacyInput.analysis)
            series = capSeries(parsed, totalPointCap: pointCap)
            summary = "Simulated \(legacyInput.analysis.rawValue) with \(series.count) probe(s)."
        }

        let artifacts = collectArtifacts(
            in: context.jobDirectoryURL,
            jobID: context.jobID,
            maxArtifactBytes: context.limits.maxArtifactBytes,
            maxArtifacts: context.limits.maxArtifacts
        )
        let elapsedMS = max(commandResult.elapsedMS, Int(Date().timeIntervalSince(startedAt) * 1000))
        var outputObject: [String: JSONValue] = [:]
        if !series.isEmpty {
            outputObject["series"] = try encodeJSONValue(series)
        }
        let result = ToolExecutionResult(
            status: "ok",
            solver: "ngspice",
            summary: cappedSummary(summary, limit: context.limits.maxSummaryCharacters),
            stdout: commandResult.stdout,
            stderr: commandResult.stderr,
            exitCode: Int(commandResult.exitCode),
            artifacts: artifacts,
            metrics: [
                "elapsed_ms": .number(Double(elapsedMS)),
                "job_id": .string(context.jobID)
            ],
            output: outputObject.isEmpty ? nil : .object(outputObject)
        )
        return try result.asJSONValue()
    }

    public static func isNgspiceInstalled() -> Bool {
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["which", "ngspice"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    public static func defaultCommandRunner(
        executable: String,
        arguments: [String],
        currentDirectoryURL: URL,
        timeoutMS: Int,
        maxStdoutBytes: Int,
        maxStderrBytes: Int
    ) throws -> CircuitsCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let startedAt = Date()
        do {
            try process.run()
        } catch {
            throw AutoSageError(
                code: "missing_dependency",
                message: "ngspice is not installed or not on PATH. Checked PATH for ngspice.",
                details: ["search": .string("PATH")]
            )
        }

        let timeoutSeconds = Double(max(1, timeoutMS)) / 1000.0
        if !waitForProcess(process, timeoutS: timeoutSeconds) {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.25)
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
            }
            throw AutoSageError(
                code: "timeout",
                message: "ngspice timed out after \(timeoutMS)ms."
            )
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
        return CircuitsCommandResult(
            exitCode: process.terminationStatus,
            stdout: decodeAndCap(data: stdoutData, maxBytes: maxStdoutBytes, suffix: "\n[stdout truncated]"),
            stderr: decodeAndCap(data: stderrData, maxBytes: maxStderrBytes, suffix: "\n[stderr truncated]"),
            elapsedMS: elapsedMS
        )
    }

    private static func decodeAndCap(data: Data, maxBytes: Int, suffix: String) -> String {
        guard data.count > maxBytes else {
            return String(data: data, encoding: .utf8) ?? ""
        }
        let prefix = data.prefix(max(0, maxBytes))
        let text = String(data: prefix, encoding: .utf8) ?? ""
        return text + suffix
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

    private static func decodeInput(from json: JSONValue?) throws -> DecodedInput {
        guard case .object(let object)? = json else {
            throw AutoSageError(code: "invalid_input", message: "circuits.simulate requires an object input.")
        }
        guard case .string(let netlist)? = object["netlist"],
              !netlist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AutoSageError(code: "invalid_input", message: "circuits.simulate requires a non-empty netlist.")
        }

        let usesLegacyFields = object["analysis"] != nil || object["probes"] != nil || object["options"] != nil
        if usesLegacyFields {
            let data = try JSONCoding.makeEncoder().encode(JSONValue.object(object))
            do {
                let decoded = try JSONCoding.makeDecoder().decode(CircuitsSimulateInput.self, from: data)
                let normalizedProbes = decoded.probes
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                guard !normalizedProbes.isEmpty else {
                    throw AutoSageError(
                        code: "invalid_input",
                        message: "Legacy circuits.simulate mode requires at least one probe."
                    )
                }
                let normalized = CircuitsSimulateInput(
                    netlist: decoded.netlist,
                    analysis: decoded.analysis,
                    probes: normalizedProbes,
                    options: decoded.options
                )
                try validateLegacyOptions(normalized)
                return .legacy(normalized)
            } catch let error as AutoSageError {
                throw error
            } catch {
                throw AutoSageError(
                    code: "invalid_input",
                    message: "Invalid legacy circuits.simulate payload.",
                    details: ["hint": .string("Expected netlist + analysis + probes (+ options as required).")]
                )
            }
        }

        let controlCommands = try decodeControlCommands(from: object["control"])
        return .minimal(MinimalInput(netlist: netlist, controlCommands: controlCommands))
    }

    private static func decodeControlCommands(from value: JSONValue?) throws -> [String] {
        guard let value else { return [] }
        switch value {
        case .string(let command):
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        case .array(let values):
            let commands = values.compactMap { item -> String? in
                guard case .string(let string) = item else { return nil }
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            guard commands.count == values.count else {
                throw AutoSageError(
                    code: "invalid_input",
                    message: "control must be a string or an array of strings."
                )
            }
            return commands
        default:
            throw AutoSageError(
                code: "invalid_input",
                message: "control must be a string or an array of strings."
            )
        }
    }

    private static func validateLegacyOptions(_ input: CircuitsSimulateInput) throws {
        switch input.analysis {
        case .op:
            return
        case .tran:
            guard let tran = input.options?.tran else {
                throw AutoSageError(code: "invalid_input", message: "analysis=tran requires options.tran.")
            }
            guard tran.tstop > 0 else {
                throw AutoSageError(code: "invalid_input", message: "options.tran.tstop must be > 0.")
            }
            if let step = tran.step, step <= 0 {
                throw AutoSageError(code: "invalid_input", message: "options.tran.step must be > 0 when provided.")
            }
        case .ac:
            guard let ac = input.options?.ac else {
                throw AutoSageError(code: "invalid_input", message: "analysis=ac requires options.ac.")
            }
            guard ac.fstart > 0, ac.fstop > ac.fstart, ac.points > 0 else {
                throw AutoSageError(code: "invalid_input", message: "options.ac must satisfy fstart>0, fstop>fstart, points>0.")
            }
        case .dc:
            guard let dc = input.options?.dc else {
                throw AutoSageError(code: "invalid_input", message: "analysis=dc requires options.dc.")
            }
            guard !dc.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AutoSageError(code: "invalid_input", message: "options.dc.source is required.")
            }
            guard dc.step != 0 else {
                throw AutoSageError(code: "invalid_input", message: "options.dc.step must be non-zero.")
            }
        }
    }

    private static func makeFinalNetlist(from input: DecodedInput) throws -> String {
        switch input {
        case .minimal(let minimal):
            return makeMinimalNetlist(input: minimal)
        case .legacy(let legacy):
            return try makeLegacyNetlist(input: legacy)
        }
    }

    private static func makeMinimalNetlist(input: MinimalInput) -> String {
        var lines = stripTrailingEndLines(from: input.netlist)
        if !input.controlCommands.isEmpty {
            lines.append(".control")
            lines.append(contentsOf: input.controlCommands)
            lines.append(".endc")
        }
        lines.append(".end")
        return """
        * AutoSage circuits.simulate generated netlist
        \(lines.joined(separator: "\n"))
        """
    }

    private static func makeLegacyNetlist(input: CircuitsSimulateInput) throws -> String {
        let sanitizedBody = sanitizeLegacyNetlist(input.netlist)
        let analysisCommand = try makeAnalysisCommand(input: input)
        let wrdataCommand = makeWrdataCommand(input: input)
        return """
        * AutoSage circuits.simulate generated netlist
        \(sanitizedBody)
        .control
        set wr_vecnames
        set wr_singlescale
        set numdgt=12
        \(analysisCommand)
        \(wrdataCommand)
        quit
        .endc
        .end
        """
    }

    private static func stripTrailingEndLines(from netlist: String) -> [String] {
        var lines = netlist.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        while let last = lines.last,
              last.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == ".end" {
            lines.removeLast()
        }
        while let last = lines.last,
              last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeLast()
        }
        return lines
    }

    private static func sanitizeLegacyNetlist(_ netlist: String) -> String {
        let forbidden = Set([".control", ".endc", ".end", "quit"])
        return netlist
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { line in
                let token = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return !forbidden.contains(token)
            }
            .joined(separator: "\n")
    }

    private static func makeAnalysisCommand(input: CircuitsSimulateInput) throws -> String {
        switch input.analysis {
        case .op:
            return "op"
        case .tran:
            guard let tran = input.options?.tran else {
                throw AutoSageError(code: "invalid_input", message: "analysis=tran requires options.tran.")
            }
            let step = tran.step ?? max(tran.tstop / 1_000.0, 1e-12)
            return "tran \(formatNumber(step)) \(formatNumber(tran.tstop))"
        case .ac:
            guard let ac = input.options?.ac else {
                throw AutoSageError(code: "invalid_input", message: "analysis=ac requires options.ac.")
            }
            return "ac dec \(ac.points) \(formatNumber(ac.fstart)) \(formatNumber(ac.fstop))"
        case .dc:
            guard let dc = input.options?.dc else {
                throw AutoSageError(code: "invalid_input", message: "analysis=dc requires options.dc.")
            }
            let source = dc.source.trimmingCharacters(in: .whitespacesAndNewlines)
            return "dc \(source) \(formatNumber(dc.start)) \(formatNumber(dc.stop)) \(formatNumber(dc.step))"
        }
    }

    private static func makeWrdataCommand(input: CircuitsSimulateInput) -> String {
        let probeExpressions: [String]
        if input.analysis == .ac {
            probeExpressions = input.probes.map { "mag(\($0))" }
        } else {
            probeExpressions = input.probes
        }

        let vectors: [String]
        switch input.analysis {
        case .tran:
            vectors = ["time"] + probeExpressions
        case .ac:
            vectors = ["frequency"] + probeExpressions
        case .dc:
            let source = input.options?.dc?.source.trimmingCharacters(in: .whitespacesAndNewlines) ?? "sweep"
            vectors = [source] + probeExpressions
        case .op:
            vectors = probeExpressions
        }
        return "wrdata data.csv " + vectors.joined(separator: " ")
    }

    private static func collectArtifacts(
        in jobDirectoryURL: URL,
        jobID: String,
        maxArtifactBytes: Int,
        maxArtifacts: Int
    ) -> [ToolArtifact] {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: jobDirectoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var artifacts: [ToolArtifact] = []
        for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard artifacts.count < maxArtifacts else { break }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                continue
            }
            let size = values.fileSize ?? 0
            guard size <= maxArtifactBytes else { continue }
            let name = url.lastPathComponent
            let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
            artifacts.append(
                ToolArtifact(
                    name: name,
                    path: "/v1/jobs/\(jobID)/artifacts/\(encodedName)",
                    mimeType: artifactMimeType(for: name),
                    bytes: size
                )
            )
        }
        return artifacts
    }

    private static func parseSeries(from dataURL: URL, probes: [String], analysis: CircuitsAnalysis) throws -> [CircuitsSeries] {
        let content = try String(contentsOf: dataURL, encoding: .utf8)
        let lines = content
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else {
            throw AutoSageError(code: "solver_failed", message: "data.csv is empty.")
        }

        let dataLines: [String]
        if lines.first?.rangeOfCharacter(from: .letters) != nil {
            dataLines = Array(lines.dropFirst())
        } else {
            dataLines = lines
        }

        let probeCount = probes.count
        guard probeCount > 0 else {
            throw AutoSageError(code: "invalid_input", message: "At least one probe is required.")
        }

        var xValues: [Double] = []
        var yValues: [[Double]] = Array(repeating: [], count: probeCount)
        let expectsX = analysis != .op

        for line in dataLines {
            let columns = splitColumns(line)
            let expected = expectsX ? (probeCount + 1) : probeCount
            guard columns.count >= expected else { continue }

            if expectsX {
                guard let x = parseDouble(columns[0]) else { continue }
                xValues.append(x)
                for index in 0..<probeCount {
                    guard let y = parseDouble(columns[index + 1]) else { continue }
                    yValues[index].append(y)
                }
            } else {
                let x = Double(xValues.count)
                xValues.append(x)
                for index in 0..<probeCount {
                    guard let y = parseDouble(columns[index]) else { continue }
                    yValues[index].append(y)
                }
            }
        }

        let usableCount = min(xValues.count, yValues.map(\.count).min() ?? 0)
        guard usableCount > 0 else {
            throw AutoSageError(code: "solver_failed", message: "No numeric rows were parsed from data.csv.")
        }

        let x = Array(xValues.prefix(usableCount))
        return probes.enumerated().map { index, probe in
            CircuitsSeries(
                probe: probe,
                x: x,
                y: Array(yValues[index].prefix(usableCount))
            )
        }
    }

    private static func capSeries(_ series: [CircuitsSeries], totalPointCap: Int) -> [CircuitsSeries] {
        guard !series.isEmpty else { return series }
        let perSeriesCap = max(1, totalPointCap / series.count)
        return series.map { item in
            let count = min(item.x.count, item.y.count)
            guard count > perSeriesCap else { return item }
            let indices = sampledIndices(count: count, maxCount: perSeriesCap)
            let x = indices.map { item.x[$0] }
            let y = indices.map { item.y[$0] }
            return CircuitsSeries(probe: item.probe, x: x, y: y)
        }
    }

    private static func sampledIndices(count: Int, maxCount: Int) -> [Int] {
        guard count > maxCount else { return Array(0..<count) }
        guard maxCount > 1 else { return [0] }
        let step = Double(count - 1) / Double(maxCount - 1)
        var result: [Int] = []
        result.reserveCapacity(maxCount)
        var previous = -1
        for index in 0..<maxCount {
            let raw = Int((Double(index) * step).rounded())
            let clamped = min(max(raw, 0), count - 1)
            if clamped != previous {
                result.append(clamped)
                previous = clamped
            }
        }
        if result.last != count - 1, !result.isEmpty {
            result[result.count - 1] = count - 1
        }
        return result
    }

    private static func splitColumns(_ line: String) -> [String] {
        if line.contains(",") {
            return line.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        }
        return line.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func parseDouble(_ text: String) -> Double? {
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = Double(token) {
            return value
        }
        if let comma = token.firstIndex(of: ","), comma != token.startIndex {
            let real = String(token[..<comma])
            return Double(real)
        }
        return nil
    }

    private static func encodeJSONValue<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONCoding.makeEncoder().encode(value)
        return try JSONCoding.makeDecoder().decode(JSONValue.self, from: data)
    }

    private static func formatNumber(_ value: Double) -> String {
        String(format: "%.12g", value)
    }

    private static func cappedSummary(_ summary: String, limit: Int) -> String {
        guard summary.count > limit else { return summary }
        return String(summary.prefix(max(3, limit - 3))) + "..."
    }

    private static func lastLines(in text: String, count: Int, maxCharacters: Int) -> String {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        let tail = lines.suffix(count).joined(separator: "\n")
        if tail.count <= maxCharacters {
            return tail
        }
        return String(tail.suffix(maxCharacters))
    }
}
