// SPDX-License-Identifier: MIT
// AutoSage elastodynamics tool wrapper for MFEM driver.

import Foundation

private struct ElastodynamicsInitialCondition: Codable, Equatable, Sendable {
    let displacement: [Double]
    let velocity: [Double]
}

private struct ElastodynamicsBoundaryCondition: Codable, Equatable, Sendable {
    let attribute: Int
    let type: String
    let value: [Double]?
    let frequency: Double?
}

private struct ElastodynamicsConfig: Codable, Equatable, Sendable {
    let density: Double
    let youngsModulus: Double
    let poissonRatio: Double
    let dt: Double
    let tFinal: Double
    let order: Int?
    let outputIntervalSteps: Int?
    let initialCondition: ElastodynamicsInitialCondition
    let bcs: [ElastodynamicsBoundaryCondition]

    enum CodingKeys: String, CodingKey {
        case density
        case youngsModulus = "youngs_modulus"
        case poissonRatio = "poisson_ratio"
        case dt
        case tFinal = "t_final"
        case order
        case outputIntervalSteps = "output_interval_steps"
        case initialCondition = "initial_condition"
        case bcs
    }
}

private struct ElastodynamicsInput: Codable, Equatable, Sendable {
    let solverClass: String?
    let mesh: JSONValue
    let config: ElastodynamicsConfig

    enum CodingKeys: String, CodingKey {
        case solverClass = "solver_class"
        case mesh
        case config
    }
}

public struct ElastodynamicsTool: Tool {
    public let name: String = "elastodynamics.solve"
    public let version: String
    public let description: String
    public let jsonSchema: JSONValue = ElastodynamicsTool.schema

    private let feaBridge: FEATool

