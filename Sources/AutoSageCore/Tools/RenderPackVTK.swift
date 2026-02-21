// SPDX-License-Identifier: MIT
// AutoSage render pack tool backed by VTK C FFI.

import Foundation
import CVTKFFI
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#else
#error("Unsupported C standard library")
#endif

private struct RenderPackVTKInput: Codable, Equatable, Sendable {
    let inputPath: String
    let width: Int?
    let height: Int?
    let views: [String]?
    let outputColor: Bool?
    let outputDepth: Bool?
    let outputNormal: Bool?

    enum CodingKeys: String, CodingKey {
        case inputPath = "input_path"
        case width
        case height
        case views
        case outputColor = "output_color"
        case outputDepth = "output_depth"
        case outputNormal = "output_normal"
    }
}

public struct RenderPackVTKNativeViewResult: Equatable, Sendable {
    public let colorPath: String?
    public let depthPath: String?
    public let normalPath: String?

    public init(colorPath: String?, depthPath: String?, normalPath: String?) {
        self.colorPath = colorPath
        self.depthPath = depthPath
        self.normalPath = normalPath
    }
}

public struct RenderPackVTKNativeResult: Equatable, Sendable {
    public let views: [RenderPackVTKNativeViewResult]
    public let cameraIntrinsics: [[Double]]
    public let errorCode: Int32
    public let errorMessage: String?

    public init(
        views: [RenderPackVTKNativeViewResult],
        cameraIntrinsics: [[Double]],
        errorCode: Int32,
        errorMessage: String?
    ) {
        self.views = views
        self.cameraIntrinsics = cameraIntrinsics
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }
}

public typealias RenderPackVTKInvoker = @Sendable (
    _ inputPath: String,
    _ outputDirectory: String,
    _ width: Int,
    _ height: Int,
    _ views: [String],
    _ outputColor: Bool,
    _ outputDepth: Bool,
    _ outputNormal: Bool
) throws -> RenderPackVTKNativeResult

public struct RenderPackVTKTool: Tool {
    public let name: String = "render_pack_vtk"
    public let version: String
    public let description: String
    public let jsonSchema: JSONValue = RenderPackVTKTool.schema

    private let invoker: RenderPackVTKInvoker

