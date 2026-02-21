// SPDX-License-Identifier: MIT
// AutoSage electromagnetic scattering tool wrapper for MFEM driver.

import Foundation

private struct ElectromagneticScatteringBoundaryCondition: Codable, Equatable, Sendable {
    let attribute: Int
    let type: String
}

private struct ElectromagneticScatteringSourceCurrent: Codable, Equatable, Sendable {
    let attributes: [Int]
    let jReal: [Double]
    let jImag: [Double]?

    enum CodingKeys: String, CodingKey {
        case attributes
        case jReal = "J_real"
        case jImag = "J_imag"
    }
}

private struct ElectromagneticScatteringConfig: Codable, Equatable, Sendable {
    let frequency: Double
    let permittivity: Double
    let permeability: Double
    let pmlAttributes: [Int]
    let sourceCurrent: ElectromagneticScatteringSourceCurrent?
    let bcs: [ElectromagneticScatteringBoundaryCondition]

    enum CodingKeys: String, CodingKey {
        case frequency
        case permittivity
        case permeability
        case pmlAttributes = "pml_attributes"
        case sourceCurrent = "source_current"
        case bcs
    }
}

private struct ElectromagneticScatteringInput: Codable, Equatable, Sendable {
    let solverClass: String?
    let mesh: JSONValue
    let config: ElectromagneticScatteringConfig

    enum CodingKeys: String, CodingKey {
        case solverClass = "solver_class"
        case mesh
        case config
    }
}

public struct ElectromagneticScatteringTool: Tool {
    public let name: String = "em_scattering.solve"
    public let version: String
    public let description: String
    public let jsonSchema: JSONValue = ElectromagneticScatteringTool.schema

    private let feaBridge: FEATool

    public init(
        version: String = "0.1.0",
        description: String = "Solves frequency-domain Maxwell scattering with PML regions using complex Nedelec finite elements.",
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
                "enum": .stringArray(["ElectromagneticScattering"])
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
                    "frequency": .object(["type": .string("number")]),
                    "permittivity": .object(["type": .string("number")]),
                    "permeability": .object(["type": .string("number")]),
                    "pml_attributes": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("integer")])
                    ]),
                    "source_current": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "attributes": .object([
                                "type": .string("array"),
                                "items": .object(["type": .string("integer")])
                            ]),
                            "J_real": .object([
                                "type": .string("array"),
                                "items": .object(["type": .string("number")])
                            ]),
                            "J_imag": .object([
                                "type": .string("array"),
                                "items": .object(["type": .string("number")])
                            ])
                        ]),
                        "required": .stringArray(["attributes", "J_real"]),
                        "additionalProperties": .bool(true)
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
                "required": .stringArray(["frequency", "permittivity", "permeability", "pml_attributes", "bcs"]),
                "additionalProperties": .bool(true)
            ])
        ]),
        "required": .stringArray(["mesh", "config"]),
        "additionalProperties": .bool(true)
    ])

    private static func decodeInput(_ input: JSONValue?) throws -> ElectromagneticScatteringInput {
        guard let input else {
            throw AutoSageError(code: "invalid_input", message: "em_scattering.solve requires an input object.")
        }
        guard case .object = input else {
            throw AutoSageError(code: "invalid_input", message: "em_scattering.solve input must be an object.")
        }

        let data = try JSONCoding.makeEncoder().encode(input)
        let decoded = try JSONCoding.makeDecoder().decode(ElectromagneticScatteringInput.self, from: data)

        if let solverClass = decoded.solverClass {
            let normalized = solverClass.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized == "electromagneticscattering" ||
                    normalized == "electromagnetic_scattering" ||
                    normalized == "electromagnetic-scattering" ||
                    normalized == "emscattering" ||
                    normalized == "em_scattering" ||
                    normalized == "em-scattering" else {
                throw AutoSageError(code: "invalid_input", message: "solver_class must be ElectromagneticScattering.")
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

        if decoded.config.frequency <= 0 {
            throw AutoSageError(code: "invalid_input", message: "config.frequency must be > 0.")
        }
        if decoded.config.permittivity <= 0 {
            throw AutoSageError(code: "invalid_input", message: "config.permittivity must be > 0.")
        }
        if decoded.config.permeability <= 0 {
            throw AutoSageError(code: "invalid_input", message: "config.permeability must be > 0.")
        }
        for attribute in decoded.config.pmlAttributes {
            if attribute <= 0 {
                throw AutoSageError(code: "invalid_input", message: "config.pml_attributes entries must be > 0.")
            }
        }

        if decoded.config.bcs.isEmpty {
            throw AutoSageError(
                code: "invalid_input",
                message: "config.bcs must include at least one perfect_conductor boundary condition."
            )
        }
        for boundary in decoded.config.bcs {
            guard boundary.attribute > 0 else {
                throw AutoSageError(code: "invalid_input", message: "config.bcs[].attribute must be > 0.")
            }
            let type = boundary.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard type == "perfect_conductor" || type == "perfect-conductor" || type == "perfectconductor" else {
                throw AutoSageError(code: "invalid_input", message: "config.bcs[].type must be perfect_conductor.")
            }
        }

        if let sourceCurrent = decoded.config.sourceCurrent {
            if sourceCurrent.attributes.isEmpty {
                throw AutoSageError(code: "invalid_input", message: "config.source_current.attributes must not be empty.")
            }
            for attribute in sourceCurrent.attributes {
                if attribute <= 0 {
                    throw AutoSageError(code: "invalid_input", message: "config.source_current.attributes entries must be > 0.")
                }
            }
            if sourceCurrent.jReal.isEmpty {
                throw AutoSageError(code: "invalid_input", message: "config.source_current.J_real must not be empty.")
            }
            if let jImag = sourceCurrent.jImag, jImag.isEmpty {
                throw AutoSageError(code: "invalid_input", message: "config.source_current.J_imag must not be empty when provided.")
            }
        }

        return decoded
    }

    private static func toDriverPayload(_ input: ElectromagneticScatteringInput) throws -> [String: JSONValue] {
        guard case .object(let meshObject) = input.mesh else {
            throw AutoSageError(code: "invalid_input", message: "mesh must be an object.")
        }
        let encodedConfig = try JSONCoding.makeDecoder().decode(
            JSONValue.self,
            from: JSONCoding.makeEncoder().encode(input.config)
        )
        guard case .object(let configObject) = encodedConfig else {
            throw AutoSageError(
                code: "internal_error",
                message: "Failed to encode electromagnetic scattering config."
            )
        }
        return [
            "solver_class": .string("ElectromagneticScattering"),
            "mesh": .object(meshObject),
            "config": .object(configObject)
        ]
    }
}
