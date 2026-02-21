// SPDX-License-Identifier: MIT
// AutoSage Stokes flow tool wrapper for MFEM driver.

import Foundation

private struct StokesBoundaryCondition: Codable, Equatable, Sendable {
    let attribute: Int
    let type: String
    let velocity: [Double]?
}

private struct StokesConfig: Codable, Equatable, Sendable {
    let dynamicViscosity: Double
    let bodyForce: [Double]?
    let bcs: [StokesBoundaryCondition]

    enum CodingKeys: String, CodingKey {
        case dynamicViscosity = "dynamic_viscosity"
        case bodyForce = "body_force"
        case bcs
    }
}

private struct StokesInput: Codable, Equatable, Sendable {
    let solverClass: String?
    let mesh: JSONValue
    let config: StokesConfig

    enum CodingKeys: String, CodingKey {
        case solverClass = "solver_class"
        case mesh
        case config
    }
}

public struct StokesTool: Tool {
    public let name: String = "stokes.solve"
    public let version: String
    public let description: String
    public let jsonSchema: JSONValue = StokesTool.schema

    private let feaBridge: FEATool

    public init(
        version: String = "0.1.0",
        description: String = "Solves incompressible Stokes flow with a mixed finite element formulation (velocity-pressure).",
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
                "enum": .stringArray(["StokesFlow"])
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
                    "dynamic_viscosity": .object(["type": .string("number")]),
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
                                    "enum": .stringArray(["no_slip", "inflow"])
                                ]),
                                "velocity": .object([
                                    "type": .string("array"),
                                    "items": .object(["type": .string("number")])
                                ])
                            ]),
                            "required": .stringArray(["attribute", "type"])
                        ])
                    ])
                ]),
                "required": .stringArray(["dynamic_viscosity", "bcs"])
            ])
        ]),
        "required": .stringArray(["mesh", "config"]),
        "additionalProperties": .bool(true)
    ])

    private static func decodeInput(_ input: JSONValue?) throws -> StokesInput {
        guard let input else {
            throw AutoSageError(code: "invalid_input", message: "stokes.solve requires an input object.")
        }
        guard case .object = input else {
            throw AutoSageError(code: "invalid_input", message: "stokes.solve input must be an object.")
        }

        let data = try JSONCoding.makeEncoder().encode(input)
        let decoded = try JSONCoding.makeDecoder().decode(StokesInput.self, from: data)

        if let solverClass = decoded.solverClass {
            let normalized = solverClass.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized == "stokes" || normalized == "stokesflow" || normalized == "stokes_flow" || normalized == "stokes-flow" else {
                throw AutoSageError(code: "invalid_input", message: "solver_class must be StokesFlow.")
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

        if decoded.config.dynamicViscosity <= 0 {
            throw AutoSageError(code: "invalid_input", message: "config.dynamic_viscosity must be > 0.")
        }
        if let bodyForce = decoded.config.bodyForce, bodyForce.isEmpty {
            throw AutoSageError(code: "invalid_input", message: "config.body_force must not be empty when provided.")
        }
        if decoded.config.bcs.isEmpty {
            throw AutoSageError(code: "invalid_input", message: "config.bcs must include at least one boundary condition.")
        }

        for boundary in decoded.config.bcs {
            guard boundary.attribute > 0 else {
                throw AutoSageError(code: "invalid_input", message: "config.bcs[].attribute must be > 0.")
            }
            let type = boundary.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard type == "no_slip" || type == "no-slip" || type == "noslip" || type == "inflow" else {
                throw AutoSageError(code: "invalid_input", message: "config.bcs[].type must be no_slip or inflow.")
            }
            if type == "inflow" {
                guard let velocity = boundary.velocity, !velocity.isEmpty else {
                    throw AutoSageError(
                        code: "invalid_input",
                        message: "config.bcs[].velocity is required when type=inflow."
                    )
                }
            }
        }

        return decoded
    }

    private static func toDriverPayload(_ input: StokesInput) throws -> [String: JSONValue] {
        guard case .object(let meshObject) = input.mesh else {
            throw AutoSageError(code: "invalid_input", message: "mesh must be an object.")
        }
        let encodedConfig = try JSONCoding.makeDecoder().decode(
            JSONValue.self,
            from: JSONCoding.makeEncoder().encode(input.config)
        )
        guard case .object(let configObject) = encodedConfig else {
            throw AutoSageError(code: "internal_error", message: "Failed to encode Stokes config.")
        }
        return [
            "solver_class": .string("StokesFlow"),
            "mesh": .object(meshObject),
            "config": .object(configObject)
        ]
    }
}
