// SPDX-License-Identifier: MIT
// AutoSage CFD tool wrapper for MFEM driver.

import Foundation

private struct CFDBoundaryCondition: Codable, Equatable, Sendable {
    let attr: Int
    let type: String
    let velocity: [Double]?
    let pressure: Double?
}

private struct CFDConfig: Codable, Equatable, Sendable {
    let viscosity: Double
    let density: Double
    let dt: Double
    let tFinal: Double
    let bcs: [CFDBoundaryCondition]

    enum CodingKeys: String, CodingKey {
        case viscosity
        case density
        case dt
        case tFinal = "t_final"
        case bcs
    }
}

private struct CFDInput: Codable, Equatable, Sendable {
    let solverClass: String?
    let mesh: JSONValue
    let config: CFDConfig

    enum CodingKeys: String, CodingKey {
        case solverClass = "solver_class"
        case mesh
        case config
    }
}

public struct CFDTool: Tool {
    public let name: String = "cfd.solve"
    public let version: String
    public let description: String
    public let jsonSchema: JSONValue = CFDTool.schema

    private let feaBridge: FEATool

    public init(
        version: String = "0.4.0",
        description: String = "Simulates fluid flow using the Incompressible Navier-Stokes equations. Useful for aerodynamics, hydraulics, and cooling analysis.",
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
                "enum": .stringArray(["NavierStokes"])
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
                    "viscosity": .object(["type": .string("number")]),
                    "density": .object(["type": .string("number")]),
                    "dt": .object(["type": .string("number")]),
                    "t_final": .object(["type": .string("number")]),
                    "bcs": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "attr": .object(["type": .string("integer")]),
                                "type": .object([
                                    "type": .string("string"),
                                    "enum": .stringArray(["inlet", "outlet", "wall"])
                                ]),
                                "velocity": .object([
                                    "type": .string("array"),
                                    "items": .object(["type": .string("number")])
                                ]),
                                "pressure": .object(["type": .string("number")])
                            ]),
                            "required": .stringArray(["attr", "type"])
                        ])
                    ])
                ]),
                "required": .stringArray(["viscosity", "density", "dt", "t_final", "bcs"])
            ])
        ]),
        "required": .stringArray(["mesh", "config"]),
        "additionalProperties": .bool(true)
    ])

    private static func decodeInput(_ input: JSONValue?) throws -> CFDInput {
        guard let input else {
            throw AutoSageError(code: "invalid_input", message: "cfd.solve requires an input object.")
        }
        guard case .object = input else {
            throw AutoSageError(code: "invalid_input", message: "cfd.solve input must be an object.")
        }
        let data = try JSONCoding.makeEncoder().encode(input)
        let decoded = try JSONCoding.makeDecoder().decode(CFDInput.self, from: data)

        if let solverClass = decoded.solverClass {
            let normalized = solverClass.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized == "navierstokes" || normalized == "navier_stokes" || normalized == "navier-stokes" else {
                throw AutoSageError(
                    code: "invalid_input",
                    message: "solver_class must be NavierStokes."
                )
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

        if decoded.config.viscosity <= 0 {
            throw AutoSageError(code: "invalid_input", message: "config.viscosity must be > 0.")
        }
        if decoded.config.density <= 0 {
            throw AutoSageError(code: "invalid_input", message: "config.density must be > 0.")
        }
        if decoded.config.dt <= 0 {
            throw AutoSageError(code: "invalid_input", message: "config.dt must be > 0.")
        }
        if decoded.config.tFinal <= 0 {
            throw AutoSageError(code: "invalid_input", message: "config.t_final must be > 0.")
        }

        for boundary in decoded.config.bcs {
            guard boundary.attr > 0 else {
                throw AutoSageError(code: "invalid_input", message: "config.bcs[].attr must be > 0.")
            }
            let type = boundary.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard type == "inlet" || type == "outlet" || type == "wall" else {
                throw AutoSageError(code: "invalid_input", message: "config.bcs[].type must be inlet, outlet, or wall.")
            }
            if type == "inlet" {
                guard let velocity = boundary.velocity, !velocity.isEmpty else {
                    throw AutoSageError(
                        code: "invalid_input",
                        message: "config.bcs[].velocity is required when type=inlet."
                    )
                }
            }
            if type == "outlet", boundary.pressure == nil {
                // Pressure defaults to zero in the solver; allow omission.
            }
        }

        return decoded
    }

    private static func toDriverPayload(_ input: CFDInput) throws -> [String: JSONValue] {
        guard case .object(let meshObject) = input.mesh else {
            throw AutoSageError(code: "invalid_input", message: "mesh must be an object.")
        }
        let encodedConfig = try JSONCoding.makeDecoder().decode(
            JSONValue.self,
            from: JSONCoding.makeEncoder().encode(input.config)
        )
        guard case .object(let configObject) = encodedConfig else {
            throw AutoSageError(code: "internal_error", message: "Failed to encode CFD config.")
        }
        return [
            "solver_class": .string("NavierStokes"),
            "mesh": .object(meshObject),
            "config": .object(configObject)
        ]
    }
}
