// SPDX-License-Identifier: MIT
// AutoSage CAD STEP import tool backed by Truck (Rust FFI).

import Foundation
import CTruckFFI
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#else
#error("Unsupported C standard library")
#endif

private enum CadOutputFormat: String, Codable, CaseIterable {
    case obj
    case stl
    case glb

    var fileExtension: String { rawValue }

    var mimeType: String {
        switch self {
        case .obj:
            return "text/plain; charset=utf-8"
        case .stl:
            return "model/stl"
        case .glb:
            return "model/gltf-binary"
        }
    }
}

private struct CadImportTruckInput: Codable, Equatable, Sendable {
    let filePath: String
    let linearDeflection: Double?
    let outputFormat: String?
    let outputFile: String?

    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case linearDeflection = "linear_deflection"
        case outputFormat = "output_format"
        case outputFile = "output_file"
    }
}

public struct CadTruckMesh: Equatable, Sendable {
    public let vertices: [Float]
    public let indices: [UInt32]
    public let volume: Double
    public let surfaceArea: Double
    public let bboxMin: [Double]
    public let bboxMax: [Double]
    public let watertight: Bool

    public init(
        vertices: [Float],
        indices: [UInt32],
        volume: Double,
        surfaceArea: Double,
        bboxMin: [Double],
        bboxMax: [Double],
        watertight: Bool
    ) {
        self.vertices = vertices
        self.indices = indices
        self.volume = volume
        self.surfaceArea = surfaceArea
        self.bboxMin = bboxMin
        self.bboxMax = bboxMax
        self.watertight = watertight
    }
}

public typealias CadTruckInvoker = @Sendable (_ stepPath: String, _ linearDeflection: Double) throws -> CadTruckMesh

public struct CadImportTruckTool: Tool {
    public let name: String = "cad_import_truck"
    public let version: String
    public let description: String
    public let jsonSchema: JSONValue = CadImportTruckTool.schema

    private let invoker: CadTruckInvoker

    public init(
        version: String = "0.1.0",
        description: String = "Imports STEP CAD geometry via Truck and tessellates to polygon meshes.",
        invoker: @escaping CadTruckInvoker = CadImportTruckTool.defaultInvoker
    ) {
        self.version = version
        self.description = description
        self.invoker = invoker
    }

    public func run(input: JSONValue?, context: ToolExecutionContext) throws -> JSONValue {
        let startedAt = Date()
        let decoded = try Self.decodeInput(input)

        let format = try Self.parseOutputFormat(decoded.outputFormat)
        let linearDeflection = decoded.linearDeflection ?? 0.001
        guard linearDeflection.isFinite, linearDeflection > 0 else {
            throw AutoSageError(
                code: "invalid_input",
                message: "linear_deflection must be > 0."
            )
        }

        let inputURL = URL(fileURLWithPath: decoded.filePath)
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw AutoSageError(
                code: "invalid_input",
                message: "STEP file does not exist.",
                details: ["file_path": .string(inputURL.path)]
            )
        }

