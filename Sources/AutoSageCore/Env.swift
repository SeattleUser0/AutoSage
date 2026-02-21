import Foundation

public func parsePort(_ value: String?) -> Int? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return nil
    }
    guard let port = Int(value), (1...65535).contains(port) else {
        return nil
    }
    return port
}

public func parsePositiveInt(_ value: String?) -> Int? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return nil
    }
    guard let parsed = Int(value), parsed > 0 else {
        return nil
    }
    return parsed
}
