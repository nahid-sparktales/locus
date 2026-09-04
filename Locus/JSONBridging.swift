import Foundation

/// Codable ⇄ JSON-dictionary bridging for payloads that arrive as decoded
/// JSON objects (backend events, fixtures) rather than raw data.
func decode<T: Decodable>(_ type: T.Type, from object: [String: Any]) -> T? {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object)
    else { return nil }
    return try? JSONDecoder().decode(type, from: data)
}

func encodedJSONObject<T: Encodable>(_ value: T) -> [String: Any]? {
    guard let data = try? JSONEncoder().encode(value) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

func encodedJSONValue<T: Encodable>(_ value: T) -> Any? {
    guard let data = try? JSONEncoder().encode(value) else { return nil }
    return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
}
