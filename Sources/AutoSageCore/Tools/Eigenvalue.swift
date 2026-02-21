// SPDX-License-Identifier: MIT
// AutoSage eigenvalue tool wrapper for MFEM driver.

import Foundation

private struct EigenvalueBoundaryCondition: Codable, Equatable, Sendable {
    let attribute: Int
    let type: String
}

private struct EigenvalueConfig: Codable, Equatable, Sendable {
    let materialCoefficient: Double
    let numEigenmodes: Int
    let bcs: [EigenvalueBoundaryCondition]

    enum CodingKeys: String, CodingKey {
        case materialCoefficient = "material_coefficient"
        case numEigenmodes = "num_eigenmodes"
        case bcs
    }
}

private struct EigenvalueInput: Codable, Equatable, Sendable {
    let solverClass: String?
    let mesh: JSONValue
    let config: EigenvalueConfig

    enum CodingKeys: String, CodingKey {
        case solverClass = "solver_class"
        case mesh
        case config
    }
}

public struct EigenvalueTool: Tool {
    public let name: String = "eigen.solve"
    public let version: String
    public let description: String
    public let jsonSchema: JSONValue = EigenvalueTool.schema

    private let feaBridge: FEATool

    public init(
        version: String = "0.1.0",
        description: String = "Computes Laplace eigenmodes for modal analysis using an MFEM/Hypre LOBPCG solve.",
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
                "enum": .stringArray(["Eigenvalue"])
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
                    "material_coefficient": .object(["type": .string("number")]),
                    "num_eigenmodes": .object(["type": .string("integer")]),
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
                "required": .stringArray(["material_coefficient", "num_eigenmodes", "bcs"])
            ])
        ]),
        "required": .stringArray(["mesh", "config"]),
        "additionalProperties": .bool(true)
    ])

    private static func decodeInput(_ input: JSONValue?) throws -> EigenvalueInput {
        guard let input else {
            throw AutoSageError(code: "invalid_input", message: "eigen.solve requires an input object.")
        }
        guard case .object = input else {
            throw AutoSageError(code: "invalid_input", message: "eigen.solve input must be an object.")
        }

        let data = try JSONCoding.makeEncoder().encode(input)
        let decoded = try JSONCoding.makeDecoder().decode(EigenvalueInput.self, from: data)

        if let solverClass = decoded.solverClass {
            let normalized = solverClass.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalized == "eigenvalue" || normalized == "eigen_value" || normalized == "eigen-value" else {
                throw AutoSageError(code: "invalid_input", message: "solver_class must be Eigenvalue.")
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

        if decoded.config.materialCoefficient <= 0 {
            throw AutoSageError(code: "invalid_input", message: "config.material_coefficient must be > 0.")
        }
        if decoded.config.numEigenmodes <= 0 {
            throw AutoSageError(code: "invalid_input", message: "config.num_eigenmodes must be > 0.")
        }
        if decoded.config.numEigenmodes > 64 {
            throw AutoSageError(code: "invalid_input", message: "config.num_eigenmodes must be <= 64.")
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

    private static func toDriverPayload(_ input: EigenvalueInput) throws -> [String: JSONValue] {
        guard case .object(let meshObject) = input.mesh else {
            throw AutoSageError(code: "invalid_input", message: "mesh must be an object.")
        }
        let encodedConfig = try JSONCoding.makeDecoder().decode(
            JSONValue.self,
            from: JSONCoding.makeEncoder().encode(input.config)
        )
        guard case .object(let configObject) = encodedConfig else {
            throw AutoSageError(code: "internal_error", message: "Failed to encode eigenvalue config.")
        }
        return [
            "solver_class": .string("Eigenvalue"),
            "mesh": .object(meshObject),
            "config": .object(configObject)
        ]
    }
}
