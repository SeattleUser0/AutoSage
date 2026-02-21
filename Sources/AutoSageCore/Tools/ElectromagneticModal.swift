// SPDX-License-Identifier: MIT
// AutoSage electromagnetic cavity modal analysis tool wrapper for MFEM driver.

import Foundation

private struct ElectromagneticModalBoundaryCondition: Codable, Equatable, Sendable {
    let attribute: Int
    let type: String
}

private struct ElectromagneticModalConfig: Codable, Equatable, Sendable {
    let permittivity: Double
    let permeability: Double
    let numModes: Int
    let bcs: [ElectromagneticModalBoundaryCondition]

    enum CodingKeys: String, CodingKey {
        case permittivity
        case permeability
        case numModes = "num_modes"
        case bcs
    }
}

private struct ElectromagneticModalInput: Codable, Equatable, Sendable {
    let solverClass: String?
    let mesh: JSONValue
    let config: ElectromagneticModalConfig

    enum CodingKeys: String, CodingKey {
        case solverClass = "solver_class"
        case mesh
        case config
    }
}

public struct ElectromagneticModalTool: Tool {
    public let name: String = "em_modal.solve"
    public let version: String
    public let description: String
    public let jsonSchema: JSONValue = ElectromagneticModalTool.schema

    private let feaBridge: FEATool

    public init(
        version: String = "0.1.0",
        description: String = "Computes resonant cavity modes by solving curl(mu^-1 curl E) = lambda epsilon E with Nedelec elements.",
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
                "enum": .stringArray(["ElectromagneticModal"])
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
                    "num_modes": .object(["type": .string("integer")]),
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
                "required": .stringArray(["permittivity", "permeability", "num_modes", "bcs"])
            ])
        ]),
        "required": .stringArray(["mesh", "config"]),
        "additionalProperties": .bool(true)
    ])

    private static func decodeInput(_ input: JSONValue?) throws -> ElectromagneticModalInput {
        guard let input else {
            throw AutoSageError(code: "invalid_input", message: "em_modal.solve requires an input object.")
        }
        guard case .object = input else {
            throw AutoSageError(code: "invalid_input", message: "em_modal.solve input must be an object.")
        }

        let data = try JSONCoding.makeEncoder().encode(input)
        let decoded = try JSONCoding.makeDecoder().decode(ElectromagneticModalInput.self, from: data)

        if let solverClass = decoded.solverClass {
            let normalized = solverClass.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized == "electromagneticmodal" || normalized == "electromagnetic_modal" ||
                    normalized == "electromagnetic-modal" || normalized == "emmodal" ||
                    normalized == "em_modal" || normalized == "em-modal" else {
                throw AutoSageError(code: "invalid_input", message: "solver_class must be ElectromagneticModal.")
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
        if decoded.config.numModes <= 0 {
            throw AutoSageError(code: "invalid_input", message: "config.num_modes must be > 0.")
        }
        if decoded.config.numModes > 64 {
            throw AutoSageError(code: "invalid_input", message: "config.num_modes must be <= 64.")
        }

        var hasPerfectConductor = false
        for boundary in decoded.config.bcs {
            guard boundary.attribute > 0 else {
                throw AutoSageError(code: "invalid_input", message: "config.bcs[].attribute must be > 0.")
            }
            let type = boundary.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard type == "perfect_conductor" || type == "perfect-conductor" || type == "perfectconductor" else {
                throw AutoSageError(
                    code: "invalid_input",
                    message: "config.bcs[].type must be perfect_conductor."
                )
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

    private static func toDriverPayload(_ input: ElectromagneticModalInput) throws -> [String: JSONValue] {
        guard case .object(let meshObject) = input.mesh else {
            throw AutoSageError(code: "invalid_input", message: "mesh must be an object.")
        }
        let encodedConfig = try JSONCoding.makeDecoder().decode(
            JSONValue.self,
            from: JSONCoding.makeEncoder().encode(input.config)
        )
        guard case .object(let configObject) = encodedConfig else {
            throw AutoSageError(code: "internal_error", message: "Failed to encode electromagnetic modal config.")
        }
        return [
            "solver_class": .string("ElectromagneticModal"),
            "mesh": .object(meshObject),
            "config": .object(configObject)
        ]
    }
}
