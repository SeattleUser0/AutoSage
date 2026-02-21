// SPDX-License-Identifier: MIT
// AutoSage structural modal analysis tool wrapper for MFEM driver.

import Foundation

private struct StructuralModalBoundaryCondition: Codable, Equatable, Sendable {
    let attribute: Int
    let type: String
}

private struct StructuralModalConfig: Codable, Equatable, Sendable {
    let density: Double
    let youngsModulus: Double
    let poissonRatio: Double
    let numModes: Int
    let bcs: [StructuralModalBoundaryCondition]

    enum CodingKeys: String, CodingKey {
        case density
        case youngsModulus = "youngs_modulus"
        case poissonRatio = "poisson_ratio"
        case numModes = "num_modes"
        case bcs
    }
}

private struct StructuralModalInput: Codable, Equatable, Sendable {
    let solverClass: String?
    let mesh: JSONValue
    let config: StructuralModalConfig

    enum CodingKeys: String, CodingKey {
        case solverClass = "solver_class"
        case mesh
        case config
    }
}

public struct StructuralModalTool: Tool {
    public let name: String = "structural_modal.solve"
    public let version: String
    public let description: String
    public let jsonSchema: JSONValue = StructuralModalTool.schema

    private let feaBridge: FEATool

    public init(
        version: String = "0.1.0",
        description: String = "Computes structural vibration modes by solving the linear elasticity generalized eigenproblem K u = lambda M u.",
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
                "enum": .stringArray(["StructuralModal"])
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
                    "num_modes": .object(["type": .string("integer")]),
                    "bcs": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "attribute": .object(["type": .string("integer")]),
                                "type": .object([
                                    "type": .string("string"),
                                    "enum": .stringArray(["fixed"])
                                ])
                            ]),
                            "required": .stringArray(["attribute", "type"])
                        ])
                    ])
                ]),
                "required": .stringArray(["density", "youngs_modulus", "poisson_ratio", "num_modes", "bcs"])
            ])
        ]),
        "required": .stringArray(["mesh", "config"]),
        "additionalProperties": .bool(true)
    ])

    private static func decodeInput(_ input: JSONValue?) throws -> StructuralModalInput {
        guard let input else {
            throw AutoSageError(code: "invalid_input", message: "structural_modal.solve requires an input object.")
        }
        guard case .object = input else {
            throw AutoSageError(code: "invalid_input", message: "structural_modal.solve input must be an object.")
        }

        let data = try JSONCoding.makeEncoder().encode(input)
        let decoded = try JSONCoding.makeDecoder().decode(StructuralModalInput.self, from: data)

        if let solverClass = decoded.solverClass {
            let normalized = solverClass.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized == "structuralmodal" || normalized == "structural_modal" || normalized == "structural-modal" else {
                throw AutoSageError(code: "invalid_input", message: "solver_class must be StructuralModal.")
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
        if decoded.config.numModes <= 0 {
            throw AutoSageError(code: "invalid_input", message: "config.num_modes must be > 0.")
        }
        if decoded.config.numModes > 64 {
            throw AutoSageError(code: "invalid_input", message: "config.num_modes must be <= 64.")
        }

        var hasFixed = false
        for boundary in decoded.config.bcs {
            guard boundary.attribute > 0 else {
                throw AutoSageError(code: "invalid_input", message: "config.bcs[].attribute must be > 0.")
            }
            let type = boundary.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard type == "fixed" else {
                throw AutoSageError(code: "invalid_input", message: "config.bcs[].type must be fixed.")
            }
            hasFixed = true
        }
        guard hasFixed else {
            throw AutoSageError(
                code: "invalid_input",
                message: "config.bcs must include at least one fixed boundary condition."
            )
        }

        return decoded
    }

    private static func toDriverPayload(_ input: StructuralModalInput) throws -> [String: JSONValue] {
        guard case .object(let meshObject) = input.mesh else {
            throw AutoSageError(code: "invalid_input", message: "mesh must be an object.")
        }
        let encodedConfig = try JSONCoding.makeDecoder().decode(
            JSONValue.self,
            from: JSONCoding.makeEncoder().encode(input.config)
        )
        guard case .object(let configObject) = encodedConfig else {
            throw AutoSageError(code: "internal_error", message: "Failed to encode structural modal config.")
        }
        return [
            "solver_class": .string("StructuralModal"),
            "mesh": .object(meshObject),
            "config": .object(configObject)
        ]
    }
}
