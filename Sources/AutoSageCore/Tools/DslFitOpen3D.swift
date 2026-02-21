// SPDX-License-Identifier: MIT
// AutoSage primitive fitting tool backed by Open3D C FFI.

import Foundation
import COpen3DFFI
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#else
#error("Unsupported C standard library")
#endif

private struct DslFitOpen3DInput: Codable, Equatable, Sendable {
    let inputPath: String
    let distanceThreshold: Double?
    let ransacN: Int?
    let numIterations: Int?

    enum CodingKeys: String, CodingKey {
        case inputPath = "input_path"
        case distanceThreshold = "distance_threshold"
        case ransacN = "ransac_n"
        case numIterations = "num_iterations"
    }
}

public struct DslFitOpen3DPrimitive: Equatable, Sendable {
    public let type: String
    public let parameters: [Double]
    public let inlierRatio: Double

    public init(type: String, parameters: [Double], inlierRatio: Double) {
        self.type = type
        self.parameters = parameters
        self.inlierRatio = inlierRatio
    }
}

public struct DslFitOpen3DNativeResult: Equatable, Sendable {
    public let primitives: [DslFitOpen3DPrimitive]
    public let unassignedPointsRatio: Double
    public let errorCode: Int32
    public let errorMessage: String?

    public init(
        primitives: [DslFitOpen3DPrimitive],
        unassignedPointsRatio: Double,
        errorCode: Int32,
        errorMessage: String?
    ) {
        self.primitives = primitives
        self.unassignedPointsRatio = unassignedPointsRatio
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }
}

public typealias DslFitOpen3DInvoker = @Sendable (
    _ inputPath: String,
    _ distanceThreshold: Double,
    _ ransacN: Int,
    _ numIterations: Int
) throws -> DslFitOpen3DNativeResult

public struct DslFitOpen3DTool: Tool {
    public let name: String = "dsl_fit_open3d"
    public let version: String
    public let description: String
    public let jsonSchema: JSONValue = DslFitOpen3DTool.schema

    private let invoker: DslFitOpen3DInvoker

    public init(
        version: String = "0.1.0",
        description: String = "Extracts geometric primitives from meshes using Open3D point-cloud sampling and iterative RANSAC.",
        invoker: @escaping DslFitOpen3DInvoker = DslFitOpen3DTool.defaultInvoker
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

        let distanceThreshold = decoded.distanceThreshold ?? 0.01
        let ransacN = decoded.ransacN ?? 3
        let numIterations = decoded.numIterations ?? 1000

        guard distanceThreshold.isFinite, distanceThreshold > 0 else {
            throw AutoSageError(code: "invalid_input", message: "distance_threshold must be > 0.")
        }
        guard ransacN >= 3 else {
            throw AutoSageError(code: "invalid_input", message: "ransac_n must be >= 3.")
        }
        guard numIterations >= 16 else {
            throw AutoSageError(code: "invalid_input", message: "num_iterations must be >= 16.")
        }

        let nativeResult = try invoker(
            inputURL.path,
            distanceThreshold,
            ransacN,
            numIterations
        )
        if nativeResult.errorCode != 0 {
            throw Self.mapNativeError(nativeResult)
        }

        let primitiveValues = nativeResult.primitives.map(Self.jsonPrimitive(from:))
        let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
        let summary = "Extracted \(primitiveValues.count) primitive(s) with Open3D."

        let result = ToolExecutionResult(
            status: "ok",
            solver: "open3d",
            summary: Self.cappedSummary(summary, limit: context.limits.maxSummaryCharacters),
            stdout: "",
            stderr: "",
            exitCode: 0,
            artifacts: [],
            metrics: [
                "elapsed_ms": .number(Double(max(0, elapsedMS))),
                "job_id": .string(context.jobID),
                "primitive_count": .number(Double(primitiveValues.count)),
                "unassigned_points_ratio": .number(nativeResult.unassignedPointsRatio),
                "distance_threshold": .number(distanceThreshold),
                "ransac_n": .number(Double(ransacN)),
                "num_iterations": .number(Double(numIterations))
            ],
            output: .object([
                "primitives": .array(primitiveValues),
                "unassigned_points_ratio": .number(nativeResult.unassignedPointsRatio)
            ])
        )
        return try result.asJSONValue()
    }

