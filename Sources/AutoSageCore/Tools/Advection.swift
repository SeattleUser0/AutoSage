// SPDX-License-Identifier: MIT
// AutoSage linear advection tool wrapper for MFEM driver.

import Foundation

private struct AdvectionBoundaryCondition: Codable, Equatable, Sendable {
    let attribute: Int
    let type: String
    let value: Double
}

private struct AdvectionInitialCondition: Codable, Equatable, Sendable {
    let type: String
    let center: [Double]
    let radius: Double
    let value: Double
}

private struct AdvectionConfig: Codable, Equatable, Sendable {
    let velocityField: [Double]
    let dt: Double
    let tFinal: Double
    let order: Int?
    let outputIntervalSteps: Int?
    let initialCondition: AdvectionInitialCondition
    let bcs: [AdvectionBoundaryCondition]

    enum CodingKeys: String, CodingKey {
        case velocityField = "velocity_field"
        case dt
        case tFinal = "t_final"
        case order
        case outputIntervalSteps = "output_interval_steps"
        case initialCondition = "initial_condition"
        case bcs
    }
}

private struct AdvectionInput: Codable, Equatable, Sendable {
    let solverClass: String?
    let mesh: JSONValue
    let config: AdvectionConfig

    enum CodingKeys: String, CodingKey {
        case solverClass = "solver_class"
        case mesh
        case config
    }
}

public struct AdvectionTool: Tool {
    public let name: String = "advection.solve"
    public let version: String
    public let description: String
    public let jsonSchema: JSONValue = AdvectionTool.schema

    private let feaBridge: FEATool

    public init(
        version: String = "0.1.0",
        description: String = "Simulates scalar transport with a DG linear advection formulation and explicit time integration.",
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
                "enum": .stringArray(["Advection"])
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
                    "velocity_field": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("number")])
                    ]),
                    "dt": .object(["type": .string("number")]),
                    "t_final": .object(["type": .string("number")]),
                    "order": .object(["type": .string("integer")]),
                    "output_interval_steps": .object(["type": .string("integer")]),
                    "initial_condition": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "type": .object([
                                "type": .string("string"),
                                "enum": .stringArray(["step_function"])
                            ]),
                            "center": .object([
                                "type": .string("array"),
                                "items": .object(["type": .string("number")])
                            ]),
                            "radius": .object(["type": .string("number")]),
                            "value": .object(["type": .string("number")])
                        ]),
                        "required": .stringArray(["type", "center", "radius", "value"])
                    ]),
                    "bcs": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "attribute": .object(["type": .string("integer")]),
                                "type": .object([
                                    "type": .string("string"),
                                    "enum": .stringArray(["inflow"])
                                ]),
                                "value": .object(["type": .string("number")])
                            ]),
                            "required": .stringArray(["attribute", "type", "value"])
                        ])
                    ])
                ]),
                "required": .stringArray(["velocity_field", "dt", "t_final", "initial_condition", "bcs"])
            ])
        ]),
        "required": .stringArray(["mesh", "config"]),
        "additionalProperties": .bool(true)
    ])

    private static func decodeInput(_ input: JSONValue?) throws -> AdvectionInput {
        guard let input else {
            throw AutoSageError(code: "invalid_input", message: "advection.solve requires an input object.")
        }
        guard case .object = input else {
            throw AutoSageError(code: "invalid_input", message: "advection.solve input must be an object.")
        }

        let data = try JSONCoding.makeEncoder().encode(input)
        let decoded = try JSONCoding.makeDecoder().decode(AdvectionInput.self, from: data)

        if let solverClass = decoded.solverClass {
            let normalized = solverClass.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let valid = [
                "advection",
                "linearadvection",
                "linear_advection",
                "linear-advection"
            ]
            guard valid.contains(normalized) else {
                throw AutoSageError(code: "invalid_input", message: "solver_class must be Advection.")
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

        if decoded.config.velocityField.isEmpty {
            throw AutoSageError(code: "invalid_input", message: "config.velocity_field must not be empty.")
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
        if let outputIntervalSteps = decoded.config.outputIntervalSteps, outputIntervalSteps <= 0 {
            throw AutoSageError(code: "invalid_input", message: "config.output_interval_steps must be > 0.")
        }

        let initialType = decoded.config.initialCondition.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard initialType == "step_function" || initialType == "step-function" || initialType == "stepfunction" else {
            throw AutoSageError(code: "invalid_input", message: "config.initial_condition.type must be step_function.")
        }

        if decoded.config.initialCondition.center.isEmpty {
            throw AutoSageError(code: "invalid_input", message: "config.initial_condition.center must not be empty.")
        }
        if decoded.config.initialCondition.radius <= 0 {
            throw AutoSageError(code: "invalid_input", message: "config.initial_condition.radius must be > 0.")
        }

        for boundary in decoded.config.bcs {
            guard boundary.attribute > 0 else {
                throw AutoSageError(code: "invalid_input", message: "config.bcs[].attribute must be > 0.")
            }
            let type = boundary.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard type == "inflow" else {
                throw AutoSageError(code: "invalid_input", message: "config.bcs[].type must be inflow.")
            }
        }

        return decoded
    }

    private static func toDriverPayload(_ input: AdvectionInput) throws -> [String: JSONValue] {
        guard case .object(let meshObject) = input.mesh else {
            throw AutoSageError(code: "invalid_input", message: "mesh must be an object.")
        }
        let encodedConfig = try JSONCoding.makeDecoder().decode(
            JSONValue.self,
            from: JSONCoding.makeEncoder().encode(input.config)
        )
        guard case .object(let configObject) = encodedConfig else {
            throw AutoSageError(code: "internal_error", message: "Failed to encode advection config.")
        }
        return [
            "solver_class": .string("Advection"),
            "mesh": .object(meshObject),
            "config": .object(configObject)
        ]
    }
}
