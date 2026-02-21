// SPDX-License-Identifier: MIT
// AutoSage hyperelasticity tool wrapper for MFEM driver.

import Foundation

private struct HyperelasticBoundaryCondition: Codable, Equatable, Sendable {
    let attribute: Int
    let type: String
    let value: [Double]?
}

private struct HyperelasticConfig: Codable, Equatable, Sendable {
    let shearModulus: Double
    let bulkModulus: Double
    let bodyForce: [Double]?
    let bcs: [HyperelasticBoundaryCondition]

    enum CodingKeys: String, CodingKey {
        case shearModulus = "shear_modulus"
        case bulkModulus = "bulk_modulus"
        case bodyForce = "body_force"
        case bcs
    }
}

private struct HyperelasticInput: Codable, Equatable, Sendable {
    let solverClass: String?
    let mesh: JSONValue
    let config: HyperelasticConfig

    enum CodingKeys: String, CodingKey {
        case solverClass = "solver_class"
        case mesh
        case config
    }
}

public struct HyperelasticityTool: Tool {
    public let name: String = "hyperelastic.solve"
    public let version: String
    public let description: String
    public let jsonSchema: JSONValue = HyperelasticityTool.schema

    private let feaBridge: FEATool

    public init(
        version: String = "0.1.0",
        description: String = "Solves large-deformation hyperelastic solids with a Neo-Hookean material model.",
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
                "enum": .stringArray(["Hyperelastic"])
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
                    "shear_modulus": .object(["type": .string("number")]),
                    "bulk_modulus": .object(["type": .string("number")]),
                    "body_force": .object([
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
                                    "enum": .stringArray(["fixed", "traction"])
                                ]),
                                "value": .object([
                                    "type": .string("array"),
                                    "items": .object(["type": .string("number")])
                                ])
                            ]),
                            "required": .stringArray(["attribute", "type"])
                        ])
                    ])
                ]),
                "required": .stringArray(["shear_modulus", "bulk_modulus", "bcs"])
            ])
        ]),
        "required": .stringArray(["mesh", "config"]),
        "additionalProperties": .bool(true)
    ])

    private static func decodeInput(_ input: JSONValue?) throws -> HyperelasticInput {
        guard let input else {
            throw AutoSageError(code: "invalid_input", message: "hyperelastic.solve requires an input object.")
        }
        guard case .object = input else {
            throw AutoSageError(code: "invalid_input", message: "hyperelastic.solve input must be an object.")
        }

        let data = try JSONCoding.makeEncoder().encode(input)
        let decoded = try JSONCoding.makeDecoder().decode(HyperelasticInput.self, from: data)

        if let solverClass = decoded.solverClass {
            let normalized = solverClass.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let valid = [
                "hyperelastic",
                "hyper_elastic",
                "hyper-elastic",
                "hyperelasticity",
                "hyper_elasticity",
                "hyper-elasticity"
            ]
            guard valid.contains(normalized) else {
                throw AutoSageError(code: "invalid_input", message: "solver_class must be Hyperelastic.")
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

        if decoded.config.shearModulus <= 0 {
            throw AutoSageError(code: "invalid_input", message: "config.shear_modulus must be > 0.")
        }
        if decoded.config.bulkModulus <= 0 {
            throw AutoSageError(code: "invalid_input", message: "config.bulk_modulus must be > 0.")
        }
        if decoded.config.bcs.isEmpty {
            throw AutoSageError(code: "invalid_input", message: "config.bcs must not be empty.")
        }

        var hasFixed = false
        for boundary in decoded.config.bcs {
            guard boundary.attribute > 0 else {
                throw AutoSageError(code: "invalid_input", message: "config.bcs[].attribute must be > 0.")
            }
            let type = boundary.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard type == "fixed" || type == "traction" else {
                throw AutoSageError(code: "invalid_input", message: "config.bcs[].type must be fixed or traction.")
            }
            if type == "fixed" {
                hasFixed = true
            }
            if type == "traction" {
                guard let value = boundary.value, !value.isEmpty else {
                    throw AutoSageError(
                        code: "invalid_input",
                        message: "config.bcs[].value is required when type=traction."
                    )
                }
            }
        }
        guard hasFixed else {
            throw AutoSageError(
                code: "invalid_input",
                message: "config.bcs must include at least one fixed boundary condition."
            )
        }

        if let bodyForce = decoded.config.bodyForce {
            if bodyForce.isEmpty {
                throw AutoSageError(code: "invalid_input", message: "config.body_force must not be empty when provided.")
            }
        }

        return decoded
    }

    private static func toDriverPayload(_ input: HyperelasticInput) throws -> [String: JSONValue] {
        guard case .object(let meshObject) = input.mesh else {
            throw AutoSageError(code: "invalid_input", message: "mesh must be an object.")
        }
        let encodedConfig = try JSONCoding.makeDecoder().decode(
            JSONValue.self,
            from: JSONCoding.makeEncoder().encode(input.config)
        )
        guard case .object(let configObject) = encodedConfig else {
            throw AutoSageError(code: "internal_error", message: "Failed to encode hyperelastic config.")
        }
        return [
            "solver_class": .string("Hyperelastic"),
            "mesh": .object(meshObject),
            "config": .object(configObject)
        ]
    }
}