    public static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "input_path": .object([
                "type": .string("string"),
                "description": .string("Path to input triangle mesh (.obj/.stl/etc supported by Open3D).")
            ]),
            "distance_threshold": .object([
                "type": .string("number"),
                "description": .string("RANSAC inlier distance threshold.")
            ]),
            "ransac_n": .object([
                "type": .string("integer"),
                "description": .string("Number of points sampled per RANSAC hypothesis.")
            ]),
            "num_iterations": .object([
                "type": .string("integer"),
                "description": .string("Maximum number of RANSAC iterations per primitive.")
            ])
        ]),
        "required": .stringArray(["input_path"]),
        "additionalProperties": .bool(false)
    ])

    public static let defaultInvoker: DslFitOpen3DInvoker = {
        inputPath,
        distanceThreshold,
        ransacN,
        numIterations in

        guard let symbols = Open3DFFILoader.shared else {
            throw AutoSageError(
                code: "ERR_PRIMITIVE_FIT_FAILED",
                message: "open3d_ffi dynamic library not found.",
                details: [
                    "hint": .string("Build Native/open3d_ffi and set AUTOSAGE_OPEN3D_FFI_LIB to libopen3d_ffi.dylib.")
                ]
            )
        }

        return try inputPath.withCString { cInputPath in
            guard let resultPtr = symbols.open3dExtractPrimitives(
                cInputPath,
                Float(distanceThreshold),
                Int32(ransacN),
                Int32(numIterations)
            ) else {
                throw AutoSageError(code: "ERR_PRIMITIVE_FIT_FAILED", message: "open3d_extract_primitives returned null.")
            }

            defer {
                symbols.open3dFreeResult(resultPtr)
            }

            let native = resultPtr.pointee
            let message = native.error_message.map { String(cString: $0) }
            let primitiveCount = max(0, Int(native.num_primitives))

            var primitives: [DslFitOpen3DPrimitive] = []
            primitives.reserveCapacity(primitiveCount)
            if let primitivePtr = native.primitives, primitiveCount > 0 {
                for index in 0..<primitiveCount {
                    let primitive = primitivePtr[index]
                    let type = primitive.type.map { String(cString: $0) } ?? "unknown"
                    let parameters: [Double] = withUnsafePointer(to: primitive.parameters) { pointer in
                        pointer.withMemoryRebound(to: Float.self, capacity: 10) { rebound in
                            Array(UnsafeBufferPointer(start: rebound, count: 10)).map(Double.init)
                        }
                    }

                    primitives.append(
                        DslFitOpen3DPrimitive(
                            type: type,
                            parameters: parameters,
                            inlierRatio: Double(primitive.inlier_ratio)
                        )
                    )
                }
            }

            return DslFitOpen3DNativeResult(
                primitives: primitives,
                unassignedPointsRatio: Double(native.unassigned_points_ratio),
                errorCode: Int32(native.error_code),
                errorMessage: message
            )
        }
    }

    private static func decodeInput(_ input: JSONValue?) throws -> DslFitOpen3DInput {
        guard let input else {
            throw AutoSageError(code: "invalid_input", message: "dsl_fit_open3d requires an input object.")
        }
        guard case .object = input else {
            throw AutoSageError(code: "invalid_input", message: "dsl_fit_open3d input must be an object.")
        }

        let data = try JSONCoding.makeEncoder().encode(input)
        let decoded = try JSONCoding.makeDecoder().decode(DslFitOpen3DInput.self, from: data)
        let trimmedPath = decoded.inputPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            throw AutoSageError(code: "invalid_input", message: "input_path must be a non-empty string.")
        }

        return DslFitOpen3DInput(
            inputPath: trimmedPath,
            distanceThreshold: decoded.distanceThreshold,
            ransacN: decoded.ransacN,
            numIterations: decoded.numIterations
        )
    }

    private static func mapNativeError(_ result: DslFitOpen3DNativeResult) -> AutoSageError {
        let message = result.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMessage = (message?.isEmpty == false) ? message! : "Open3D primitive fitting failed."
        let details: [String: JSONValue] = [
            "open3d_error_code": .number(Double(result.errorCode)),
            "unassigned_points_ratio": .number(result.unassignedPointsRatio)
        ]

        switch result.errorCode {
        case 1:
            return AutoSageError(code: "invalid_input", message: normalizedMessage, details: details)
        case 3:
            return AutoSageError(code: "ERR_POINTCLOUD_GENERATION_FAILED", message: normalizedMessage, details: details)
        case 4:
            return AutoSageError(code: "ERR_PRIMITIVE_FIT_TIMEOUT", message: normalizedMessage, details: details)
        default:
            return AutoSageError(code: "ERR_PRIMITIVE_FIT_FAILED", message: normalizedMessage, details: details)
        }
    }

    private static func jsonPrimitive(from primitive: DslFitOpen3DPrimitive) -> JSONValue {
        let type = primitive.type.lowercased()
        var payload: [String: JSONValue] = [
            "type": .string(type),
            "inlier_ratio": .number(primitive.inlierRatio),
            "raw_parameters": .numberArray(primitive.parameters)
        ]

        switch type {
        case "plane":
            payload["coefficients"] = .numberArray(Array(primitive.parameters.prefix(4)))
        case "sphere":
            payload["center"] = .numberArray(Array(primitive.parameters.prefix(3)))
            payload["radius"] = .number(primitive.parameters.count > 3 ? primitive.parameters[3] : 0.0)
        case "cylinder":
            payload["axis_point"] = .numberArray(Array(primitive.parameters.prefix(3)))
            if primitive.parameters.count >= 6 {
                payload["axis_direction"] = .numberArray(Array(primitive.parameters[3...5]))
            } else {
                payload["axis_direction"] = .numberArray([0.0, 0.0, 1.0])
            }
            payload["radius"] = .number(primitive.parameters.count > 6 ? primitive.parameters[6] : 0.0)
        default:
            break
        }

        return .object(payload)
    }

    private static func cappedSummary(_ summary: String, limit: Int) -> String {
        guard summary.count > limit else { return summary }
        return String(summary.prefix(max(3, limit - 3))) + "..."
    }
}