        try FileManager.default.createDirectory(
            at: context.jobDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let mesh = try invoker(inputURL.path, linearDeflection)
        let outputName = try Self.normalizedOutputFileName(decoded.outputFile, format: format)
        let outputURL = context.jobDirectoryURL.appendingPathComponent(outputName)

        switch format {
        case .obj:
            try Self.writeOBJ(mesh: mesh, to: outputURL)
        case .stl:
            try Self.writeSTL(mesh: mesh, to: outputURL)
        case .glb:
            try Self.writeGLB(mesh: mesh, to: outputURL)
        }

        let artifactBytes = try Self.ensureArtifactWithinLimit(
            at: outputURL,
            maxArtifactBytes: context.limits.maxArtifactBytes
        )

        let encodedName = outputName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? outputName
        let artifact = ToolArtifact(
            name: outputName,
            path: "/v1/jobs/\(context.jobID)/artifacts/\(encodedName)",
            mimeType: format.mimeType,
            bytes: artifactBytes
        )

        let vertexCount = mesh.vertices.count / 3
        let triangleCount = mesh.indices.count / 3
        let summary = "Imported STEP geometry and generated \(triangleCount) triangle(s) as \(format.fileExtension)."

        let outputPayload: JSONValue = .object([
            "file_name": .string(outputName),
            "format": .string(format.rawValue),
            "vertex_count": .number(Double(vertexCount)),
            "triangle_count": .number(Double(triangleCount)),
            "volume": .number(mesh.volume),
            "surface_area": .number(mesh.surfaceArea),
            "bbox_min": .numberArray(mesh.bboxMin),
            "bbox_max": .numberArray(mesh.bboxMax),
            "watertight": .bool(mesh.watertight)
        ])

        let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
        let result = ToolExecutionResult(
            status: "ok",
            solver: "truck",
            summary: Self.cappedSummary(summary, limit: context.limits.maxSummaryCharacters),
            stdout: "",
            stderr: "",
            exitCode: 0,
            artifacts: [artifact],
            metrics: [
                "elapsed_ms": .number(Double(max(0, elapsedMS))),
                "job_id": .string(context.jobID),
                "vertex_count": .number(Double(vertexCount)),
                "triangle_count": .number(Double(triangleCount)),
                "watertight": .bool(mesh.watertight)
            ],
            output: outputPayload
        )
        return try result.asJSONValue()
    }

