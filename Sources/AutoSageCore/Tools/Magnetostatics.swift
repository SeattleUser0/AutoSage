// SPDX-License-Identifier: MIT
// AutoSage magnetostatics tool wrapper for MFEM driver.

import Foundation

private struct MagnetostaticsBoundaryCondition: Codable, Equatable, Sendable {
    let attribute: Int
    let type: String
}

private struct MagnetostaticsConfig: Codable, Equatable, Sendable {
    let permeability: Double
    let currentDensity: [Double]?
    let bcs: [MagnetostaticsBoundaryCondition]

    enum CodingKeys: String, CodingKey {
        case permeability
        case currentDensity = "current_density"
        case bcs
    }
}

private struct MagnetostaticsInput: Codable, Equatable, Sendable {
    let solverClass: String?
    let mesh: JSONValue
    let config: MagnetostaticsConfig

    enum CodingKeys: String, CodingKey {
        case solverClass = "solver_class"
        case mesh
        case config
    }
}

public struct MagnetostaticsTool: Tool {
    public let name: String = "magnetostatics.solve"
    public let version: String
    public let description: String
    public let jsonSchema: JSONValue = MagnetostaticsTool.schema

    private let feaBridge: FEATool

    public init(
        version: String = "0.1.0",
        description: String = "Solves static magnetic vector potential with curl-curl formulation and AMS-preconditioned linear solves.",
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
                "enum": .stringArray(["Magnetostatics"])
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
                    "permeability": .object(["type": .string("number")]),
                    "current_density": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("number")])
                    ]),
                    "bcs": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "attribute": .object(["type": .string("integer")]),
                                "type": .object([
                                    "type": .string("string"),
                                    "enum": .stringArray(["magnetic_insulation"])
                                ])
                            ]),
                            "required": .stringArray(["attribute", "type"])
                        ])
                    ])
                ]),
                "required": .stringArray(["permeability", "bcs"])
            ])
        ]),
        "required": .stringArray(["mesh", "config"]),
        "additionalProperties": .bool(true)
    ])

    private static func decodeInput(_ input: JSONValue?) throws -> MagnetostaticsInput {
        guard let input else {
            throw AutoSageError(code: "invalid_input", message: "magnetostatics.solve requires an input object.")
        }
        guard case .object = input else {
            throw AutoSageError(code: "invalid_input", message: "magnetostatics.solve input must be an object.")
        }

        let data = try JSONCoding.makeEncoder().encode(input)
        let decoded = try JSONCoding.makeDecoder().decode(MagnetostaticsInput.self, from: data)

        if let solverClass = decoded.solverClass {
            let normalized = solverClass.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let valid = ["magnetostatics", "magneto_statics", "magneto-statics"]
            guard valid.contains(normalized) else {
                throw AutoSageError(code: "invalid_input", message: "solver_class must be Magnetostatics.")
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

        if decoded.config.permeability <= 0 {
            throw AutoSageError(code: "invalid_input", message: "config.permeability must be > 0.")
        }
        if let currentDensity = decoded.config.currentDensity, currentDensity.isEmpty {
            throw AutoSageError(code: "invalid_input", message: "config.current_density must not be empty when provided.")
        }

        var hasMagneticInsulation = false
        for boundary in decoded.config.bcs {
            guard boundary.attribute > 0 else {
                throw AutoSageError(code: "invalid_input", message: "config.bcs[].attribute must be > 0.")
            }
            let type = boundary.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard type == "magnetic_insulation" || type == "magnetic-insulation" || type == "magneticinsulation" else {
                throw AutoSageError(code: "invalid_input", message: "config.bcs[].type must be magnetic_insulation.")
            }
            hasMagneticInsulation = true
        }
        guard hasMagneticInsulation else {
            throw AutoSageError(
                code: "invalid_input",
                message: "config.bcs must include at least one magnetic_insulation boundary condition."
            )
        }

        return decoded
    }

    private static func toDriverPayload(_ input: MagnetostaticsInput) throws -> [String: JSONValue] {
        guard case .object(let meshObject) = input.mesh else {
            throw AutoSageError(code: "invalid_input", message: "mesh must be an object.")
        }
        let encodedConfig = try JSONCoding.makeDecoder().decode(
            JSONValue.self,
            from: JSONCoding.makeEncoder().encode(input.config)
        )
        guard case .object(let configObject) = encodedConfig else {
            throw AutoSageError(code: "internal_error", message: "Failed to encode magnetostatics config.")
        }
        return [
            "solver_class": .string("Magnetostatics"),
            "mesh": .object(meshObject),
            "config": .object(configObject)
        ]
    }
}
