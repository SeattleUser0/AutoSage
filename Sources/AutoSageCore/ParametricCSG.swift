// SPDX-License-Identifier: MIT

import Foundation

public struct ParametricVector3: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public var magnitudeSquared: Double {
        (x * x) + (y * y) + (z * z)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode([x, y, z])
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let values = try container.decode([Double].self)
        guard values.count == 3 else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a 3-element numeric array."
            )
        }
        guard values.allSatisfy(\.isFinite) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Vector values must be finite numbers."
            )
        }
        self = ParametricVector3(values[0], values[1], values[2])
    }
}

public enum ParametricCSGNodeType: String, Codable, CaseIterable, Sendable {
    case box
    case cylinder
    case sphere
    case importedMesh = "imported_mesh"
    case translate
    case rotate
    case union
    case difference
    case intersect
}

public indirect enum ParametricCSGNode: Codable, Equatable, Sendable {
    case box(size: ParametricVector3, center: ParametricVector3)
    case cylinder(radius: Double, height: Double, center: ParametricVector3, axis: ParametricVector3)
    case sphere(radius: Double, center: ParametricVector3)
    case importedMesh(path: String)
    case translate(vector: ParametricVector3, child: ParametricCSGNode)
    case rotate(axis: ParametricVector3, angleDegrees: Double, child: ParametricCSGNode)
    case union(children: [ParametricCSGNode])
    case difference(target: ParametricCSGNode, tool: ParametricCSGNode)
    case intersect(children: [ParametricCSGNode])

    private enum CodingKeys: String, CodingKey {
        case type
        case size
        case center
        case radius
        case height
        case path
        case vector
        case child
        case axis
        case angleDegrees = "angle_degrees"
        case children
        case target
        case tool
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let nodeType = try container.decode(ParametricCSGNodeType.self, forKey: .type)

        switch nodeType {
        case .box:
            let size = try container.decode(ParametricVector3.self, forKey: .size)
            let center = try container.decode(ParametricVector3.self, forKey: .center)
            try Self.requirePositive(size.x, for: .size, in: container)
            try Self.requirePositive(size.y, for: .size, in: container)
            try Self.requirePositive(size.z, for: .size, in: container)
            self = .box(size: size, center: center)
        case .cylinder:
            let radius = try container.decode(Double.self, forKey: .radius)
            let height = try container.decode(Double.self, forKey: .height)
            let center = try container.decode(ParametricVector3.self, forKey: .center)
            let axis = try container.decode(ParametricVector3.self, forKey: .axis)
            try Self.requirePositive(radius, for: .radius, in: container)
            try Self.requirePositive(height, for: .height, in: container)
            try Self.requireNonZeroVector(axis, for: .axis, in: container)
            self = .cylinder(radius: radius, height: height, center: center, axis: axis)
        case .sphere:
            let radius = try container.decode(Double.self, forKey: .radius)
            let center = try container.decode(ParametricVector3.self, forKey: .center)
            try Self.requirePositive(radius, for: .radius, in: container)
            self = .sphere(radius: radius, center: center)
        case .importedMesh:
            let path = try container.decode(String.self, forKey: .path).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .path,
                    in: container,
                    debugDescription: "path must be a non-empty string."
                )
            }
            self = .importedMesh(path: path)
        case .translate:
            let vector = try container.decode(ParametricVector3.self, forKey: .vector)
            let child = try container.decode(ParametricCSGNode.self, forKey: .child)
            self = .translate(vector: vector, child: child)
        case .rotate:
            let axis = try container.decode(ParametricVector3.self, forKey: .axis)
            let angleDegrees = try container.decode(Double.self, forKey: .angleDegrees)
            let child = try container.decode(ParametricCSGNode.self, forKey: .child)
            try Self.requireFinite(angleDegrees, for: .angleDegrees, in: container)
            try Self.requireNonZeroVector(axis, for: .axis, in: container)
            self = .rotate(axis: axis, angleDegrees: angleDegrees, child: child)
        case .union:
            let children = try container.decode([ParametricCSGNode].self, forKey: .children)
            try Self.requireAtLeastTwoChildren(children, for: .children, in: container)
            self = .union(children: children)
        case .difference:
            let target = try container.decode(ParametricCSGNode.self, forKey: .target)
            let tool = try container.decode(ParametricCSGNode.self, forKey: .tool)
            self = .difference(target: target, tool: tool)
        case .intersect:
            let children = try container.decode([ParametricCSGNode].self, forKey: .children)
            try Self.requireAtLeastTwoChildren(children, for: .children, in: container)
            self = .intersect(children: children)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .box(let size, let center):
            try container.encode(ParametricCSGNodeType.box, forKey: .type)
            try container.encode(size, forKey: .size)
            try container.encode(center, forKey: .center)
        case .cylinder(let radius, let height, let center, let axis):
            try container.encode(ParametricCSGNodeType.cylinder, forKey: .type)
            try container.encode(radius, forKey: .radius)
            try container.encode(height, forKey: .height)
            try container.encode(center, forKey: .center)
            try container.encode(axis, forKey: .axis)
        case .sphere(let radius, let center):
            try container.encode(ParametricCSGNodeType.sphere, forKey: .type)
            try container.encode(radius, forKey: .radius)
            try container.encode(center, forKey: .center)
        case .importedMesh(let path):
            try container.encode(ParametricCSGNodeType.importedMesh, forKey: .type)
            try container.encode(path, forKey: .path)
        case .translate(let vector, let child):
            try container.encode(ParametricCSGNodeType.translate, forKey: .type)
            try container.encode(vector, forKey: .vector)
            try container.encode(child, forKey: .child)
        case .rotate(let axis, let angleDegrees, let child):
            try container.encode(ParametricCSGNodeType.rotate, forKey: .type)
            try container.encode(axis, forKey: .axis)
            try container.encode(angleDegrees, forKey: .angleDegrees)
            try container.encode(child, forKey: .child)
        case .union(let children):
            try container.encode(ParametricCSGNodeType.union, forKey: .type)
            try container.encode(children, forKey: .children)
        case .difference(let target, let tool):
            try container.encode(ParametricCSGNodeType.difference, forKey: .type)
            try container.encode(target, forKey: .target)
            try container.encode(tool, forKey: .tool)
        case .intersect(let children):
            try container.encode(ParametricCSGNodeType.intersect, forKey: .type)
            try container.encode(children, forKey: .children)
        }
    }

    public static func decode(from json: JSONValue) throws -> ParametricCSGNode {
        let data = try JSONCoding.makeEncoder().encode(json)
        return try JSONCoding.makeDecoder().decode(ParametricCSGNode.self, from: data)
    }

    public func encodeToJSONValue() throws -> JSONValue {
        let data = try JSONCoding.makeEncoder().encode(self)
        return try JSONCoding.makeDecoder().decode(JSONValue.self, from: data)
    }

    public static let jsonSchema: JSONValue = {
        let nodeRef = ref("#/$defs/node")
        let vec3Ref = ref("#/$defs/vec3")

        return .object([
            "$schema": .string("https://json-schema.org/draft/2020-12/schema"),
            "$id": .string("https://autosage.dev/schemas/parametric-csg-node.schema.json"),
            "title": .string("AutoSage Parametric CSG Node"),
            "description": .string("Canonical parametric DSL AST for deterministic CSG graph operations."),
            "$ref": .string("#/$defs/node"),
            "$defs": .object([
                "vec3": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("number")]),
                    "minItems": .number(3),
                    "maxItems": .number(3)
                ]),
                "node": .object([
                    "oneOf": .array([
                        ref("#/$defs/box"),
                        ref("#/$defs/cylinder"),
                        ref("#/$defs/sphere"),
                        ref("#/$defs/imported_mesh"),
                        ref("#/$defs/translate"),
                        ref("#/$defs/rotate"),
                        ref("#/$defs/union"),
                        ref("#/$defs/difference"),
                        ref("#/$defs/intersect")
                    ])
                ]),
                "box": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "type": .object(["const": .string("box")]),
                        "size": vec3Ref,
                        "center": vec3Ref
                    ]),
                    "required": .stringArray(["type", "size", "center"]),
                    "additionalProperties": .bool(false)
                ]),
                "cylinder": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "type": .object(["const": .string("cylinder")]),
                        "radius": .object([
                            "type": .string("number"),
                            "exclusiveMinimum": .number(0)
                        ]),
                        "height": .object([
                            "type": .string("number"),
                            "exclusiveMinimum": .number(0)
                        ]),
                        "center": vec3Ref,
                        "axis": vec3Ref
                    ]),
                    "required": .stringArray(["type", "radius", "height", "center", "axis"]),
                    "additionalProperties": .bool(false)
                ]),
                "sphere": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "type": .object(["const": .string("sphere")]),
                        "radius": .object([
                            "type": .string("number"),
                            "exclusiveMinimum": .number(0)
                        ]),
                        "center": vec3Ref
                    ]),
                    "required": .stringArray(["type", "radius", "center"]),
                    "additionalProperties": .bool(false)
                ]),
                "imported_mesh": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "type": .object(["const": .string("imported_mesh")]),
                        "path": .object([
                            "type": .string("string"),
                            "minLength": .number(1)
                        ])
                    ]),
                    "required": .stringArray(["type", "path"]),
                    "additionalProperties": .bool(false)
                ]),
                "translate": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "type": .object(["const": .string("translate")]),
                        "vector": vec3Ref,
                        "child": nodeRef
                    ]),
                    "required": .stringArray(["type", "vector", "child"]),
                    "additionalProperties": .bool(false)
                ]),
                "rotate": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "type": .object(["const": .string("rotate")]),
                        "axis": vec3Ref,
                        "angle_degrees": .object(["type": .string("number")]),
                        "child": nodeRef
                    ]),
                    "required": .stringArray(["type", "axis", "angle_degrees", "child"]),
                    "additionalProperties": .bool(false)
                ]),
                "union": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "type": .object(["const": .string("union")]),
                        "children": .object([
                            "type": .string("array"),
                            "items": nodeRef,
                            "minItems": .number(2)
                        ])
                    ]),
                    "required": .stringArray(["type", "children"]),
                    "additionalProperties": .bool(false)
                ]),
                "difference": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "type": .object(["const": .string("difference")]),
                        "target": nodeRef,
                        "tool": nodeRef
                    ]),
                    "required": .stringArray(["type", "target", "tool"]),
                    "additionalProperties": .bool(false)
                ]),
                "intersect": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "type": .object(["const": .string("intersect")]),
                        "children": .object([
                            "type": .string("array"),
                            "items": nodeRef,
                            "minItems": .number(2)
                        ])
                    ]),
                    "required": .stringArray(["type", "children"]),
                    "additionalProperties": .bool(false)
                ])
            ])
        ])
    }()

    private static func ref(_ pointer: String) -> JSONValue {
        .object(["$ref": .string(pointer)])
    }

    private static func requireFinite(
        _ value: Double,
        for key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws {
        guard value.isFinite else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) must be finite."
            )
        }
    }

    private static func requirePositive(
        _ value: Double,
        for key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws {
        try requireFinite(value, for: key, in: container)
        guard value > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) must be > 0."
            )
        }
    }

    private static func requireNonZeroVector(
        _ vector: ParametricVector3,
        for key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws {
        guard vector.magnitudeSquared > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) must not be the zero vector."
            )
        }
    }

    private static func requireAtLeastTwoChildren(
        _ children: [ParametricCSGNode],
        for key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws {
        guard children.count >= 2 else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) must contain at least 2 nodes."
            )
        }
    }
}

