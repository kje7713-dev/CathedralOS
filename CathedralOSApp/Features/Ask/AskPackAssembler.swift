import Foundation

struct AskPackAssembler {
    static func assemble(contextExport: String, question: String) -> String {
        return contextExport + "\n\nUSER QUESTION:\n" + question
    }
}
