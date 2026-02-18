import Foundation

public protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }
    var jsonSchema: JSONValue { get }
    func run(input: JSONValue?) -> JSONValue
}

public struct ToolRegistry {
    public let tools: [String: Tool]

    public init(tools: [Tool]) {
        var map: [String: Tool] = [:]
        for tool in tools {
            map[tool.name] = tool
        }
        self.tools = map
    }

    public func tool(named name: String) -> Tool? {
        tools[name]
    }

    public static let `default` = ToolRegistry(tools: [
        StubTool.feaSolve,
        StubTool.cfdSolve,
        StubTool.circuitsSimulate
    ])
}

public struct StubTool: Tool {
    public let name: String
    public let description: String
    public let jsonSchema: JSONValue

    public init(name: String, description: String, jsonSchema: JSONValue) {
        self.name = name
        self.description = description
        self.jsonSchema = jsonSchema
    }

    public func run(input: JSONValue?) -> JSONValue {
        let cappedValues: [Double] = Array([0.1, 0.2, 0.3, 0.4, 0.5].prefix(10))
        return .object([
            "status": .string("ok"),
            "solver": .string(name),
            "summary": .string("Stub result for \(name)."),
            "values": .numberArray(cappedValues)
        ])
    }

    public static let feaSolve = StubTool(
        name: "fea.solve",
        description: "Finite element analysis (stub).",
        jsonSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "mesh": .object([
                    "type": .string("string")
                ]),
                "materials": .object([
                    "type": .string("array"),
                    "items": .object([
                        "type": .string("string")
                    ])
                ])
            ])
        ])
    )

    public static let cfdSolve = StubTool(
        name: "cfd.solve",
        description: "Computational fluid dynamics (stub).",
        jsonSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "geometry": .object([
                    "type": .string("string")
                ]),
                "timestep": .object([
                    "type": .string("number")
                ])
            ])
        ])
    )

    public static let circuitsSimulate = StubTool(
        name: "circuits.simulate",
        description: "Circuit simulation (stub).",
        jsonSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "netlist": .object([
                    "type": .string("string")
                ]),
                "analysis": .object([
                    "type": .string("string")
                ])
            ])
        ])
    )
}