    public static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "file_path": .object([
                "type": .string("string"),
                "description": .string("Absolute or working-directory STEP file path.")
            ]),
            "linear_deflection": .object([
                "type": .string("number"),
                "description": .string("Positive tessellation linear deflection.")
            ]),
            "output_format": .object([
                "type": .string("string"),
                "enum": .stringArray(CadOutputFormat.allCases.map(\.rawValue)),
                "description": .string("Target mesh format: obj, stl, or glb.")
            ]),
            "output_file": .object([
                "type": .string("string"),
                "description": .string("Optional output filename. Extension is normalized to match output_format.")
            ])
        ]),
        "required": .stringArray(["file_path"]),
        "additionalProperties": .bool(false)
    ])

    public static let defaultInvoker: CadTruckInvoker = { stepPath, linearDeflection in
        guard let symbols = TruckFFILoader.shared else {
            throw AutoSageError(
                code: "ERR_TESSELLATION_FAILED",
                message: "truck_ffi dynamic library not found.",
                details: [
                    "hint": .string("Build Native/truck_ffi and set AUTOSAGE_TRUCK_FFI_LIB to libtruck_ffi.dylib.")
                ]
            )
        }

        return try stepPath.withCString { cPath -> CadTruckMesh in
            guard let resultPtr = symbols.truckLoadStep(cPath, linearDeflection) else {
                throw AutoSageError(
                    code: "ERR_TESSELLATION_FAILED",
                    message: "truck_load_step returned null."
                )
            }

            defer {
                symbols.truckFreeResult(resultPtr)
            }

            let result = resultPtr.pointee
            if result.error_code != 0 {
                let message: String
                if let cMessage = result.error_message {
                    message = String(cString: cMessage)
                } else {
                    message = "Truck FFI failed with error code \(result.error_code)."
                }
                throw AutoSageError(
                    code: mapTruckErrorCode(result.error_code),
                    message: message,
                    details: ["truck_error_code": .number(Double(result.error_code))]
                )
            }

            let vertexCount = Int(result.vertex_count)
            let indexCount = Int(result.index_count)
            guard vertexCount > 0, vertexCount % 3 == 0 else {
                throw AutoSageError(
                    code: "ERR_TESSELLATION_FAILED",
                    message: "Truck FFI returned an invalid vertex buffer length."
                )
            }
            guard indexCount > 0, indexCount % 3 == 0 else {
                throw AutoSageError(
                    code: "ERR_TESSELLATION_FAILED",
                    message: "Truck FFI returned an invalid index buffer length."
                )
            }
            guard let verticesPointer = result.vertices,
                  let indicesPointer = result.indices else {
                throw AutoSageError(
                    code: "ERR_TESSELLATION_FAILED",
                    message: "Truck FFI returned null mesh buffers."
                )
            }

            let vertices = Array(UnsafeBufferPointer(start: verticesPointer, count: vertexCount))
            let indices = Array(UnsafeBufferPointer(start: indicesPointer, count: indexCount))

            return CadTruckMesh(
                vertices: vertices,
                indices: indices,
                volume: result.volume,
                surfaceArea: result.surface_area,
                bboxMin: [result.bbox_min_x, result.bbox_min_y, result.bbox_min_z],
                bboxMax: [result.bbox_max_x, result.bbox_max_y, result.bbox_max_z],
                watertight: result.watertight != 0
            )
        }
    }

    private static func decodeInput(_ input: JSONValue?) throws -> CadImportTruckInput {
        guard let input else {
            throw AutoSageError(code: "invalid_input", message: "cad_import_truck requires an input object.")
        }
        guard case .object = input else {
            throw AutoSageError(code: "invalid_input", message: "cad_import_truck input must be an object.")
        }

        let data = try JSONCoding.makeEncoder().encode(input)
        let decoded = try JSONCoding.makeDecoder().decode(CadImportTruckInput.self, from: data)
        let path = decoded.filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw AutoSageError(code: "invalid_input", message: "file_path must be a non-empty string.")
        }

        return CadImportTruckInput(
            filePath: path,
            linearDeflection: decoded.linearDeflection,
            outputFormat: decoded.outputFormat,
            outputFile: decoded.outputFile
        )
    }

    private static func parseOutputFormat(_ value: String?) throws -> CadOutputFormat {
        guard let value else {
            return .obj
        }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let format = CadOutputFormat(rawValue: normalized) else {
            throw AutoSageError(
                code: "invalid_input",
                message: "output_format must be one of: obj, stl, glb."
            )
        }
        return format
    }

    private static func normalizedOutputFileName(_ value: String?, format: CadOutputFormat) throws -> String {
        let rawName = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = "mesh.\(format.fileExtension)"
        let candidate = (rawName?.isEmpty == false ? rawName! : fallback)

        let baseName = URL(fileURLWithPath: candidate).lastPathComponent
        guard !baseName.isEmpty, baseName != ".", baseName != ".." else {
            throw AutoSageError(code: "invalid_input", message: "output_file must be a valid filename.")
        }

        let stem = URL(fileURLWithPath: baseName).deletingPathExtension().lastPathComponent
        guard !stem.isEmpty else {
            throw AutoSageError(code: "invalid_input", message: "output_file must include a valid filename stem.")
        }

        return "\(stem).\(format.fileExtension)"
    }

    private static func writeOBJ(mesh: CadTruckMesh, to url: URL) throws {
        var text = "# AutoSage CAD import (Truck)\n"
        text.reserveCapacity(max(256, mesh.vertices.count * 24 + mesh.indices.count * 8))

        for index in stride(from: 0, to: mesh.vertices.count, by: 3) {
            text += "v \(mesh.vertices[index]) \(mesh.vertices[index + 1]) \(mesh.vertices[index + 2])\n"
        }

        for index in stride(from: 0, to: mesh.indices.count, by: 3) {
            let i0 = mesh.indices[index] + 1
            let i1 = mesh.indices[index + 1] + 1
            let i2 = mesh.indices[index + 2] + 1
            text += "f \(i0) \(i1) \(i2)\n"
        }

        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func writeSTL(mesh: CadTruckMesh, to url: URL) throws {
        let triangleCount = mesh.indices.count / 3
        var data = Data(count: 80)
        data.appendUInt32LE(UInt32(triangleCount))

        for index in stride(from: 0, to: mesh.indices.count, by: 3) {
            let i0 = Int(mesh.indices[index]) * 3
            let i1 = Int(mesh.indices[index + 1]) * 3
            let i2 = Int(mesh.indices[index + 2]) * 3

            let p0 = SIMD3<Float>(mesh.vertices[i0], mesh.vertices[i0 + 1], mesh.vertices[i0 + 2])
            let p1 = SIMD3<Float>(mesh.vertices[i1], mesh.vertices[i1 + 1], mesh.vertices[i1 + 2])
            let p2 = SIMD3<Float>(mesh.vertices[i2], mesh.vertices[i2 + 1], mesh.vertices[i2 + 2])

            let normal = normalizedFaceNormal(p0: p0, p1: p1, p2: p2)
            data.appendFloat32LE(normal.x)
            data.appendFloat32LE(normal.y)
            data.appendFloat32LE(normal.z)

            data.appendFloat32LE(p0.x)
            data.appendFloat32LE(p0.y)
            data.appendFloat32LE(p0.z)

            data.appendFloat32LE(p1.x)
            data.appendFloat32LE(p1.y)
            data.appendFloat32LE(p1.z)

            data.appendFloat32LE(p2.x)
            data.appendFloat32LE(p2.y)
            data.appendFloat32LE(p2.z)

            data.appendUInt16LE(0)
        }

        try data.write(to: url, options: .atomic)
    }

    private static func writeGLB(mesh: CadTruckMesh, to url: URL) throws {
        let vertexCount = mesh.vertices.count / 3
        let indexCount = mesh.indices.count

        var positionData = Data(capacity: mesh.vertices.count * MemoryLayout<Float>.size)
        for value in mesh.vertices {
            positionData.appendFloat32LE(value)
        }

        var indexData = Data(capacity: mesh.indices.count * MemoryLayout<UInt32>.size)
        for value in mesh.indices {
            indexData.appendUInt32LE(value)
        }

        var binChunk = Data()
        let positionsOffset = 0
        binChunk.append(positionData)
        padDataTo4(&binChunk)

        let indicesOffset = binChunk.count
        binChunk.append(indexData)
        padDataTo4(&binChunk)

        let jsonObject: [String: Any] = [
            "asset": [
                "version": "2.0",
                "generator": "AutoSage cad_import_truck"
            ],
            "buffers": [
                ["byteLength": binChunk.count]
            ],
            "bufferViews": [
                [
                    "buffer": 0,
                    "byteOffset": positionsOffset,
                    "byteLength": positionData.count,
                    "target": 34962
                ],
                [
                    "buffer": 0,
                    "byteOffset": indicesOffset,
                    "byteLength": indexData.count,
                    "target": 34963
                ]
            ],
            "accessors": [
                [
                    "bufferView": 0,
                    "componentType": 5126,
                    "count": vertexCount,
                    "type": "VEC3",
                    "min": mesh.bboxMin,
                    "max": mesh.bboxMax
                ],
                [
                    "bufferView": 1,
                    "componentType": 5125,
                    "count": indexCount,
                    "type": "SCALAR"
                ]
            ],
            "meshes": [
                [
                    "primitives": [
                        [
                            "attributes": ["POSITION": 0],
                            "indices": 1,
                            "mode": 4
                        ]
                    ]
                ]
            ],
            "nodes": [["mesh": 0]],
            "scenes": [["nodes": [0]]],
            "scene": 0
        ]

        var jsonChunk = try JSONSerialization.data(withJSONObject: jsonObject, options: [.withoutEscapingSlashes])
        padDataTo4(&jsonChunk, paddingByte: 0x20)

        let totalLength = 12 + 8 + jsonChunk.count + 8 + binChunk.count
        var glb = Data(capacity: totalLength)

        glb.appendUInt32LE(0x46546C67)
        glb.appendUInt32LE(2)
        glb.appendUInt32LE(UInt32(totalLength))

        glb.appendUInt32LE(UInt32(jsonChunk.count))
        glb.appendUInt32LE(0x4E4F534A)
        glb.append(jsonChunk)

        glb.appendUInt32LE(UInt32(binChunk.count))
        glb.appendUInt32LE(0x004E4942)
        glb.append(binChunk)

        try glb.write(to: url, options: .atomic)
    }

    private static func ensureArtifactWithinLimit(at url: URL, maxArtifactBytes: Int) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attributes[.size] as? NSNumber)?.intValue ?? 0
        if bytes > maxArtifactBytes {
            try? FileManager.default.removeItem(at: url)
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
        return bytes
    }

    private static func cappedSummary(_ summary: String, limit: Int) -> String {
        guard summary.count > limit else { return summary }
        return String(summary.prefix(max(3, limit - 3))) + "..."
    }
}

