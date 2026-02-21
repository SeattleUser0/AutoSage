// SPDX-License-Identifier: MIT
// AutoSage volume tetrahedral meshing tool backed by Quartet C FFI.

import Foundation
import CQuartetFFI
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#else
#error("Unsupported C standard library")
#endif

private struct VolumeMeshQuartetInput: Codable, Equatable, Sendable {
    let inputPath: String
    let outputFile: String?
    let dx: Double?
    let optimizeQuality: Bool?
    let featureAngleThreshold: Double?

    enum CodingKeys: String, CodingKey {
        case inputPath = "input_path"
        case outputFile = "output_file"
        case dx
        case optimizeQuality = "optimize_quality"
        case featureAngleThreshold = "feature_angle_threshold"
    }
}

public struct VolumeMeshQuartetStats: Equatable, Sendable {
    public let nodeCount: Int
    public let tetrahedraCount: Int
    public let worstElementQuality: Double

    public init(nodeCount: Int, tetrahedraCount: Int, worstElementQuality: Double) {
        self.nodeCount = nodeCount
        self.tetrahedraCount = tetrahedraCount
        self.worstElementQuality = worstElementQuality
    }

    public var asJSONValue: JSONValue {
        .object([
            "node_count": .number(Double(nodeCount)),
            "tetrahedra_count": .number(Double(tetrahedraCount)),
            "worst_element_quality": .number(worstElementQuality)
        ])
    }
}

public struct VolumeMeshQuartetNativeResult: Equatable, Sendable {
    public let stats: VolumeMeshQuartetStats
    public let errorCode: Int32
    public let errorMessage: String?

    public init(stats: VolumeMeshQuartetStats, errorCode: Int32, errorMessage: String?) {
        self.stats = stats
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }
}

public typealias VolumeMeshQuartetInvoker = @Sendable (
    _ inputPath: String,
    _ outputPath: String,
    _ dx: Double,
    _ optimizeQuality: Bool,
    _ featureAngleThreshold: Double
) throws -> VolumeMeshQuartetNativeResult

public struct VolumeMeshQuartetTool: Tool {
    public let name: String = "volume_mesh_quartet"
    public let version: String
    public let description: String
    public let jsonSchema: JSONValue = VolumeMeshQuartetTool.schema

    private let invoker: VolumeMeshQuartetInvoker

    public init(
        version: String = "0.1.0",
        description: String = "Generates tetrahedral volume meshes using Quartet isosurface stuffing and optimization.",
        invoker: @escaping VolumeMeshQuartetInvoker = VolumeMeshQuartetTool.defaultInvoker
    ) {
        self.version = version
        self.description = description
        self.invoker = invoker
    }

    public func run(input: JSONValue?, context: ToolExecutionContext) throws -> JSONValue {
        let startedAt = Date()
        let decoded = try Self.decodeInput(input)

        let inputURL = URL(fileURLWithPath: decoded.inputPath)
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw AutoSageError(
                code: "invalid_input",
                message: "input_path does not exist.",
                details: ["input_path": .string(inputURL.path)]
            )
        }

        let dx = decoded.dx ?? 0.05
        guard dx.isFinite, dx > 0 else {
            throw AutoSageError(code: "invalid_input", message: "dx must be a finite number greater than 0.")
        }

        let optimizeQuality = decoded.optimizeQuality ?? true
        let featureAngleThreshold = decoded.featureAngleThreshold ?? 45.0
        guard featureAngleThreshold.isFinite else {
            throw AutoSageError(code: "invalid_input", message: "feature_angle_threshold must be finite.")
        }

        try FileManager.default.createDirectory(
            at: context.jobDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let outputFileName = try Self.normalizedOutputFileName(decoded.outputFile)
        let outputURL = context.jobDirectoryURL.appendingPathComponent(outputFileName)

        let nativeResult = try invoker(
            inputURL.path,
            outputURL.path,
            dx,
            optimizeQuality,
            featureAngleThreshold
        )

        if nativeResult.errorCode != 0 {
            throw Self.mapNativeError(nativeResult)
        }

        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw AutoSageError(
                code: "ERR_VOLUME_MESH_FAILED",
                message: "Quartet did not produce an output .tet file.",
                details: ["expected_path": .string(outputURL.path)]
            )
        }

        let artifact = try Self.makeArtifact(
            for: outputURL,
            jobID: context.jobID,
            maxArtifactBytes: context.limits.maxArtifactBytes
        )

