// SPDX-License-Identifier: MIT
// AutoSage compressible flow tool wrapper for MFEM driver.

import Foundation

private struct CompressibleBoundaryCondition: Codable, Equatable, Sendable {
    let attribute: Int
    let type: String
}

private struct CompressibleInitialCondition: Codable, Equatable, Sendable {
    let type: String
    let leftState: [Double]
    let rightState: [Double]

    enum CodingKeys: String, CodingKey {
        case type
        case leftState = "left_state"
        case rightState = "right_state"
    }
}

private struct CompressibleConfig: Codable, Equatable, Sendable {
    let specificHeatRatio: Double
    let dt: Double
    let tFinal: Double
    let order: Int?
    let outputIntervalSteps: Int?
    let initialCondition: CompressibleInitialCondition
    let bcs: [CompressibleBoundaryCondition]

    enum CodingKeys: String, CodingKey {
        case specificHeatRatio = "specific_heat_ratio"
        case dt
        case tFinal = "t_final"
        case order
        case outputIntervalSteps = "output_interval_steps"
        case initialCondition = "initial_condition"
        case bcs
    }
}

private struct CompressibleInput: Codable, Equatable, Sendable {
    let solverClass: String?
    let mesh: JSONValue
    let config: CompressibleConfig

    enum CodingKeys: String, CodingKey {
        case solverClass = "solver_class"
        case mesh
        case config
    }
}

public struct CompressibleFlowTool: Tool {
    public let name: String = "compressible.solve"
    public let version: String
    public let description: String
    public let jsonSchema: JSONValue = CompressibleFlowTool.schema

    private let feaBridge: FEATool

    public init(
        version: String = "0.1.0",
        description: String = "Simulates compressible Euler flow with a discontinuous Galerkin discretization and Rusanov numerical flux.",
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
                "enum": .stringArray(["CompressibleEuler"])
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
                    "specific_heat_ratio": .object(["type": .string("number")]),
                    "dt": .object(["type": .string("number")]),
                    "t_final": .object(["type": .string("number")]),
                    "order": .object(["type": .string("integer")]),
                    "output_interval_steps": .object(["type": .string("integer")]),
                    "initial_condition": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "type": .object([
                                "type": .string("string"),
                                "enum": .stringArray(["shock_tube"])
                            ]),
                            "left_state": .object([
                                "type": .string("array"),
                                "items": .object(["type": .string("number")])
                            ]),
                            "right_state": .object([
                                "type": .string("array"),
                                "items": .object(["type": .string("number")])
                            ])
                        ]),
                        "required": .stringArray(["type", "left_state", "right_state"])
                    ]),
                    "bcs": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "attribute": .object(["type": .string("integer")]),
                                "type": .object([
                                    "type": .string("string"),
                                    "enum": .stringArray(["slip_wall"])
                                ])
                            ]),
                            "required": .stringArray(["attribute", "type"])
                        ])
                    ])
                ]),
                "required": .stringArray(["specific_heat_ratio", "dt", "t_final", "initial_condition", "bcs"])
            ])
        ]),
        "required": .stringArray(["mesh", "config"]),
        "additionalProperties": .bool(true)
    ])

    private static func decodeInput(_ input: JSONValue?) throws -> CompressibleInput {
        guard let input else {
            throw AutoSageError(code: "invalid_input", message: "compressible.solve requires an input object.")
        }
        guard case .object = input else {
            throw AutoSageError(code: "invalid_input", message: "compressible.solve input must be an object.")
        }

        let data = try JSONCoding.makeEncoder().encode(input)
        let decoded = try JSONCoding.makeDecoder().decode(CompressibleInput.self, from: data)

        if let solverClass = decoded.solverClass {
            let normalized = solverClass.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let valid = [
                "compressibleeuler",
                "compressible_euler",
                "compressible-euler"
            ]
            guard valid.contains(normalized) else {
                throw AutoSageError(code: "invalid_input", message: "solver_class must be CompressibleEuler.")
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

        if decoded.config.specificHeatRatio <= 1 {
            throw AutoSageError(code: "invalid_input", message: "config.specific_heat_ratio must be > 1.")
        }
        if decoded.config.dt <= 0 {
            throw AutoSageError(code: "invalid_input", message: "config.dt must be > 0.")
        }
        if decoded.config.tFinal <= 0 {
            throw AutoSageError(code: "invalid_input", message: "config.t_final must be > 0.")
        }
        if let order = decoded.config.order, order < 0 {
            throw AutoSageError(code: "invalid_input", message: "config.order must be >= 0.")
        }
        if let outputSteps = decoded.config.outputIntervalSteps, outputSteps <= 0 {
            throw AutoSageError(code: "invalid_input", message: "config.output_interval_steps must be > 0.")
        }

        let initialType = decoded.config.initialCondition.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard initialType == "shock_tube" || initialType == "shock-tube" || initialType == "shocktube" else {
            throw AutoSageError(code: "invalid_input", message: "config.initial_condition.type must be shock_tube.")
        }

        guard decoded.config.initialCondition.leftState.count >= 3 else {
            throw AutoSageError(
                code: "invalid_input",
                message: "config.initial_condition.left_state must contain [density, velocity_x, pressure]."
            )
        }
        guard decoded.config.initialCondition.rightState.count >= 3 else {
            throw AutoSageError(
                code: "invalid_input",
                message: "config.initial_condition.right_state must contain [density, velocity_x, pressure]."
            )
        }
        if decoded.config.initialCondition.leftState[0] <= 0 || decoded.config.initialCondition.leftState[2] <= 0 {
            throw AutoSageError(code: "invalid_input", message: "config.initial_condition.left_state density and pressure must be > 0.")
        }
        if decoded.config.initialCondition.rightState[0] <= 0 || decoded.config.initialCondition.rightState[2] <= 0 {
            throw AutoSageError(code: "invalid_input", message: "config.initial_condition.right_state density and pressure must be > 0.")
        }

        for boundary in decoded.config.bcs {
            guard boundary.attribute > 0 else {
                throw AutoSageError(code: "invalid_input", message: "config.bcs[].attribute must be > 0.")
            }
            let type = boundary.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard type == "slip_wall" || type == "slip-wall" || type == "slipwall" else {
                throw AutoSageError(code: "invalid_input", message: "config.bcs[].type must be slip_wall.")
            }
        }

        return decoded
    }

    private static func toDriverPayload(_ input: CompressibleInput) throws -> [String: JSONValue] {
        guard case .object(let meshObject) = input.mesh else {
            throw AutoSageError(code: "invalid_input", message: "mesh must be an object.")
        }
        let encodedConfig = try JSONCoding.makeDecoder().decode(
            JSONValue.self,
            from: JSONCoding.makeEncoder().encode(input.config)
        )
        guard case .object(let configObject) = encodedConfig else {
            throw AutoSageError(code: "internal_error", message: "Failed to encode compressible flow config.")
        }
        return [
            "solver_class": .string("CompressibleEuler"),
            "mesh": .object(meshObject),
            "config": .object(configObject)
        ]
    }
}
