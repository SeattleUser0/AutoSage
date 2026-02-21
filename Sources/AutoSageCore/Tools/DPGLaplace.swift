// SPDX-License-Identifier: MIT
// AutoSage DPG Laplace tool wrapper for MFEM driver.

import Foundation

private struct DPGLaplaceBoundaryCondition: Codable, Equatable, Sendable {
    let attribute: Int
    let type: String
    let value: Double
}

private struct DPGLaplaceConfig: Codable, Equatable, Sendable {
    let coefficient: Double
    let sourceTerm: Double?
    let order: Int?
    let bcs: [DPGLaplaceBoundaryCondition]

    enum CodingKeys: String, CodingKey {
        case coefficient
        case sourceTerm = "source_term"
        case order
        case bcs
    }
}

private struct DPGLaplaceInput: Codable, Equatable, Sendable {
    let solverClass: String?
    let mesh: JSONValue
    let config: DPGLaplaceConfig

    enum CodingKeys: String, CodingKey {
        case solverClass = "solver_class"
        case mesh
        case config
    }
}

public struct DPGLaplaceTool: Tool {
    public let name: String = "dpg_laplace.solve"
    public let version: String
    public let description: String
    public let jsonSchema: JSONValue = DPGLaplaceTool.schema

    private let feaBridge: FEATool

    public init(
        version: String = "0.1.0",
        description: String = "Solves Laplace equations with a DPG least-squares formulation and interfacial trace unknowns.",
        driverRunner: @escaping FEADriverRunner = FEATool.defaultDriverRunner,
        driverResolver: @escaping @Sendable () -> String? = FEATool.defaultDriverResolverClosure
    ) {
        self.version = version
        self.description = description
        self.feaBridge = FEATool(
            version: version,
            description: description,
            driverRunner: driverRunner,
            driverResolver: driverResolver
        )
    }

    public func run(input: JSONValue?, context: ToolExecutionContext) throws -> JSONValue {
        let decoded = try Self.decodeInput(input)
        let payload = try Self.toDriverPayload(decoded)
        return try feaBridge.run(input: .object(payload), context: context)
    }

    public static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "solver_class": .object([
                "type": .string("string"),
                "enum": .stringArray(["DPGLaplace"])
            ]),
            "mesh": .object([
                "type": .string("object"),
                "description": .string("Mesh source passed through to mfem-driver."),
                "properties": .object([
                    "type": .object([
                        "type": .string("string"),
                        "enum": .stringArray(["inline_mfem", "file"])
                    ]),
                    "data": .object(["type": .string("string")]),
                    "path": .object(["type": .string("string")]),
                    "encoding": .object([
                        "type": .string("string"),
                        "enum": .stringArray(["plain", "base64"])
                    ])
                ]),
                "required": .stringArray(["type"]),
                "additionalProperties": .bool(true)
            ]),
            "config": .object([
                "type": .string("object"),
                "properties": .object([
                    "coefficient": .object(["type": .string("number")]),
                    "source_term": .object(["type": .string("number")]),
                    "order": .object(["type": .string("integer")]),
                    "bcs": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "attribute": .object(["type": .string("integer")]),
                                "type": .object([
                                    "type": .string("string"),
                                    "enum": .stringArray(["fixed"])
                                ]),
                                "value": .object(["type": .string("number")])
                            ]),
                            "required": .stringArray(["attribute", "type", "value"])
                        ])
                    ])
                ]),
                "required": .stringArray(["coefficient", "bcs"])
            ])
        ]),
        "required": .stringArray(["mesh", "config"]),
        "additionalProperties": .bool(true)
    ])

    private static func decodeInput(_ input: JSONValue?) throws -> DPGLaplaceInput {
        guard let input else {
            throw AutoSageError(code: "invalid_input", message: "dpg_laplace.solve requires an input object.")
        }
        guard case .object = input else {
            throw AutoSageError(code: "invalid_input", message: "dpg_laplace.solve input must be an object.")
        }

        let data = try JSONCoding.makeEncoder().encode(input)
        let decoded = try JSONCoding.makeDecoder().decode(DPGLaplaceInput.self, from: data)

        if let solverClass = decoded.solverClass {
            let normalized = solverClass.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized == "dpglaplace" || normalized == "dpg_laplace" || normalized == "dpg-laplace" else {
                throw AutoSageError(code: "invalid_input", message: "solver_class must be DPGLaplace.")
            }
        }

        guard case .object(let meshObject) = decoded.mesh else {
            throw AutoSageError(code: "invalid_input", message: "mesh must be an object.")
        }
        guard case .string(let meshTypeRaw)? = meshObject["type"] else {
            throw AutoSageError(code: "invalid_input", message: "mesh.type is required and must be a string.")
        }
        let meshType = meshTypeRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard meshType == "inline_mfem" || meshType == "file" else {
            throw AutoSageError(code: "invalid_input", message: "mesh.type must be inline_mfem or file.")
        }
        if meshType == "inline_mfem" {
            guard case .string(let data)? = meshObject["data"],
                  !data.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AutoSageError(code: "invalid_input", message: "mesh.data is required for mesh.type=inline_mfem.")
            }
        } else {
            guard case .string(let path)? = meshObject["path"],
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AutoSageError(code: "invalid_input", message: "mesh.path is required for mesh.type=file.")
            }
        }

        guard decoded.config.coefficient.isFinite, decoded.config.coefficient > 0 else {
            throw AutoSageError(code: "invalid_input", message: "config.coefficient must be finite and > 0.")
        }
        if let sourceTerm = decoded.config.sourceTerm, !sourceTerm.isFinite {
            throw AutoSageError(code: "invalid_input", message: "config.source_term must be finite when provided.")
        }
        if let order = decoded.config.order {
            guard order >= 1 else {
                throw AutoSageError(code: "invalid_input", message: "config.order must be >= 1 when provided.")
            }
            guard order <= 8 else {
                throw AutoSageError(code: "invalid_input", message: "config.order must be <= 8 when provided.")
            }
        }
        if decoded.config.bcs.isEmpty {
            throw AutoSageError(code: "invalid_input", message: "config.bcs must include at least one fixed boundary condition.")
        }
        for boundary in decoded.config.bcs {
            guard boundary.attribute > 0 else {
                throw AutoSageError(code: "invalid_input", message: "config.bcs[].attribute must be > 0.")
            }
            let type = boundary.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard type == "fixed" else {
                throw AutoSageError(code: "invalid_input", message: "config.bcs[].type must be fixed.")
            }
            guard boundary.value.isFinite else {
                throw AutoSageError(code: "invalid_input", message: "config.bcs[].value must be finite.")
            }
        }

        return decoded
    }

    private static func toDriverPayload(_ input: DPGLaplaceInput) throws -> [String: JSONValue] {
        guard case .object(let meshObject) = input.mesh else {
            throw AutoSageError(code: "invalid_input", message: "mesh must be an object.")
        }
        let encodedConfig = try JSONCoding.makeDecoder().decode(
            JSONValue.self,
            from: JSONCoding.makeEncoder().encode(input.config)
        )
        guard case .object(let configObject) = encodedConfig else {
            throw AutoSageError(code: "internal_error", message: "Failed to encode DPG Laplace config.")
        }
        return [
            "solver_class": .string("DPGLaplace"),
            "mesh": .object(meshObject),
            "config": .object(configObject)
        ]
    }
}
