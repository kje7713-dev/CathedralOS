import Foundation

enum ExportMode: String, CaseIterable, Identifiable {
    case json
    case instructions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .json: return "JSON"
        case .instructions: return "Instructions"
        }
    }
}