    public init(
        version: String = "0.1.0",
        description: String = "Headless VTK rendering that exports color/depth/normal packs from predefined camera views.",
        invoker: @escaping RenderPackVTKInvoker = RenderPackVTKTool.defaultInvoker
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

        let width = decoded.width ?? 1024
        let height = decoded.height ?? 768
        guard width >= 16, width <= 8192, height >= 16, height <= 8192 else {
            throw AutoSageError(code: "invalid_input", message: "width and height must be between 16 and 8192.")
        }

        let views = try Self.parseViews(decoded.views)
        let outputColor = decoded.outputColor ?? true
        let outputDepth = decoded.outputDepth ?? true
        let outputNormal = decoded.outputNormal ?? true
        guard outputColor || outputDepth || outputNormal else {
            throw AutoSageError(code: "invalid_input", message: "At least one of output_color/output_depth/output_normal must be true.")
        }

        try FileManager.default.createDirectory(
            at: context.jobDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let nativeResult = try invoker(
            inputURL.path,
            context.jobDirectoryURL.path,
            width,
            height,
            views,
            outputColor,
            outputDepth,
            outputNormal
        )

        if nativeResult.errorCode != 0 {
            throw Self.mapNativeError(nativeResult)
        }

        var artifacts: [ToolArtifact] = []
        var viewObjects: [JSONValue] = []
        for (index, viewName) in views.enumerated() {
            let nativeView = index < nativeResult.views.count ? nativeResult.views[index] : RenderPackVTKNativeViewResult(colorPath: nil, depthPath: nil, normalPath: nil)
            var payload: [String: JSONValue] = ["view": .string(viewName)]

            if let colorPath = nativeView.colorPath {
                let artifact = try Self.makeArtifact(
                    fromNativePath: colorPath,
                    expectedMimeType: "image/png",
                    jobID: context.jobID,
                    jobDirectoryURL: context.jobDirectoryURL,
                    maxArtifactBytes: context.limits.maxArtifactBytes
                )
                artifacts.append(artifact)
                payload["color_path"] = .string(artifact.path)
            }

            if let depthPath = nativeView.depthPath {
                let artifact = try Self.makeArtifact(
                    fromNativePath: depthPath,
                    expectedMimeType: "image/tiff",
                    jobID: context.jobID,
                    jobDirectoryURL: context.jobDirectoryURL,
                    maxArtifactBytes: context.limits.maxArtifactBytes
                )
                artifacts.append(artifact)
                payload["depth_path"] = .string(artifact.path)
            }

            if let normalPath = nativeView.normalPath {
                let artifact = try Self.makeArtifact(
                    fromNativePath: normalPath,
                    expectedMimeType: "image/png",
                    jobID: context.jobID,
                    jobDirectoryURL: context.jobDirectoryURL,
                    maxArtifactBytes: context.limits.maxArtifactBytes
                )
                artifacts.append(artifact)
                payload["normal_path"] = .string(artifact.path)
            }

            viewObjects.append(.object(payload))
        }

        if artifacts.count > context.limits.maxArtifacts {
            throw AutoSageError(
                code: "artifact_too_many",
                message: "Generated artifacts exceed configured max_artifacts limit.",
                details: [
                    "artifact_count": .number(Double(artifacts.count)),
                    "max_artifacts": .number(Double(context.limits.maxArtifacts))
                ]
            )
        }

        let intrinsicsRows = nativeResult.cameraIntrinsics.map { JSONValue.numberArray($0) }
        let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
        let summary = "Rendered \(views.count) view(s) at \(width)x\(height) with VTK."

        let result = ToolExecutionResult(
            status: "ok",
            solver: "vtk",
            summary: Self.cappedSummary(summary, limit: context.limits.maxSummaryCharacters),
            stdout: "",
            stderr: "",
            exitCode: 0,
            artifacts: artifacts,
            metrics: [
                "elapsed_ms": .number(Double(max(0, elapsedMS))),
                "job_id": .string(context.jobID),
                "width": .number(Double(width)),
                "height": .number(Double(height)),
                "num_views": .number(Double(views.count)),
                "output_color": .bool(outputColor),
                "output_depth": .bool(outputDepth),
                "output_normal": .bool(outputNormal)
            ],
            output: .object([
                "views": .array(viewObjects),
                "camera_intrinsics": .array(intrinsicsRows)
            ])
        )
        return try result.asJSONValue()
    }

    public static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "input_path": .object([
                "type": .string("string"),
                "description": .string("Path to input mesh (.obj or .stl).")
            ]),
            "width": .object([
                "type": .string("integer"),
                "description": .string("Render width in pixels.")
            ]),
            "height": .object([
                "type": .string("integer"),
                "description": .string("Render height in pixels.")
            ]),
            "views": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string("Camera views (e.g. isometric, front, top).")
            ]),
            "output_color": .object([
                "type": .string("boolean"),
                "description": .string("Whether to output RGB color buffers.")
            ]),
            "output_depth": .object([
                "type": .string("boolean"),
                "description": .string("Whether to output linear depth buffers.")
            ]),
            "output_normal": .object([
                "type": .string("boolean"),
                "description": .string("Whether to output normal buffers.")
            ])
        ]),
        "required": .stringArray(["input_path"]),
        "additionalProperties": .bool(false)
    ])

    public static let defaultInvoker: RenderPackVTKInvoker = {
        inputPath,
        outputDirectory,
        width,
        height,
        views,
        outputColor,
        outputDepth,
        outputNormal in

        guard let symbols = VTKFFILoader.shared else {
            throw AutoSageError(
                code: "ERR_RENDER_PACK_FAILED",
                message: "vtk_ffi dynamic library not found.",
                details: [
                    "hint": .string("Build Native/vtk_ffi and set AUTOSAGE_VTK_FFI_LIB to libvtk_ffi.dylib.")
                ]
            )
        }

        var duplicatedViews: [UnsafeMutablePointer<CChar>] = []
        duplicatedViews.reserveCapacity(views.count)
        for view in views {
            guard let pointer = strdup(view) else {
                throw AutoSageError(code: "internal_error", message: "Failed to allocate C string for view token.")
            }
            duplicatedViews.append(pointer)
        }
        defer {
            duplicatedViews.forEach { free($0) }
        }

        var cViewPointers: [UnsafePointer<CChar>?] = duplicatedViews.map { UnsafePointer($0) }

        return try inputPath.withCString { cInputPath in
            try outputDirectory.withCString { cOutputDirectory in
                let resultPtr = cViewPointers.withUnsafeBufferPointer { pointerBuffer in
                    symbols.vtkRenderPack(
                        cInputPath,
                        cOutputDirectory,
                        Int32(width),
                        Int32(height),
                        pointerBuffer.baseAddress,
                        Int32(views.count),
                        outputColor ? 1 : 0,
                        outputDepth ? 1 : 0,
                        outputNormal ? 1 : 0
                    )
                }

                guard let resultPtr else {
                    throw AutoSageError(code: "ERR_RENDER_PACK_FAILED", message: "vtk_render_pack returned null.")
                }

                defer {
                    symbols.vtkFreeResult(resultPtr)
                }

                let native = resultPtr.pointee
                let message = native.error_message.map { String(cString: $0) }
                let numViews = max(0, Int(native.num_views))

                var nativeViews: [RenderPackVTKNativeViewResult] = []
                nativeViews.reserveCapacity(numViews)
                if let viewsPointer = native.views, numViews > 0 {
                    for index in 0..<numViews {
                        let item = viewsPointer[index]
                        nativeViews.append(
                            RenderPackVTKNativeViewResult(
                                colorPath: item.color_path.map { String(cString: $0) },
                                depthPath: item.depth_path.map { String(cString: $0) },
                                normalPath: item.normal_path.map { String(cString: $0) }
                            )
                        )
                    }
                }

                let flatIntrinsics: [Float] = withUnsafePointer(to: native.camera_intrinsics) { pointer in
                    pointer.withMemoryRebound(to: Float.self, capacity: 9) { rebound in
                        Array(UnsafeBufferPointer(start: rebound, count: 9))
                    }
                }
                let cameraIntrinsics: [[Double]] = [
                    [Double(flatIntrinsics[0]), Double(flatIntrinsics[1]), Double(flatIntrinsics[2])],
                    [Double(flatIntrinsics[3]), Double(flatIntrinsics[4]), Double(flatIntrinsics[5])],
                    [Double(flatIntrinsics[6]), Double(flatIntrinsics[7]), Double(flatIntrinsics[8])]
                ]

                return RenderPackVTKNativeResult(
                    views: nativeViews,
                    cameraIntrinsics: cameraIntrinsics,
                    errorCode: Int32(native.error_code),
                    errorMessage: message
                )
            }
        }
    }

    private static func decodeInput(_ input: JSONValue?) throws -> RenderPackVTKInput {
        guard let input else {
            throw AutoSageError(code: "invalid_input", message: "render_pack_vtk requires an input object.")
        }
        guard case .object = input else {
            throw AutoSageError(code: "invalid_input", message: "render_pack_vtk input must be an object.")
        }

        let data = try JSONCoding.makeEncoder().encode(input)
        let decoded = try JSONCoding.makeDecoder().decode(RenderPackVTKInput.self, from: data)
        let trimmedPath = decoded.inputPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            throw AutoSageError(code: "invalid_input", message: "input_path must be a non-empty string.")
        }

        return RenderPackVTKInput(
            inputPath: trimmedPath,
            width: decoded.width,
            height: decoded.height,
            views: decoded.views,
            outputColor: decoded.outputColor,
            outputDepth: decoded.outputDepth,
            outputNormal: decoded.outputNormal
        )
    }

    private static func parseViews(_ values: [String]?) throws -> [String] {
        let fallback = ["isometric"]
        let source = (values?.isEmpty == false) ? values! : fallback
        var normalized: [String] = []
        normalized.reserveCapacity(source.count)

        for value in source {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty else {
                throw AutoSageError(code: "invalid_input", message: "views entries must be non-empty strings.")
            }
            normalized.append(trimmed)
        }

        if normalized.count > 32 {
            throw AutoSageError(code: "invalid_input", message: "views may contain at most 32 entries.")
        }
        return normalized
    }

    private static func mapNativeError(_ result: RenderPackVTKNativeResult) -> AutoSageError {
        let message = result.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedMessage = (message?.isEmpty == false) ? message! : "VTK render pack failed."
        let details: [String: JSONValue] = [
            "vtk_error_code": .number(Double(result.errorCode))
        ]

        switch result.errorCode {
        case 1:
            return AutoSageError(code: "invalid_input", message: normalizedMessage, details: details)
        case 2:
            return AutoSageError(code: "ERR_HEADLESS_CONTEXT_FAILED", message: normalizedMessage, details: details)
        case 5:
            return AutoSageError(code: "ERR_BUFFER_EXTRACTION_FAILED", message: normalizedMessage, details: details)
        default:
            return AutoSageError(code: "ERR_RENDER_PACK_FAILED", message: normalizedMessage, details: details)
        }
    }

    private static func makeArtifact(
        fromNativePath nativePath: String,
        expectedMimeType: String,
        jobID: String,
        jobDirectoryURL: URL,
        maxArtifactBytes: Int
    ) throws -> ToolArtifact {
        let fileURL = try resolveNativePath(nativePath, jobDirectoryURL: jobDirectoryURL)

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let bytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
        if bytes > maxArtifactBytes {
            throw AutoSageError(
                code: "artifact_too_large",
                message: "Generated artifact exceeds max artifact size.",
                details: [
                    "artifact": .string(fileURL.lastPathComponent),
                    "bytes": .number(Double(bytes)),
                    "max_artifact_bytes": .number(Double(maxArtifactBytes))
                ]
            )
        }

        let encodedName = fileURL.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fileURL.lastPathComponent
        let resolvedMime = Self.mimeType(for: fileURL.pathExtension, fallback: expectedMimeType)
        return ToolArtifact(
            name: fileURL.lastPathComponent,
            path: "/v1/jobs/\(jobID)/artifacts/\(encodedName)",
            mimeType: resolvedMime,
            bytes: bytes
        )
    }

    private static func resolveNativePath(_ nativePath: String, jobDirectoryURL: URL) throws -> URL {
        let trimmed = nativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AutoSageError(code: "ERR_RENDER_PACK_FAILED", message: "VTK returned an empty artifact path.")
        }

        let candidateURL = URL(fileURLWithPath: trimmed)
        let resolvedURL: URL
        if candidateURL.path.hasPrefix("/") {
            resolvedURL = candidateURL.standardizedFileURL
        } else {
            resolvedURL = jobDirectoryURL.appendingPathComponent(trimmed).standardizedFileURL
        }

        let jobPath = jobDirectoryURL.standardizedFileURL.path
        let resolvedPath = resolvedURL.path
        let jobPrefix = jobPath.hasSuffix("/") ? jobPath : jobPath + "/"

        guard resolvedPath == jobPath || resolvedPath.hasPrefix(jobPrefix) else {
            throw AutoSageError(
                code: "ERR_RENDER_PACK_FAILED",
                message: "VTK output path escaped job directory.",
                details: [
                    "job_directory": .string(jobPath),
                    "artifact_path": .string(resolvedPath)
                ]
            )
        }

        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            throw AutoSageError(
                code: "ERR_RENDER_PACK_FAILED",
                message: "VTK reported an artifact path that does not exist.",
                details: ["artifact_path": .string(resolvedPath)]
            )
        }

        return resolvedURL
    }

    private static func mimeType(for fileExtension: String, fallback: String) -> String {
        switch fileExtension.lowercased() {
        case "png":
            return "image/png"
        case "tif", "tiff":
            return "image/tiff"
        default:
            return fallback
        }
    }

    private static func cappedSummary(_ summary: String, limit: Int) -> String {
        guard summary.count > limit else { return summary }
        return String(summary.prefix(max(3, limit - 3))) + "..."
    }
}

