import Testing
import Foundation
@testable import CopilotCore

@Test func recognitionMetricsCountSubstitutionDeletionAndInsertion() {
    let result = RecognitionMetrics(reference: "The pressure was 30, not 13.", hypothesis: "Pressure was 13 extra.", criticalTerms: ["not", "30"])
    #expect(result.referenceWords == 6)
    #expect(result.wordErrors == 4)
    #expect(result.missingCriticalTerms == ["not", "30"])
    let normalized = RecognitionMetrics(reference: "你好，世界！", hypothesis: "你好世界")
    #expect(normalized.characterErrorRate == 0)
}

@Test func emptyReferenceDoesNotProduceFalsePerfectMetric() {
    let result = RecognitionMetrics(reference: "", hypothesis: "hallucinated")
    #expect(result.wordErrorRate == nil)
    #expect(result.wordErrors == 1)
    #expect(result.characterErrorRate == nil)
}

@Test func criticalPhrasesDoNotMatchOppositePrefixesOrOtherNumbers() {
    let result = RecognitionMetrics(reference: "Reversible injury at 30 hours.",
        hypothesis: "Irreversible injury at 130 hours.", criticalTerms: ["reversible injury", "30 hours"])
    #expect(result.checkedCriticalTerms == ["reversible injury", "30 hours"])
    #expect(result.missingCriticalTerms == ["reversible injury", "30 hours"])
    #expect(!RecognitionMetrics.containsPhrase("do not prove", in: "do prove this, not that"))
    #expect(RecognitionMetrics.containsPhrase("do not prove", in: "These changes DO NOT prove necrosis."))
    #expect(RecognitionMetrics.containsPhrase("you're seeing", in: "changes you’re seeing"))
    #expect(!RecognitionMetrics.containsPhrase("", in: "anything"))
}

@Test func historicalMetricsDistinguishUncheckedCriticalTerms() throws {
    let current = RecognitionMetrics(reference: "irreversible", hypothesis: "a reversible", criticalTerms: ["irreversible"])
    var value = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
    value.removeValue(forKey: "checkedCriticalTerms")
    let old = try JSONDecoder().decode(RecognitionMetrics.self, from: JSONSerialization.data(withJSONObject: value))
    #expect(old.checkedCriticalTerms == nil)
    #expect(RecognitionMetrics(reference: "a", hypothesis: "a").checkedCriticalTerms == [])
}
