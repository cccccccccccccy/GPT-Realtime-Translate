import Foundation

public struct RecognitionMetrics: Codable, Equatable, Sendable {
    public var wordErrors: Int
    public var referenceWords: Int
    public var wordErrorRate: Double?
    public var characterErrors: Int
    public var referenceCharacters: Int
    public var characterErrorRate: Double?
    public var missingCriticalTerms: [String]
    /// Nil in legacy reports; an empty list means no critical phrases were evaluated.
    public var checkedCriticalTerms: [String]?

    public init(reference: String, hypothesis: String, criticalTerms: [String] = []) {
        let expected = Self.words(reference), actual = Self.words(hypothesis)
        referenceWords = expected.count; wordErrors = Self.distance(expected, actual)
        wordErrorRate = expected.isEmpty ? nil : Double(wordErrors) / Double(expected.count)
        let referenceChars = Array(reference.lowercased().filter { $0.isLetter || $0.isNumber })
        let actualChars = Array(hypothesis.lowercased().filter { $0.isLetter || $0.isNumber })
        referenceCharacters = referenceChars.count; characterErrors = Self.distance(referenceChars, actualChars)
        characterErrorRate = referenceChars.isEmpty ? nil : Double(characterErrors) / Double(referenceChars.count)
        checkedCriticalTerms = criticalTerms
        missingCriticalTerms = criticalTerms.filter { !Self.containsPhrase($0, in: hypothesis) }
    }

    /// Literal contiguous word sequences, using the same normalization as WER.
    /// Substrings must not turn "irreversible" into evidence for "reversible", or "130" for "30".
    /// This checks wording only; it does not prove the phrase's meaning, scope or speaker attribution.
    public static func containsPhrase(_ phrase: String, in text: String) -> Bool {
        let expected = words(phrase), actual = words(text)
        guard !expected.isEmpty, expected.count <= actual.count else { return false }
        return (0...(actual.count - expected.count)).contains { start in
            actual[start..<(start + expected.count)].elementsEqual(expected)
        }
    }

    public static func words(_ text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+(?:[.'’-][\p{L}\p{N}]+)*"#)
        let value = text.lowercased().replacingOccurrences(of: "’", with: "'") as NSString
        return regex.matches(in: value as String, range: NSRange(location: 0, length: value.length)).map { value.substring(with: $0.range) }
    }

    private static func distance<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        var previous = Array(0...b.count)
        for (i, expected) in a.enumerated() {
            var current = [i + 1] + [Int](repeating: 0, count: b.count)
            for (j, actual) in b.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (expected == actual ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
