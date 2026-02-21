// SPDX-License-Identifier: MIT
// AutoSage transient electromagnetics tool wrapper for MFEM driver.

import Foundation

private struct TransientEMInitialCondition: Codable, Equatable, Sendable {
    let type: String
    let center: [Double]
    let polarization: [Double]
}

private struct TransientEMBoundaryCondition: Codable, Equatable, Sendable {
    let attribute: Int
    let type: String
}

private struct TransientEMConfig: Codable, Equatable, Sendable {
    let permittivity: Double
    let permeability: Double
    let conductivity: Double
    let dt: Double
    let tFinal: Double
    let order: Int?
    let outputIntervalSteps: Int?
    let initialCondition: TransientEMInitialCondition
    let bcs: [TransientEMBoundaryCondition]

    enum CodingKeys: String, CodingKey {
        case permittivity
        case permeability
        case conductivity
        case dt
        case tFinal = "t_final"
        case order
        case outputIntervalSteps = "output_interval_steps"
        case initialCondition = "initial_condition"
        case bcs
    }
}

private struct TransientEMInput: Codable, Equatable, Sendable {
    let solverClass: String?
    let mesh: JSONValue
    let config: TransientEMConfig

    enum CodingKeys: String, CodingKey {
        case solverClass = "solver_class"
        case mesh
        case config
    }
}

public struct TransientEMTool: Tool {
    public let name: String = "transient_em.solve"
    public let version: String
    public let description: String
    public let jsonSchema: JSONValue = TransientEMTool.schema

    private let feaBridge: FEATool

    public init(
        version: String = "0.1.0",
        description: String = "Simulates transient Maxwell dynamics in H(curl) using implicit time integration and AMS-preconditioned solves.",
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
                "enum": .stringArray(["TransientMaxwell"])
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
                    "permeability": .object(["type": .string("number")]),
                    "conductivity": .object(["type": .string("number")]),
                    "dt": .object(["type": .string("number")]),
                    "t_final": .object(["type": .string("number")]),
                    "order": .object(["type": .string("integer")]),
                    "output_interval_steps": .object(["type": .string("integer")]),
                    "initial_condition": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "type": .object([
                                "type": .string("string"),
                                "enum": .stringArray(["dipole_pulse"])
                            ]),
                            "center": .object([
                                "type": .string("array"),
                                "items": .object(["type": .string("number")])
                            ]),
                            "polarization": .object([
                                "type": .string("array"),
                                "items": .object(["type": .string("number")])
                            ])
                        ]),
                        "required": .stringArray(["type", "center", "polarization"])
                    ]),
                    "bcs": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "attribute": .object(["type": .string("integer")]),
                                "type": .object([
                                    "type": .string("string"),
                                    "enum": .stringArray(["perfect_conductor"])
                                ])
                            ]),
                            "required": .stringArray(["attribute", "type"])
                        ])
                    ])
                ]),
                "required": .stringArray([
                    "permittivity",
                    "permeability",
                    "conductivity",
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

    private static func decodeInput(_ input: JSONValue?) throws -> TransientEMInput {
        guard let input else {
            throw AutoSageError(code: "invalid_input", message: "transient_em.solve requires an input object.")
        }
        guard case .object = input else {
            throw AutoSageError(code: "invalid_input", message: "transient_em.solve input must be an object.")
        }

        let data = try JSONCoding.makeEncoder().encode(input)
        let decoded = try JSONCoding.makeDecoder().decode(TransientEMInput.self, from: data)

        if let solverClass = decoded.solverClass {
            let normalized = solverClass.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let valid = [
                "transientmaxwell",
                "transient_maxwell",
                "transient-maxwell",
                "transientem",
                "transient_em",
                "transient-em"
            ]
            guard valid.contains(normalized) else {
                throw AutoSageError(code: "invalid_input", message: "solver_class must be TransientMaxwell.")
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
        if decoded.config.permeability <= 0 {
            throw AutoSageError(code: "invalid_input", message: "config.permeability must be > 0.")
        }
        if decoded.config.conductivity < 0 {
            throw AutoSageError(code: "invalid_input", message: "config.conductivity must be >= 0.")
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

        let initialType = decoded.config.initialCondition.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard initialType == "dipole_pulse" || initialType == "dipole-pulse" || initialType == "dipolepulse" else {
            throw AutoSageError(code: "invalid_input", message: "config.initial_condition.type must be dipole_pulse.")
        }
        guard !decoded.config.initialCondition.center.isEmpty else {
            throw AutoSageError(code: "invalid_input", message: "config.initial_condition.center must not be empty.")
        }
        guard !decoded.config.initialCondition.polarization.isEmpty else {
            throw AutoSageError(code: "invalid_input", message: "config.initial_condition.polarization must not be empty.")
        }
        if !decoded.config.initialCondition.polarization.contains(where: { abs($0) > 0 }) {
            throw AutoSageError(code: "invalid_input", message: "config.initial_condition.polarization must have non-zero magnitude.")
        }

        var hasPerfectConductor = false
        for boundary in decoded.config.bcs {
            guard boundary.attribute > 0 else {
                throw AutoSageError(code: "invalid_input", message: "config.bcs[].attribute must be > 0.")
            }
            let type = boundary.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard type == "perfect_conductor" || type == "perfect-conductor" || type == "perfectconductor" else {
                throw AutoSageError(code: "invalid_input", message: "config.bcs[].type must be perfect_conductor.")
            }
            hasPerfectConductor = true
        }
        guard hasPerfectConductor else {
            throw AutoSageError(
                code: "invalid_input",
                message: "config.bcs must include at least one perfect_conductor boundary condition."
            )
        }

        return decoded
    }

    private static func toDriverPayload(_ input: TransientEMInput) throws -> [String: JSONValue] {
        guard case .object(let meshObject) = input.mesh else {
            throw AutoSageError(code: "invalid_input", message: "mesh must be an object.")
        }
        let encodedConfig = try JSONCoding.makeDecoder().decode(
            JSONValue.self,
            from: JSONCoding.makeEncoder().encode(input.config)
        )
        guard case .object(let configObject) = encodedConfig else {
            throw AutoSageError(code: "internal_error", message: "Failed to encode transient electromagnetics config.")
        }
        return [
            "solver_class": .string("TransientMaxwell"),
            "mesh": .object(meshObject),
            "config": .object(configObject)
        ]
    }
}