private struct TruckFFISymbols {
    let handle: UnsafeMutableRawPointer
    let truckLoadStep: @convention(c) (UnsafePointer<CChar>?, Double) -> UnsafeMutablePointer<TruckMeshResult>?
    let truckFreeResult: @convention(c) (UnsafeMutablePointer<TruckMeshResult>?) -> Void
}

private enum TruckFFILoader {
    static let shared: TruckFFISymbols? = loadSymbols()

    private static func loadSymbols() -> TruckFFISymbols? {
        var candidates: [String] = []
        if let configured = ProcessInfo.processInfo.environment["AUTOSAGE_TRUCK_FFI_LIB"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            candidates.append(configured)
        }

        let cwd = FileManager.default.currentDirectoryPath
        candidates.append(contentsOf: [
            "\(cwd)/Native/truck_ffi/target/release/libtruck_ffi.dylib",
            "\(cwd)/Native/truck_ffi/target/debug/libtruck_ffi.dylib",
            "/opt/homebrew/lib/libtruck_ffi.dylib",
            "/usr/local/lib/libtruck_ffi.dylib",
            "libtruck_ffi.dylib"
        ])

        for candidate in candidates {
            guard let handle = dlopen(candidate, RTLD_NOW | RTLD_LOCAL) else {
                continue
            }

            guard let loadSymbol = dlsym(handle, "truck_load_step"),
                  let freeSymbol = dlsym(handle, "truck_free_result") else {
                dlclose(handle)
                continue
            }

            let loadFn = unsafeBitCast(
                loadSymbol,
                to: (@convention(c) (UnsafePointer<CChar>?, Double) -> UnsafeMutablePointer<TruckMeshResult>?).self
            )
            let freeFn = unsafeBitCast(
                freeSymbol,
                to: (@convention(c) (UnsafeMutablePointer<TruckMeshResult>?) -> Void).self
            )

            return TruckFFISymbols(handle: handle, truckLoadStep: loadFn, truckFreeResult: freeFn)
        }

        return nil
    }
}