private struct VTKFFISymbols {
    let handle: UnsafeMutableRawPointer
    let vtkRenderPack: @convention(c) (
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        Int32,
        Int32,
        UnsafePointer<UnsafePointer<CChar>?>?,
        Int32,
        Int32,
        Int32,
        Int32
    ) -> UnsafeMutablePointer<VtkRenderOutput>?
    let vtkFreeResult: @convention(c) (UnsafeMutablePointer<VtkRenderOutput>?) -> Void
}

private enum VTKFFILoader {
    static let shared: VTKFFISymbols? = load()

    private static func load() -> VTKFFISymbols? {
        var candidates: [String] = []
        if let configured = ProcessInfo.processInfo.environment["AUTOSAGE_VTK_FFI_LIB"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            candidates.append(configured)
        }

        let cwd = FileManager.default.currentDirectoryPath
        candidates.append(contentsOf: [
            "\(cwd)/Native/vtk_ffi/build/libvtk_ffi.dylib",
            "/opt/homebrew/lib/libvtk_ffi.dylib",
            "/usr/local/lib/libvtk_ffi.dylib",
            "libvtk_ffi.dylib"
        ])

        for path in candidates {
            guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
                continue
            }

            guard let renderSymbol = dlsym(handle, "vtk_render_pack"),
                  let freeSymbol = dlsym(handle, "vtk_free_result") else {
                dlclose(handle)
                continue
            }

            let render = unsafeBitCast(
                renderSymbol,
                to: (@convention(c) (
                    UnsafePointer<CChar>?,
                    UnsafePointer<CChar>?,
                    Int32,
                    Int32,
                    UnsafePointer<UnsafePointer<CChar>?>?,
                    Int32,
                    Int32,
                    Int32,
                    Int32
                ) -> UnsafeMutablePointer<VtkRenderOutput>?).self
            )
            let free = unsafeBitCast(
                freeSymbol,
                to: (@convention(c) (UnsafeMutablePointer<VtkRenderOutput>?) -> Void).self
            )

            return VTKFFISymbols(handle: handle, vtkRenderPack: render, vtkFreeResult: free)
        }

        return nil
    }
}