        let stats = nativeResult.stats
        let summary = "Generated tetrahedral mesh with \(stats.nodeCount) node(s) and \(stats.tetrahedraCount) element(s)."
        let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)

        let result = ToolExecutionResult(
            status: "ok",
            solver: "quartet",
            summary: Self.cappedSummary(summary, limit: context.limits.maxSummaryCharacters),
            stdout: "",
            stderr: "",
            exitCode: 0,
            artifacts: [artifact],
            metrics: [
                "elapsed_ms": .number(Double(max(0, elapsedMS))),
                "job_id": .string(context.jobID),
                "dx": .number(dx),
                "optimize_quality": .bool(optimizeQuality),
                "feature_angle_threshold": .number(featureAngleThreshold),
                "node_count": .number(Double(stats.nodeCount)),
                "tetrahedra_count": .number(Double(stats.tetrahedraCount)),
                "worst_element_quality": .number(stats.worstElementQuality)
            ],
            output: .object([
                "output_file": .string(outputFileName),
                "stats": stats.asJSONValue
            ])
        )

        return try result.asJSONValue()
    }

    public static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "input_path": .object([
                "type": .string("string"),
                "description": .string("Path to a watertight OBJ surface mesh.")
            ]),
            "output_file": .object([
                "type": .string("string"),
                "description": .string("Optional .tet output filename placed in the job directory.")
            ]),
            "dx": .object([
                "type": .string("number"),
                "description": .string("Target grid spacing for isosurface stuffing.")
            ]),
            "optimize_quality": .object([
                "type": .string("boolean"),
                "description": .string("Whether to enable Quartet optimization passes.")
            ]),
            "feature_angle_threshold": .object([
                "type": .string("number"),
                "description": .string("Automatic feature edge detection threshold in degrees.")
            ])
        ]),
        "required": .stringArray(["input_path"]),
        "additionalProperties": .bool(false)
    ])

    public static let defaultInvoker: VolumeMeshQuartetInvoker = {
        inputPath,
        outputPath,
        dx,
        optimizeQuality,
        featureAngleThreshold in

        guard let symbols = QuartetFFILoader.shared else {
            throw AutoSageError(
                code: "ERR_VOLUME_MESH_FAILED",
                message: "quartet_ffi dynamic library not found.",
                details: [
                    "hint": .string("Build Native/quartet_ffi and set AUTOSAGE_QUARTET_FFI_LIB to libquartet_ffi.dylib.")
                ]
            )
        }

        return try inputPath.withCString { cInputPath in
            try outputPath.withCString { cOutputPath in
                guard let resultPtr = symbols.quartetGenerateMesh(
                    cInputPath,
                    cOutputPath,
                    Float(dx),
                    optimizeQuality ? 1 : 0,
                    Float(featureAngleThreshold)
                ) else {
                    throw AutoSageError(
                        code: "ERR_VOLUME_MESH_FAILED",
                        message: "quartet_generate_mesh returned null."
                    )
                }

                defer {
                    symbols.quartetFreeResult(resultPtr)
                }

                let native = resultPtr.pointee
                let stats = VolumeMeshQuartetStats(
                    nodeCount: Int(native.stats.node_count),
                    tetrahedraCount: Int(native.stats.tetrahedra_count),
                    worstElementQuality: Double(native.stats.worst_element_quality)
                )
                let message = native.error_message.map { String(cString: $0) }

                return VolumeMeshQuartetNativeResult(
                    stats: stats,
                    errorCode: Int32(native.error_code),
                    errorMessage: message
                )
            }
        }
    }

    private static func decodeInput(_ input: JSONValue?) throws -> VolumeMeshQuartetInput {
        guard let input else {
            throw AutoSageError(code: "invalid_input", message: "volume_mesh_quartet requires an input object.")
        }
        guard case .object = input else {
            throw AutoSageError(code: "invalid_input", message: "volume_mesh_quartet input must be an object.")
        }

        let data = try JSONCoding.makeEncoder().encode(input)
        let decoded = try JSONCoding.makeDecoder().decode(VolumeMeshQuartetInput.self, from: data)
        let trimmedPath = decoded.inputPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            throw AutoSageError(code: "invalid_input", message: "input_path must be a non-empty string.")
        }

        return VolumeMeshQuartetInput(
            inputPath: trimmedPath,
            outputFile: decoded.outputFile,
            dx: decoded.dx,
            optimizeQuality: decoded.optimizeQuality,
            featureAngleThreshold: decoded.featureAngleThreshold
        )
    }

    private static func normalizedOutputFileName(_ value: String?) throws -> String {
        let rawName = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = "volume_mesh.tet"
        let candidate = (rawName?.isEmpty == false ? rawName! : fallback)

        let baseName = URL(fileURLWithPath: candidate).lastPathComponent
        guard !baseName.isEmpty, baseName != ".", baseName != ".." else {
            throw AutoSageError(code: "invalid_input", message: "output_file must be a valid filename.")
        }

        let stem = URL(fileURLWithPath: baseName).deletingPathExtension().lastPathComponent
        guard !stem.isEmpty else {
            throw AutoSageError(code: "invalid_input", message: "output_file must include a valid filename stem.")
        }
        return "\(stem).tet"
    }

    private static func mapNativeError(_ result: VolumeMeshQuartetNativeResult) -> AutoSageError {
        let message = result.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMessage = (message?.isEmpty == false) ? message! : "Quartet volume meshing failed."
        let details: [String: JSONValue] = [
            "quartet_error_code": .number(Double(result.errorCode)),
            "stats": result.stats.asJSONValue
        ]

        switch result.errorCode {
        case 1:
            return AutoSageError(code: "invalid_input", message: normalizedMessage, details: details)
        case 3:
            return AutoSageError(code: "ERR_NOT_WATERTIGHT", message: normalizedMessage, details: details)
        case 4:
            return AutoSageError(code: "ERR_INVALID_DX", message: normalizedMessage, details: details)
        default:
            return AutoSageError(code: "ERR_VOLUME_MESH_FAILED", message: normalizedMessage, details: details)
        }
    }

    private static func makeArtifact(for url: URL, jobID: String, maxArtifactBytes: Int) throws -> ToolArtifact {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
        if bytes > maxArtifactBytes {
            throw AutoSageError(
                code: "artifact_too_large",
                message: "Generated artifact exceeds max artifact size.",
                details: [
                    "artifact": .string(url.lastPathComponent),
                    "bytes": .number(Double(bytes)),
                    "max_artifact_bytes": .number(Double(maxArtifactBytes))
                ]
            )
        }

        let encodedName = url.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.lastPathComponent
        return ToolArtifact(
            name: url.lastPathComponent,
            path: "/v1/jobs/\(jobID)/artifacts/\(encodedName)",
            mimeType: "application/octet-stream",
            bytes: bytes
        )
    }

    private static func cappedSummary(_ summary: String, limit: Int) -> String {
        guard summary.count > limit else { return summary }
        return String(summary.prefix(max(3, limit - 3))) + "..."
    }
}

