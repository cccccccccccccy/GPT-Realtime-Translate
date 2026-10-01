import Foundation
import Testing
import CopilotCore
@testable import CopilotSpeech

private struct AssetFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    var model: URL { root.appendingPathComponent("model", isDirectory: true) }
    var cache: URL { root.appendingPathComponent("cache", isDirectory: true) }
    init(vocabulary: Int = 51866, embedding: Int = 1280) throws {
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["model_type": "whisper", "vocab_size": vocabulary, "d_model": embedding])
        try data.write(to: model.appendingPathComponent("config.json"))
    }
    func writeTokenizer(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ModelAssets.tokenizerFiles { try Data("{}".utf8).write(to: folder.appendingPathComponent(name)) }
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

@Test func localModelMetadataSelectsVocabularyFamilyAndRejectsUnknownShapes() throws {
    let v3 = try AssetFixture(); defer { v3.clean() }
    #expect(try WhisperModelMetadata(folder: v3.model).tokenizerRepository == "openai/whisper-large-v3")
    let english = try AssetFixture(vocabulary: 51864, embedding: 384); defer { english.clean() }
    #expect(try WhisperModelMetadata(folder: english.model).tokenizerRepository == "openai/whisper-tiny.en")
    let invalid = try AssetFixture(vocabulary: 51866, embedding: 384); defer { invalid.clean() }
    #expect(throws: CopilotError.self) { try WhisperModelMetadata(folder: invalid.model) }
}

@Test func offlinePreparationRejectsMissingAndMalformedTokenizersBeforeModelLoading() async throws {
    let fixture = try AssetFixture(); defer { fixture.clean() }
    let metadata = try WhisperModelMetadata(folder: fixture.model)
    await #expect(throws: CopilotError.self) {
        try await ModelAssets.prepareTokenizer(modelFolder: fixture.model, root: fixture.cache,
                                               metadata: metadata, allowDownload: false, progress: { _ in })
    }
    let tokenizer = fixture.model.appendingPathComponent("Tokenizer")
    try fixture.writeTokenizer(tokenizer)
    await #expect(throws: CopilotError.self) {
        try await ModelAssets.prepareTokenizer(modelFolder: fixture.model, root: fixture.cache,
                                               metadata: metadata, allowDownload: false, progress: { _ in })
    }
    #expect(!FileManager.default.fileExists(atPath: fixture.cache.path))
}

@Test func incompleteBundledTokenizerIsNotSilentlyReplacedByCachedResources() throws {
    let fixture = try AssetFixture(); defer { fixture.clean() }
    let bundled = fixture.model.appendingPathComponent("Tokenizer")
    try fixture.writeTokenizer(bundled)
    try FileManager.default.removeItem(at: bundled.appendingPathComponent("tokenizer_config.json"))
    try fixture.writeTokenizer(fixture.cache.appendingPathComponent("models/openai/whisper-large-v3"))
    #expect(throws: CopilotError.self) {
        try ModelAssets.localTokenizerFolder(modelFolder: fixture.model, root: fixture.cache, repository: "openai/whisper-large-v3")
    }
}

@Test func tokenizerTamperingIsDetectedWithoutWritingInsideImportedModel() throws {
    let fixture = try AssetFixture(); defer { fixture.clean() }
    let tokenizer = fixture.root.appendingPathComponent("tokenizer")
    try fixture.writeTokenizer(tokenizer)
    let baseline = try ModelIntegrity.resourceBaseline(model: fixture.model, tokenizer: tokenizer, root: fixture.cache)
    try ModelIntegrity.record(baseline)
    #expect(!FileManager.default.fileExists(atPath: fixture.model.appendingPathComponent("researchcopilot-integrity.json").path))
    _ = try ModelIntegrity.resourceBaseline(model: fixture.model, tokenizer: tokenizer, root: fixture.cache)
    try Data("{\"changed\":true}".utf8).write(to: tokenizer.appendingPathComponent("tokenizer.json"))
    #expect(throws: CopilotError.self) {
        try ModelIntegrity.resourceBaseline(model: fixture.model, tokenizer: tokenizer, root: fixture.cache)
    }
}

@Test func cancelledPreparationCannotBecomeReadyOrStartRecognition() async throws {
    let provider = WhisperKitProvider()
    let fixture = try AssetFixture(); defer { fixture.clean() }
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await provider.prepare(model: "not-downloaded", folder: fixture.model.path,
            allowDownload: true, cacheDirectory: fixture.cache, progress: { _ in })
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    await #expect(throws: CopilotError.self) { try await provider.start(silence: 1, emit: { _ in }) }
    #expect(!FileManager.default.fileExists(atPath: fixture.cache.path))
}

@Test func cancellationAtPreparationProgressDoesNotFallThroughToDownload() async throws {
    let fixture = try AssetFixture(); defer { fixture.clean() }
    let provider = WhisperKitProvider()
    let task = Task {
        try await provider.prepare(model: "fixture", folder: fixture.model.path, allowDownload: true,
                                   cacheDirectory: fixture.cache) { _ in
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await provider.preparedResources == nil)
    #expect(!FileManager.default.fileExists(atPath: fixture.cache.appendingPathComponent("models").path))
}

@Test func aCachedDownloadMustMatchTheRequestedCommit() throws {
    let fixture = try AssetFixture(); defer { fixture.clean() }
    let snapshot = fixture.cache
    let metadata = snapshot.appendingPathComponent(".cache/huggingface/download/config.json.metadata")
    try FileManager.default.createDirectory(at: metadata.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: snapshot.appendingPathComponent("config.json"))
    try "old-commit\netag\n0\n".write(to: metadata, atomically: true, encoding: .utf8)
    #expect(throws: CopilotError.self) {
        try ModelAssets.verifyDownloadMetadata(snapshot: snapshot, files: ["config.json"], revision: "requested-commit")
    }
    try "requested-commit\netag\n0\n".write(to: metadata, atomically: true, encoding: .utf8)
    try ModelAssets.verifyDownloadMetadata(snapshot: snapshot, files: ["config.json"], revision: "requested-commit")
}
