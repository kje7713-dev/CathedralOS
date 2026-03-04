import XCTest
@testable import CathedralOSApp

final class AskPackAssemblerTests: XCTestCase {

    func testAssembledOutputContainsContextExport() {
        let context = "ROLES:\n- (none yet)"
        let question = "What should I focus on today?"

        let output = AskPackAssembler.assemble(contextExport: context, question: question)

        XCTAssertTrue(output.hasPrefix(context), "Output must begin with the context export")
    }

    func testAssembledOutputContainsUserQuestionLabel() {
        let context = "ROLES:\n- (none yet)"
        let question = "What should I focus on today?"

        let output = AskPackAssembler.assemble(contextExport: context, question: question)

        XCTAssertTrue(output.contains("USER QUESTION:"), "Output must contain 'USER QUESTION:' label")
    }

    func testAssembledOutputContainsQuestionText() {
        let context = "ROLES:\n- (none yet)"
        let question = "What should I focus on today?"

        let output = AskPackAssembler.assemble(contextExport: context, question: question)

        XCTAssertTrue(output.contains(question), "Output must contain the user's question text")
    }

    func testAssembledOutputFormatting() {
        let context = "CONTEXT"
        let question = "My Question"

        let output = AskPackAssembler.assemble(contextExport: context, question: question)

        XCTAssertEqual(output, "CONTEXT\n\nUSER QUESTION:\nMy Question",
                       "Output must follow: context + blank line + USER QUESTION: + question")
    }

    func testContextExportAppearsBeforeUserQuestionLabel() {
        let context = "ROLES:\n- Developer"
        let question = "How should I prioritize?"

        let output = AskPackAssembler.assemble(contextExport: context, question: question)
        let contextEnd = try! XCTUnwrap(output.range(of: context)).upperBound
        let labelStart = try! XCTUnwrap(output.range(of: "USER QUESTION:")).lowerBound

        XCTAssertLessThan(contextEnd, labelStart,
                          "Context export must appear before the USER QUESTION: label")
    }
}
