import Foundation

/// A tool that the LLM can invoke.
protocol ToolDefinition {
    var name: String { get }
    var description: String { get }
    var parameters: [String: Any] { get } // JSON Schema for parameters

    func execute(arguments: String) async throws -> String
}

extension ToolDefinition {
    /// Converts this tool into the OpenAI-compatible function schema format.
    func toAPISchema() -> [String: AnyCodable] {
        return [
            "type": AnyCodable("function"),
            "function": AnyCodable([
                "name": AnyCodable(name),
                "description": AnyCodable(description),
                "parameters": AnyCodable(parameters)
            ] as [String: AnyCodable])
        ]
    }

    /// Helper to parse JSON arguments string into a dictionary.
    func parseArguments(_ arguments: String) throws -> [String: Any] {
        guard let data = arguments.data(using: .utf8),
              let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExecuterError.invalidArguments("Failed to parse JSON: \(arguments)")
        }
        return dict
    }

    /// Helper to get a required string parameter.
    func requiredString(_ key: String, from args: [String: Any]) throws -> String {
        guard let value = args[key] as? String else {
            throw ExecuterError.invalidArguments("Missing required parameter: \(key)")
        }
        return value
    }

    /// Helper to get an optional string parameter.
    func optionalString(_ key: String, from args: [String: Any]) -> String? {
        args[key] as? String
    }

    /// Helper to get an optional int parameter.
    func optionalInt(_ key: String, from args: [String: Any]) -> Int? {
        if let val = args[key] as? Int { return val }
        if let val = args[key] as? Double { return Int(val) }
        if let val = args[key] as? String, let num = Int(val) { return num }
        return nil
    }

    /// Helper to get a required double parameter.
    func requiredDouble(_ key: String, from args: [String: Any]) throws -> Double {
        if let val = args[key] as? Double { return val }
        if let val = args[key] as? Int { return Double(val) }
        if let val = args[key] as? String, let num = Double(val) { return num }
        throw ExecuterError.invalidArguments("Missing required parameter: \(key)")
    }

    /// Helper to get an optional double parameter.
    func optionalDouble(_ key: String, from args: [String: Any]) -> Double? {
        if let val = args[key] as? Double { return val }
        if let val = args[key] as? Int { return Double(val) }
        if let val = args[key] as? String, let num = Double(val) { return num }
        return nil
    }

    /// Helper to get an optional bool parameter.
    func optionalBool(_ key: String, from args: [String: Any]) -> Bool? {
        args[key] as? Bool
    }
}

/// JSON Schema helpers for tool parameter definitions.
enum JSONSchema {
    static func object(properties: [String: Any], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = [
            "type": "object",
            "properties": properties
        ]
        if !required.isEmpty {
            schema["required"] = required
        }
        return schema
    }

    static func string(description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    static func integer(description: String, minimum: Int? = nil, maximum: Int? = nil) -> [String: Any] {
        var schema: [String: Any] = ["type": "integer", "description": description]
        if let min = minimum { schema["minimum"] = min }
        if let max = maximum { schema["maximum"] = max }
        return schema
    }

    static func boolean(description: String) -> [String: Any] {
        ["type": "boolean", "description": description]
    }

    static func number(description: String) -> [String: Any] {
        ["type": "number", "description": description]
    }

    static func array(items: [String: Any], description: String) -> [String: Any] {
        ["type": "array", "items": items, "description": description]
    }

    static func enumString(description: String, values: [String]) -> [String: Any] {
        ["type": "string", "description": description, "enum": values]
    }
}
