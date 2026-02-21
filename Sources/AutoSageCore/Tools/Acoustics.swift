// SPDX-License-Identifier: MIT
// AutoSage acoustics tool wrapper for MFEM driver.

import Foundation

private struct AcousticsInitialCondition: Codable, Equatable, Sendable {
    let type: String
    let amplitude: Double
    let center: [Double]
}

private struct AcousticsBoundaryCondition: Codable, Equatable, Sendable {
    let attribute: Int
    let type: String
}

private struct AcousticsConfig: Codable, Equatable, Sendable {
    let waveSpeed: Double
    let dt: Double
    let tFinal: Double
    let initialCondition: AcousticsInitialCondition
    let bcs: [AcousticsBoundaryCondition]

    enum CodingKeys: String, CodingKey {
        case waveSpeed = "wave_speed"
        case dt
        case tFinal = "t_final"
        case initialCondition = "initial_condition"
        case bcs
    }
}

private struct AcousticsInput: Codable, Equatable, Sendable {
    let solverClass: String?
    let mesh: JSONValue
    let config: AcousticsConfig

    enum CodingKeys: String, CodingKey {
        case solverClass = "solver_class"
        case mesh
        case config
    }
}

public struct AcousticsTool: Tool {
    public let name: String = "acoustics.solve"
    public let version: String
    public let description: String
    public let jsonSchema: JSONValue = AcousticsTool.schema

    private let feaBridge: FEATool

    public init(
        version: String = "0.1.0",
        description: String = "Simulates time-dependent acoustic wave propagation using a second-order finite element formulation.",
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
                "enum": .stringArray(["AcousticWave"])
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
                    "wave_speed": .object(["type": .string("number")]),
                    "dt": .object(["type": .string("number")]),
                    "t_final": .object(["type": .string("number")]),
                    "initial_condition": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "type": .object([
                                "type": .string("string"),
                                "enum": .stringArray(["gaussian_pulse"])
                            ]),
                            "amplitude": .object(["type": .string("number")]),
                            "center": .object([
                                "type": .string("array"),
                                "items": .object(["type": .string("number")])
                            ])
                        ]),
                        "required": .stringArray(["type", "amplitude", "center"])
                    ]),
                    "bcs": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "attribute": .object(["type": .string("integer")]),
                                "type": .object([
                                    "type": .string("string"),
                                    "enum": .stringArray(["rigid_wall"])
                                ])
                            ]),
                            "required": .stringArray(["attribute", "type"])
                        ])
                    ])
                ]),
                "required": .stringArray(["wave_speed", "dt", "t_final", "initial_condition", "bcs"])
            ])
        ]),
        "required": .stringArray(["mesh", "config"]),
        "additionalProperties": .bool(true)
    ])

    private static func decodeInput(_ input: JSONValue?) throws -> AcousticsInput {
        guard let input else {
            throw AutoSageError(code: "invalid_input", message: "acoustics.solve requires an input object.")
        }
        guard case .object = input else {
            throw AutoSageError(code: "invalid_input", message: "acoustics.solve input must be an object.")
        }

        let data = try JSONCoding.makeEncoder().encode(input)
        let decoded = try JSONCoding.makeDecoder().decode(AcousticsInput.self, from: data)

        if let solverClass = decoded.solverClass {
            let normalized = solverClass.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized == "acousticwave" || normalized == "acoustic_wave" || normalized == "acoustic-wave" else {
                throw AutoSageError(code: "invalid_input", message: "solver_class must be AcousticWave.")
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

        if decoded.config.waveSpeed <= 0 {
            throw AutoSageError(code: "invalid_input", message: "config.wave_speed must be > 0.")
        }
        if decoded.config.dt <= 0 {
            throw AutoSageError(code: "invalid_input", message: "config.dt must be > 0.")
        }
        if decoded.config.tFinal <= 0 {
            throw AutoSageError(code: "invalid_input", message: "config.t_final must be > 0.")
        }

        let initialType = decoded.config.initialCondition.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard initialType == "gaussian_pulse" || initialType == "gaussian-pulse" || initialType == "gaussianpulse" else {
            throw AutoSageError(
                code: "invalid_input",
                message: "config.initial_condition.type must be gaussian_pulse."
            )
        }
        guard !decoded.config.initialCondition.center.isEmpty else {
            throw AutoSageError(
                code: "invalid_input",
                message: "config.initial_condition.center must not be empty."
            )
        }
        for value in decoded.config.initialCondition.center where !value.isFinite {
            throw AutoSageError(
                code: "invalid_input",
                message: "config.initial_condition.center entries must be finite numbers."
            )
        }

        for boundary in decoded.config.bcs {
            guard boundary.attribute > 0 else {
                throw AutoSageError(code: "invalid_input", message: "config.bcs[].attribute must be > 0.")
            }
            let type = boundary.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard type == "rigid_wall" || type == "rigid-wall" || type == "rigidwall" else {
                throw AutoSageError(code: "invalid_input", message: "config.bcs[].type must be rigid_wall.")
            }
        }

        return decoded
    }

    private static func toDriverPayload(_ input: AcousticsInput) throws -> [String: JSONValue] {
        guard case .object(let meshObject) = input.mesh else {
            throw AutoSageError(code: "invalid_input", message: "mesh must be an object.")
        }
        let encodedConfig = try JSONCoding.makeDecoder().decode(
            JSONValue.self,
            from: JSONCoding.makeEncoder().encode(input.config)
        )
        guard case .object(let configObject) = encodedConfig else {
            throw AutoSageError(code: "internal_error", message: "Failed to encode acoustics config.")
        }
        return [
            "solver_class": .string("AcousticWave"),
            "mesh": .object(meshObject),
            "config": .object(configObject)
        ]
    }
}