private func mapTruckErrorCode(_ value: Int32) -> String {
    switch value {
    case 3:
        return "ERR_STEP_UNSUPPORTED_SCHEMA"
    case 4:
        return "ERR_TESSELLATION_FAILED"
    case 1:
        return "ERR_TESSELLATION_FAILED"
    case 2:
        return "ERR_TESSELLATION_FAILED"
    case 5:
        return "ERR_TESSELLATION_FAILED"
    default:
        return "ERR_TESSELLATION_FAILED"
    }
}

private func normalizedFaceNormal(p0: SIMD3<Float>, p1: SIMD3<Float>, p2: SIMD3<Float>) -> SIMD3<Float> {
    let u = p1 - p0
    let v = p2 - p0
    let cross = SIMD3<Float>(
        u.y * v.z - u.z * v.y,
        u.z * v.x - u.x * v.z,
        u.x * v.y - u.y * v.x
    )
    let length = sqrt(cross.x * cross.x + cross.y * cross.y + cross.z * cross.z)
    guard length > 0 else {
        return SIMD3<Float>(repeating: 0)
    }
    return cross / length
}

private func padDataTo4(_ data: inout Data, paddingByte: UInt8 = 0x00) {
    let remainder = data.count % 4
    if remainder == 0 {
        return
    }
    data.append(contentsOf: Array(repeating: paddingByte, count: 4 - remainder))
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            self.append(contentsOf: bytes)
        }
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            self.append(contentsOf: bytes)
        }
    }

    mutating func appendFloat32LE(_ value: Float) {
        appendUInt32LE(value.bitPattern)
    }
}
