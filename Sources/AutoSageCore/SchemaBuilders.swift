import Foundation

public enum JSONSchemaBuilder {
    public static func schemaObject(
        title: String? = nil,
        description: String,
        properties: [String: JSONValue],
        required: [String]
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "type": .string("object"),
            "description": .string(description),
            "properties": .object(properties),
            "required": .stringArray(required),
            "additionalProperties": .bool(false)
        ]
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            object["title"] = .string(title)
        }
        return .object(object)
    }

    public static func schemaString(
        description: String,
        enum values: [String]? = nil,
        pattern: String? = nil,
        minLength: Int? = nil,
        maxLength: Int? = nil
    ) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("string"),
            "description": .string(description)
        ]
        if let values, !values.isEmpty {
            schema["enum"] = .stringArray(values)
        }
        if let pattern, !pattern.isEmpty {
            schema["pattern"] = .string(pattern)
        }
        if let minLength {
            schema["minLength"] = .number(Double(minLength))
        }
        if let maxLength {
            schema["maxLength"] = .number(Double(maxLength))
        }
        return .object(schema)
    }

    public static func schemaNumber(
        description: String,
        minimum: Double? = nil,
        maximum: Double? = nil
    ) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("number"),
            "description": .string(description)
        ]
        if let minimum {
            schema["minimum"] = .number(minimum)
        }
        if let maximum {
            schema["maximum"] = .number(maximum)
        }
        return .object(schema)
    }

    public static func schemaInteger(
        description: String,
        minimum: Int? = nil,
        maximum: Int? = nil
    ) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("integer"),
            "description": .string(description)
        ]
        if let minimum {
            schema["minimum"] = .number(Double(minimum))
        }
        if let maximum {
            schema["maximum"] = .number(Double(maximum))
        }
        return .object(schema)
    }

    public static func schemaArray(
        description: String,
        items: JSONValue,
        minItems: Int? = nil,
        maxItems: Int? = nil
    ) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("array"),
            "description": .string(description),
            "items": items
        ]
        if let minItems {
            schema["minItems"] = .number(Double(minItems))
        }
        if let maxItems {
            schema["maxItems"] = .number(Double(maxItems))
        }
        return .object(schema)
    }

    public static func schemaBool(description: String) -> JSONValue {
        .object([
            "type": .string("boolean"),
            "description": .string(description)
        ])
    }
}
