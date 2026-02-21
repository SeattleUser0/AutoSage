// SPDX-License-Identifier: MIT
// AutoSage Joule heating tool wrapper for MFEM driver.

import Foundation

private struct JouleHeatingBoundaryCondition: Codable, Equatable, Sendable {
    let attribute: Int
    let type: String
    let value: Double
}

private struct JouleHeatingConfig: Codable, Equatable, Sendable {
    let electricalConductivity: Double
    let thermalConductivity: Double
    let heatCapacity: Double
    let dt: Double
    let tFinal: Double
    let bcs: [JouleHeatingBoundaryCondition]

    enum CodingKeys: String, CodingKey {
        case electricalConductivity = "electrical_conductivity"
        case thermalConductivity = "thermal_conductivity"
        case heatCapacity = "heat_capacity"
        case dt
        case tFinal = "t_final"
        case bcs
    }
}

private struct JouleHeatingInput: Codable, Equatable, Sendable {
    let solverClass: String?
    let mesh: JSONValue
    let config: JouleHeatingConfig

    enum CodingKeys: String, CodingKey {
        case solverClass = "solver_class"
        case mesh
        case config
    }
}

public struct JouleHeatingTool: Tool {
    public let name: String = "joule_heating.solve"
    public let version: String
    public let description: String
    public let jsonSchema: JSONValue = JouleHeatingTool.schema

    private let feaBridge: FEATool

    public init(
        version: String = "0.1.0",
        description: String = "Solves coupled quasi-static electrical conduction and transient heat diffusion with Joule source coupling.",
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
                "enum": .stringArray(["JouleHeating"])
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
                    "electrical_conductivity": .object(["type": .string("number")]),
                    "thermal_conductivity": .object(["type": .string("number")]),
                    "heat_capacity": .object(["type": .string("number")]),
                    "dt": .object(["type": .string("number")]),
                    "t_final": .object(["type": .string("number")]),
                    "bcs": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "attribute": .object(["type": .string("integer")]),
                                "type": .object([
                                    "type": .string("string"),
                                    "enum": .stringArray(["voltage", "ground", "fixed_temp"])
                                ]),
                                "value": .object(["type": .string("number")])
                            ]),
                            "required": .stringArray(["attribute", "type", "value"])
                        ])
                    ])
                ]),
                "required": .stringArray([
                    "electrical_conductivity",
                    "thermal_conductivity",
                    "heat_capacity",
                    "dt",
                    "t_final",
                    "bcs"
                ])
            ])
        ]),
        "required": .stringArray(["mesh", "config"]),
        "additionalProperties": .bool(true)
    ])

    private static func decodeInput(_ input: JSONValue?) throws -> JouleHeatingInput {
        guard let input else {
            throw AutoSageError(code: "invalid_input", message: "joule_heating.solve requires an input object.")
        }
        guard case .object = input else {
            throw AutoSageError(code: "invalid_input", message: "joule_heating.solve input must be an object.")
        }
        let data = try JSONCoding.makeEncoder().encode(input)
        let decoded = try JSONCoding.makeDecoder().decode(JouleHeatingInput.self, from: data)

        if let solverClass = decoded.solverClass {
            let normalized = solverClass.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized == "jouleheating" ||
                    normalized == "joule_heating" ||
                    normalized == "joule-heating" else {
                throw AutoSageError(code: "invalid_input", message: "solver_class must be JouleHeating.")
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

        guard decoded.config.electricalConductivity > 0 else {
            throw AutoSageError(code: "invalid_input", message: "config.electrical_conductivity must be > 0.")
        }
        guard decoded.config.thermalConductivity > 0 else {
            throw AutoSageError(code: "invalid_input", message: "config.thermal_conductivity must be > 0.")
        }
        guard decoded.config.heatCapacity > 0 else {
            throw AutoSageError(code: "invalid_input", message: "config.heat_capacity must be > 0.")
        }
        guard decoded.config.dt > 0 else {
            throw AutoSageError(code: "invalid_input", message: "config.dt must be > 0.")
        }
        guard decoded.config.tFinal > 0 else {
            throw AutoSageError(code: "invalid_input", message: "config.t_final must be > 0.")
        }

        var hasElectricDirichlet = false
        var hasThermalDirichlet = false
        for boundary in decoded.config.bcs {
            guard boundary.attribute > 0 else {
                throw AutoSageError(code: "invalid_input", message: "config.bcs[].attribute must be > 0.")
            }
            let type = boundary.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard type == "voltage" || type == "ground" || type == "fixed_temp" else {
                throw AutoSageError(
                    code: "invalid_input",
                    message: "config.bcs[].type must be voltage, ground, or fixed_temp."
                )
            }
            if type == "voltage" || type == "ground" {
                hasElectricDirichlet = true
            }
            if type == "fixed_temp" {
                hasThermalDirichlet = true
            }
        }

        guard hasElectricDirichlet else {
            throw AutoSageError(
                code: "invalid_input",
                message: "config.bcs must include at least one voltage or ground boundary condition."
            )
        }
        guard hasThermalDirichlet else {
            throw AutoSageError(
                code: "invalid_input",
                message: "config.bcs must include at least one fixed_temp boundary condition."
            )
        }

        return decoded
    }

    private static func toDriverPayload(_ input: JouleHeatingInput) throws -> [String: JSONValue] {
        guard case .object(let meshObject) = input.mesh else {
            throw AutoSageError(code: "invalid_input", message: "mesh must be an object.")
        }
        let encodedConfig = try JSONCoding.makeDecoder().decode(
            JSONValue.self,
            from: JSONCoding.makeEncoder().encode(input.config)
        )
        guard case .object(let configObject) = encodedConfig else {
            throw AutoSageError(code: "internal_error", message: "Failed to encode Joule heating config.")
        }
        return [
            "solver_class": .string("JouleHeating"),
            "mesh": .object(meshObject),
            "config": .object(configObject)
        ]
    }
}
