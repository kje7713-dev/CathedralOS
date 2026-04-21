import Foundation

extension String {
    /// Returns `nil` if the string is empty, otherwise returns `self`.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension Optional where Wrapped == String {
    /// Returns `nil` if the wrapped string is empty or the optional itself is `nil`.
    var nilIfEmpty: String? {
        guard let self else { return nil }
        return self.isEmpty ? nil : self
    }
}