private struct QuartetFFISymbols {
    let handle: UnsafeMutableRawPointer
    let quartetGenerateMesh: @convention(c) (
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        Float,
        Int32,
        Float
    ) -> UnsafeMutablePointer<QuartetResult>?
    let quartetFreeResult: @convention(c) (UnsafeMutablePointer<QuartetResult>?) -> Void
}

private enum QuartetFFILoader {
    static let shared: QuartetFFISymbols? = load()

    private static func load() -> QuartetFFISymbols? {
        var candidates: [String] = []
        if let configured = ProcessInfo.processInfo.environment["AUTOSAGE_QUARTET_FFI_LIB"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            candidates.append(configured)
        }

        let cwd = FileManager.default.currentDirectoryPath
        candidates.append(contentsOf: [
            "\(cwd)/Native/quartet_ffi/build/libquartet_ffi.dylib",
            "/opt/homebrew/lib/libquartet_ffi.dylib",
            "/usr/local/lib/libquartet_ffi.dylib",
            "libquartet_ffi.dylib"
        ])

        for path in candidates {
            guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
                continue
            }

            guard let generateSymbol = dlsym(handle, "quartet_generate_mesh"),
                  let freeSymbol = dlsym(handle, "quartet_free_result") else {
                dlclose(handle)
                continue
            }

            let generate = unsafeBitCast(
                generateSymbol,
                to: (@convention(c) (
                    UnsafePointer<CChar>?,
                    UnsafePointer<CChar>?,
                    Float,
                    Int32,
                    Float
                ) -> UnsafeMutablePointer<QuartetResult>?).self
            )
            let free = unsafeBitCast(
                freeSymbol,
                to: (@convention(c) (UnsafeMutablePointer<QuartetResult>?) -> Void).self
            )

            return QuartetFFISymbols(handle: handle, quartetGenerateMesh: generate, quartetFreeResult: free)
        }

        return nil
    }
}
