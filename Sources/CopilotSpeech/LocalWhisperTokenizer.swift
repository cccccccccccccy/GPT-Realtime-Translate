// Word splitting is adapted from WhisperKit 1.1.0, Copyright 2024 Argmax, Inc., MIT.
// See Resources/Licenses and THIRD_PARTY_NOTICES.md.
import Foundation
import NaturalLanguage
@preconcurrency import WhisperKit
import CopilotCore

/// Uses only Argmax's local-file tokenizer factory; no network fallback exists on this path.
/// The adapter is needed because WhisperTokenizerWrapper's initializer is not public in 1.1.0.
struct LocalWhisperTokenizer: WhisperTokenizer, Sendable {
    let base: TokenizerWrapper
    let specialTokens: SpecialTokens
    let allLanguageTokens: Set<Int>

    init(base: TokenizerWrapper, vocabularySize: Int) throws {
        self.base = base
        func required(_ token: String) throws -> Int {
            guard let id = base.convertTokenToId(token), id >= 0, id < vocabularySize else {
                throw CopilotError.message("分词资源缺少必要标记或与模型词表不匹配：\(token)")
            }
            return id
        }
        let whitespace = base.encode(text: " ", addSpecialTokens: false)
        guard whitespace.count == 1, let whitespaceToken = whitespace.first else { throw CopilotError.invalidResponse }
        let tokens = try SpecialTokens(endToken: required("<|endoftext|>"), englishToken: required("<|en|>"),
            noSpeechToken: required("<|nospeech|>"), noTimestampsToken: required("<|notimestamps|>"),
            specialTokenBegin: required("<|endoftext|>"), startOfPreviousToken: required("<|startofprev|>"),
            startOfTranscriptToken: required("<|startoftranscript|>"), timeTokenBegin: required("<|0.00|>"),
            transcribeToken: required("<|transcribe|>"), translateToken: required("<|translate|>"),
            whitespaceToken: whitespaceToken)
        specialTokens = tokens
        guard tokens.endToken == (vocabularySize == 51864 ? 50256 : 50257),
              tokens.timeTokenBegin == vocabularySize - 1501,
              try required("<|30.00|>") == vocabularySize - 1 else {
            throw CopilotError.message("分词资源与语音模型版本不匹配，请导入配套资源。")
        }
        allLanguageTokens = Set(Constants.languages.values.compactMap { base.convertTokenToId("<|\($0)|>") }
            .filter { $0 > tokens.specialTokenBegin })
    }

    func encode(text: String) -> [Int] { base.encode(text: text) }
    func decode(tokens: [Int]) -> String { base.decode(tokens: tokens) }
    func convertTokenToId(_ token: String) -> Int? { base.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { base.convertIdToToken(id) }

    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        let decodedFull = decode(tokens: tokenIds)
        var subwords: [String] = [], subTokens: [[Int]] = [], pending: [Int] = []
        for token in tokenIds {
            pending.append(token)
            let decoded = decode(tokens: pending)
            // A token can contain only part of a UTF-8 scalar. Keep it until decoding is complete.
            if !decoded.contains("\u{fffd}") || decodedFull.contains("\u{fffd}") {
                subwords.append(decoded); subTokens.append(pending); pending = []
            }
        }
        if !pending.isEmpty { subwords.append(decode(tokens: pending)); subTokens.append(pending) }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(decode(tokens: tokenIds.filter { $0 < specialTokens.specialTokenBegin }))
        let language = recognizer.dominantLanguage.flatMap { Locale(identifier: $0.rawValue).language.languageCode?.identifier }
        if ["zh", "ja", "th", "lo", "my", "yue"].contains(language) { return (subwords, subTokens) }
        var words: [String] = [], wordTokens: [[Int]] = []
        for (word, tokens) in zip(subwords, subTokens) {
            let special = (tokens.first ?? 0) >= specialTokens.specialTokenBegin
            let punctuation = UnicodeScalar(word.trimmingCharacters(in: .whitespaces)).map {
                CharacterSet.punctuationCharacters.contains($0)
            } ?? false
            if special || word.hasPrefix(" ") || punctuation || words.isEmpty {
                words.append(word); wordTokens.append(tokens)
            } else {
                words[words.count - 1] += word; wordTokens[wordTokens.count - 1] += tokens
            }
        }
        return (words, wordTokens)
    }
}
