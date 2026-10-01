import Foundation
import Testing
@testable import CopilotCore

private struct DiagnosticProvider: TextModelProvider {
    func complete(_ request: TextRequest, onDelta: @escaping @Sendable (String) async -> Void) async throws -> String {
        switch request.schemaName {
        case "translation":
            return #"{"sourceIDs":["diagnostic-question"],"translation":"陈博士，请介绍如何通过组织学验证影像变化。"}"#
        case "analysis":
            // Valid JSON, deliberately incorrect addressee: the report must retain the response.
            return #"{"sourceIDs":["diagnostic-question"],"kind":"QUESTION","coreMeaning":"介绍验证计划","intent":"了解验证方式","requiresResponse":false,"addressee":"other","reason":"错误的测试分类"}"#
        case "answer":
            throw CopilotError.message("Synthetic transport failure")
        default:
            return #"{"topics":[],"questions":[{"text":"专家询问验证计划","sourceIDs":["diagnostic-question"],"owner":null,"deadline":null}],"actualAnswers":[{"text":"本人介绍与组织学比较的计划","sourceIDs":["diagnostic-actual-answer"],"owner":null,"deadline":null}],"decisions":[],"actions":[],"unresolved":[]}"#
        }
    }
}

private actor DiagnosticResults {
    var values: [TextDiagnosticResult] = []
    func append(_ value: TextDiagnosticResult) { values.append(value) }
}

@Test func diagnosticsRetainFailuresAndStillExerciseSubsequentTasks() async throws {
    let recorder = DiagnosticResults()
    try await TextServiceDiagnostics.run(configuration: .init(kind: .deepSeek),
                                        service: .init(provider: DiagnosticProvider())) { await recorder.append($0) }
    let results = await recorder.values
    #expect(results.map(\.id) == ["translation", "analysis", "answer", "summary"])
    #expect(results[0].failure == nil)
    #expect(results[1].failure != nil)
    #expect(results[1].responseJSON?.contains("other") == true)
    #expect(results[2].failure == "Synthetic transport failure")
    #expect(results[3].failure == nil)
}