    public init(
        version: String = "0.1.0",
        description: String = "Solves transient structural dynamics using linear elastodynamics with implicit time integration.",
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
                "enum": .stringArray(["Elastodynamics"])
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
                    "density": .object(["type": .string("number")]),
                    "youngs_modulus": .object(["type": .string("number")]),
                    "poisson_ratio": .object(["type": .string("number")]),
                    "dt": .object(["type": .string("number")]),
                    "t_final": .object(["type": .string("number")]),
                    "order": .object(["type": .string("integer")]),
                    "output_interval_steps": .object(["type": .string("integer")]),
                    "initial_condition": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "displacement": .object([
                                "type": .string("array"),
                                "items": .object(["type": .string("number")])
                            ]),
                            "velocity": .object([
                                "type": .string("array"),
                                "items": .object(["type": .string("number")])
                            ])
                        ]),
                        "required": .stringArray(["displacement", "velocity"])
                    ]),
                    "bcs": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "attribute": .object(["type": .string("integer")]),
                                "type": .object([
                                    "type": .string("string"),
                                    "enum": .stringArray(["fixed", "time_varying_load"])
                                ]),
                                "value": .object([
                                    "type": .string("array"),
                                    "items": .object(["type": .string("number")])
                                ]),
                                "frequency": .object(["type": .string("number")])
                            ]),
                            "required": .stringArray(["attribute", "type"])
                        ])
                    ])
                ]),
                "required": .stringArray([
                    "density",
                    "youngs_modulus",
                    "poisson_ratio",
                    "dt",
                    "t_final",
                    "initial_condition",
                    "bcs"
                ])
            ])
        ]),
        "required": .stringArray(["mesh", "config"]),
        "additionalProperties": .bool(true)
    ])

    private static func decodeInput(_ input: JSONValue?) throws -> ElastodynamicsInput {
        guard let input else {
            throw AutoSageError(code: "invalid_input", message: "elastodynamics.solve requires an input object.")
        }
        guard case .object = input else {
            throw AutoSageError(code: "invalid_input", message: "elastodynamics.solve input must be an object.")
        }

        let data = try JSONCoding.makeEncoder().encode(input)
        let decoded = try JSONCoding.makeDecoder().decode(ElastodynamicsInput.self, from: data)

        if let solverClass = decoded.solverClass {
            let normalized = solverClass.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let valid = [
                "elastodynamics",
                "elasto_dynamics",
                "elasto-dynamics"
            ]
            guard valid.contains(normalized) else {
                throw AutoSageError(code: "invalid_input", message: "solver_class must be Elastodynamics.")
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

        if decoded.config.density <= 0 {
            throw AutoSageError(code: "invalid_input", message: "config.density must be > 0.")
        }
        if decoded.config.youngsModulus <= 0 {
            throw AutoSageError(code: "invalid_input", message: "config.youngs_modulus must be > 0.")
        }
        if decoded.config.poissonRatio <= -1 || decoded.config.poissonRatio >= 0.5 {
            throw AutoSageError(code: "invalid_input", message: "config.poisson_ratio must be in (-1, 0.5).")
        }
        if decoded.config.dt <= 0 {
            throw AutoSageError(code: "invalid_input", message: "config.dt must be > 0.")
        }
        if decoded.config.tFinal <= 0 {
            throw AutoSageError(code: "invalid_input", message: "config.t_final must be > 0.")
        }
        if let order = decoded.config.order, order < 1 {
            throw AutoSageError(code: "invalid_input", message: "config.order must be >= 1.")
        }
        if let outputIntervalSteps = decoded.config.outputIntervalSteps, outputIntervalSteps <= 0 {
            throw AutoSageError(code: "invalid_input", message: "config.output_interval_steps must be > 0.")
        }
        if decoded.config.initialCondition.displacement.isEmpty {
            throw AutoSageError(code: "invalid_input", message: "config.initial_condition.displacement must not be empty.")
        }
        if decoded.config.initialCondition.velocity.isEmpty {
            throw AutoSageError(code: "invalid_input", message: "config.initial_condition.velocity must not be empty.")
        }
        if decoded.config.bcs.isEmpty {
            throw AutoSageError(code: "invalid_input", message: "config.bcs must not be empty.")
        }

        var hasFixedBoundary = false
        for boundary in decoded.config.bcs {
            guard boundary.attribute > 0 else {
                throw AutoSageError(code: "invalid_input", message: "config.bcs[].attribute must be > 0.")
            }
            let type = boundary.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if type == "fixed" {
                hasFixedBoundary = true
                continue
            }
            guard type == "time_varying_load" || type == "time-varying-load" || type == "timevaryingload" else {
                throw AutoSageError(code: "invalid_input", message: "config.bcs[].type must be fixed or time_varying_load.")
            }
            guard let value = boundary.value, !value.isEmpty else {
                throw AutoSageError(code: "invalid_input", message: "config.bcs[].value is required when type=time_varying_load.")
            }
            guard let frequency = boundary.frequency, frequency > 0 else {
                throw AutoSageError(code: "invalid_input", message: "config.bcs[].frequency must be > 0 when type=time_varying_load.")
            }
        }
        guard hasFixedBoundary else {
            throw AutoSageError(code: "invalid_input", message: "config.bcs must include at least one fixed boundary condition.")
        }

        return decoded
    }

    private static func toDriverPayload(_ input: ElastodynamicsInput) throws -> [String: JSONValue] {
        guard case .object(let meshObject) = input.mesh else {
            throw AutoSageError(code: "invalid_input", message: "mesh must be an object.")
        }
        let encodedConfig = try JSONCoding.makeDecoder().decode(
            JSONValue.self,
            from: JSONCoding.makeEncoder().encode(input.config)
        )
        guard case .object(let configObject) = encodedConfig else {
            throw AutoSageError(code: "internal_error", message: "Failed to encode elastodynamics config.")
        }
        return [
            "solver_class": .string("Elastodynamics"),
            "mesh": .object(meshObject),
            "config": .object(configObject)
        ]
    }
}
