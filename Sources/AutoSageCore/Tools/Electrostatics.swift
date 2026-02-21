// SPDX-License-Identifier: MIT
// AutoSage electrostatics tool wrapper for MFEM driver.

import Foundation

private struct ElectrostaticsBoundaryCondition: Codable, Equatable, Sendable {
    let attribute: Int
    let type: String
    let value: Double
}

private struct ElectrostaticsConfig: Codable, Equatable, Sendable {
    let permittivity: Double
    let chargeDensity: Double?
    let bcs: [ElectrostaticsBoundaryCondition]

    enum CodingKeys: String, CodingKey {
        case permittivity
        case chargeDensity = "charge_density"
        case bcs
    }
}

private struct ElectrostaticsInput: Codable, Equatable, Sendable {
    let solverClass: String?
    let mesh: JSONValue
    let config: ElectrostaticsConfig

    enum CodingKeys: String, CodingKey {
        case solverClass = "solver_class"
        case mesh
        case config
    }
}

public struct ElectrostaticsTool: Tool {
    public let name: String = "electrostatics.solve"
    public let version: String
    public let description: String
    public let jsonSchema: JSONValue = ElectrostaticsTool.schema

    private let feaBridge: FEATool

    public init(
        version: String = "0.1.0",
        description: String = "Solves static electric potential using the Poisson equation with MFEM.",
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
                "enum": .stringArray(["Electrostatics"])
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
                    "permittivity": .object(["type": .string("number")]),
                    "charge_density": .object(["type": .string("number")]),
                    "bcs": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "attribute": .object(["type": .string("integer")]),
                                "type": .object([
                                    "type": .string("string"),
                                    "enum": .stringArray(["fixed_voltage", "surface_charge"])
                                ]),
                                "value": .object(["type": .string("number")])
                            ]),
                            "required": .stringArray(["attribute", "type", "value"])
                        ])
                    ])
                ]),
                "required": .stringArray(["permittivity", "bcs"])
            ])
        ]),
        "required": .stringArray(["mesh", "config"]),
        "additionalProperties": .bool(true)
    ])

    private static func decodeInput(_ input: JSONValue?) throws -> ElectrostaticsInput {
        guard let input else {
            throw AutoSageError(code: "invalid_input", message: "electrostatics.solve requires an input object.")
        }
        guard case .object = input else {
            throw AutoSageError(code: "invalid_input", message: "electrostatics.solve input must be an object.")
        }

        let data = try JSONCoding.makeEncoder().encode(input)
        let decoded = try JSONCoding.makeDecoder().decode(ElectrostaticsInput.self, from: data)

        if let solverClass = decoded.solverClass {
            let normalized = solverClass.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized == "electrostatics" || normalized == "electro_statics" || normalized == "electro-statics" else {
                throw AutoSageError(code: "invalid_input", message: "solver_class must be Electrostatics.")
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

        if decoded.config.permittivity <= 0 {
            throw AutoSageError(code: "invalid_input", message: "config.permittivity must be > 0.")
        }

        var hasFixedVoltage = false
        for boundary in decoded.config.bcs {
            guard boundary.attribute > 0 else {
                throw AutoSageError(code: "invalid_input", message: "config.bcs[].attribute must be > 0.")
            }
            let type = boundary.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard type == "fixed_voltage" || type == "surface_charge" else {
                throw AutoSageError(
                    code: "invalid_input",
                    message: "config.bcs[].type must be fixed_voltage or surface_charge."
                )
            }
            if type == "fixed_voltage" {
                hasFixedVoltage = true
            }
        }
        guard hasFixedVoltage else {
            throw AutoSageError(
                code: "invalid_input",
                message: "config.bcs must include at least one fixed_voltage boundary condition."
            )
        }

        return decoded
    }

    private static func toDriverPayload(_ input: ElectrostaticsInput) throws -> [String: JSONValue] {
        guard case .object(let meshObject) = input.mesh else {
            throw AutoSageError(code: "invalid_input", message: "mesh must be an object.")
        }
        let encodedConfig = try JSONCoding.makeDecoder().decode(
            JSONValue.self,
            from: JSONCoding.makeEncoder().encode(input.config)
        )
        guard case .object(let configObject) = encodedConfig else {
            throw AutoSageError(code: "internal_error", message: "Failed to encode electrostatics config.")
        }
        return [
            "solver_class": .string("Electrostatics"),
            "mesh": .object(meshObject),
            "config": .object(configObject)
        ]
    }
}
