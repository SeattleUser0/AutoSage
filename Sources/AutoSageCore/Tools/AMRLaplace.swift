// SPDX-License-Identifier: MIT
// AutoSage AMR Laplace tool wrapper for MFEM driver.

import Foundation

private struct AMRLaplaceBoundaryCondition: Codable, Equatable, Sendable {
    let attribute: Int
    let type: String
    let value: Double
}

private struct AMRLaplaceSettings: Codable, Equatable, Sendable {
    let maxIterations: Int
    let maxDOFs: Int
    let errorTolerance: Double

    enum CodingKeys: String, CodingKey {
        case maxIterations = "max_iterations"
        case maxDOFs = "max_dofs"
        case errorTolerance = "error_tolerance"
    }
}

private struct AMRLaplaceConfig: Codable, Equatable, Sendable {
    let coefficient: Double
    let sourceTerm: Double?
    let amrSettings: AMRLaplaceSettings
    let bcs: [AMRLaplaceBoundaryCondition]

    enum CodingKeys: String, CodingKey {
        case coefficient
        case sourceTerm = "source_term"
        case amrSettings = "amr_settings"
        case bcs
    }
}

private struct AMRLaplaceInput: Codable, Equatable, Sendable {
    let solverClass: String?
    let mesh: JSONValue
    let config: AMRLaplaceConfig

    enum CodingKeys: String, CodingKey {
        case solverClass = "solver_class"
        case mesh
        case config
    }
}

public struct AMRLaplaceTool: Tool {
    public let name: String = "amr_laplace.solve"
    public let version: String
    public let description: String
    public let jsonSchema: JSONValue = AMRLaplaceTool.schema

    private let feaBridge: FEATool

    public init(
        version: String = "0.1.0",
        description: String = "Solves a Laplace/Poisson problem with adaptive mesh refinement using MFEM.",
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
                "enum": .stringArray(["AMRLaplace"])
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
                    "amr_settings": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "max_iterations": .object(["type": .string("integer")]),
                            "max_dofs": .object(["type": .string("integer")]),
                            "error_tolerance": .object(["type": .string("number")])
                        ]),
                        "required": .stringArray(["max_iterations", "max_dofs", "error_tolerance"])
                    ]),
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
                "required": .stringArray(["coefficient", "amr_settings", "bcs"])
            ])
        ]),
        "required": .stringArray(["mesh", "config"]),
        "additionalProperties": .bool(true)
    ])

    private static func decodeInput(_ input: JSONValue?) throws -> AMRLaplaceInput {
        guard let input else {
            throw AutoSageError(code: "invalid_input", message: "amr_laplace.solve requires an input object.")
        }
        guard case .object = input else {
            throw AutoSageError(code: "invalid_input", message: "amr_laplace.solve input must be an object.")
        }
        let data = try JSONCoding.makeEncoder().encode(input)
        let decoded = try JSONCoding.makeDecoder().decode(AMRLaplaceInput.self, from: data)

        if let solverClass = decoded.solverClass {
            let normalized = solverClass.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized == "amrlaplace" || normalized == "amr_laplace" || normalized == "amr-laplace" else {
                throw AutoSageError(code: "invalid_input", message: "solver_class must be AMRLaplace.")
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

        guard decoded.config.coefficient > 0 else {
            throw AutoSageError(code: "invalid_input", message: "config.coefficient must be > 0.")
        }
        guard decoded.config.amrSettings.maxIterations > 0 else {
            throw AutoSageError(code: "invalid_input", message: "config.amr_settings.max_iterations must be > 0.")
        }
        guard decoded.config.amrSettings.maxDOFs > 0 else {
            throw AutoSageError(code: "invalid_input", message: "config.amr_settings.max_dofs must be > 0.")
        }
        guard decoded.config.amrSettings.errorTolerance > 0 else {
            throw AutoSageError(code: "invalid_input", message: "config.amr_settings.error_tolerance must be > 0.")
        }

        var hasFixedBoundary = false
        for boundary in decoded.config.bcs {
            guard boundary.attribute > 0 else {
                throw AutoSageError(code: "invalid_input", message: "config.bcs[].attribute must be > 0.")
            }
            let type = boundary.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard type == "fixed" else {
                throw AutoSageError(code: "invalid_input", message: "config.bcs[].type must be fixed.")
            }
            hasFixedBoundary = true
        }
        guard hasFixedBoundary else {
            throw AutoSageError(code: "invalid_input", message: "config.bcs must include at least one fixed boundary condition.")
        }

        return decoded
    }

    private static func toDriverPayload(_ input: AMRLaplaceInput) throws -> [String: JSONValue] {
        guard case .object(let meshObject) = input.mesh else {
            throw AutoSageError(code: "invalid_input", message: "mesh must be an object.")
        }
        let encodedConfig = try JSONCoding.makeDecoder().decode(
            JSONValue.self,
            from: JSONCoding.makeEncoder().encode(input.config)
        )
        guard case .object(let configObject) = encodedConfig else {
            throw AutoSageError(code: "internal_error", message: "Failed to encode AMR Laplace config.")
        }
        return [
            "solver_class": .string("AMRLaplace"),
            "mesh": .object(meshObject),
            "config": .object(configObject)
        ]
    }
}