private struct Open3DFFISymbols {
    let handle: UnsafeMutableRawPointer
    let open3dExtractPrimitives: @convention(c) (
        UnsafePointer<CChar>?,
        Float,
        Int32,
        Int32
    ) -> UnsafeMutablePointer<O3DResult>?
    let open3dFreeResult: @convention(c) (UnsafeMutablePointer<O3DResult>?) -> Void
}

private enum Open3DFFILoader {
    static let shared: Open3DFFISymbols? = load()

    private static func load() -> Open3DFFISymbols? {
        var candidates: [String] = []
        if let configured = ProcessInfo.processInfo.environment["AUTOSAGE_OPEN3D_FFI_LIB"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            candidates.append(configured)
        }

        let cwd = FileManager.default.currentDirectoryPath
        candidates.append(contentsOf: [
            "\(cwd)/Native/open3d_ffi/build/libopen3d_ffi.dylib",
            "/opt/homebrew/lib/libopen3d_ffi.dylib",
            "/usr/local/lib/libopen3d_ffi.dylib",
            "libopen3d_ffi.dylib"
        ])

        for path in candidates {
            guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
                continue
            }

            guard let extractSymbol = dlsym(handle, "open3d_extract_primitives"),
                  let freeSymbol = dlsym(handle, "open3d_free_result") else {
                dlclose(handle)
                continue
            }

            let extract = unsafeBitCast(
                extractSymbol,
                to: (@convention(c) (
                    UnsafePointer<CChar>?,
                    Float,
                    Int32,
                    Int32
                ) -> UnsafeMutablePointer<O3DResult>?).self
            )
            let free = unsafeBitCast(
                freeSymbol,
                to: (@convention(c) (UnsafeMutablePointer<O3DResult>?) -> Void).self
            )

            return Open3DFFISymbols(handle: handle, open3dExtractPrimitives: extract, open3dFreeResult: free)
        }

        return nil
    }
}
