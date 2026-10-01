import Foundation
@preconcurrency import WhisperKit
import CopilotCore

struct WhisperModelMetadata: Sendable {
    let vocabularySize: Int
    let embeddingSize: Int
    let tokenizerRepository: String
    var isMultilingual: Bool { vocabularySize != 51864 }

    init(folder: URL) throws {
        let data = try Data(contentsOf: folder.appendingPathComponent("config.json"))
        guard data.count <= 1_048_576,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["model_type"] as? String == "whisper",
              let vocabulary = object["vocab_size"] as? Int, let embedding = object["d_model"] as? Int,
              [51864, 51865, 51866].contains(vocabulary) else {
            throw CopilotError.message("模型 config.json 缺少受支持的 Whisper 词表与维度信息。")
        }
        vocabularySize = vocabulary; embeddingSize = embedding
        if vocabulary == 51866 {
            guard embedding == 1280 else { throw CopilotError.message("模型配置的词表与维度不匹配。") }
            tokenizerRepository = "openai/whisper-large-v3"
        } else {
            let family: String
            switch embedding {
            case 384: family = "tiny"
            case 512: family = "base"
            case 768: family = "small"
            case 1024: family = "medium"
            case 1280 where vocabulary == 51865: family = "large-v2"
            default: throw CopilotError.message("不支持此语音模型维度，请选择兼容的 WhisperKit 模型。")
            }
            tokenizerRepository = "openai/whisper-" + family + (vocabulary == 51864 ? ".en" : "")
        }
    }
}

enum ModelAssets {
    static let modelRepository = "argmaxinc/whisperkit-coreml"
    // Commits recorded from all files of the successfully downloaded and tested default assets.
    static let modelRevision = "0f63a7800b00dd0226abd051b906c246e1907482"
    static let largeV3TokenizerRevision = "06f233fe06e710322aca913c1bc4249a0d71fce1"
    static let tokenizerFiles = ["config.json", "tokenizer.json", "tokenizer_config.json"]

    static func downloadModel(_ model: String, root: URL,
                              progress: @escaping @Sendable (Progress) -> Void) async throws -> URL {
        try Task.checkCancellation()
        guard !model.isEmpty, model.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else {
            throw CopilotError.message("模型标识只能包含字母、数字、点、连字符和下划线。")
        }
        let hub = HubApiWrapper(downloadBase: root)
        let repo = HubApiWrapper.Repo(id: modelRepository)
        let names = try await hub.getFilenames(from: repo, revision: modelRevision, matching: ["*\(model)/*"])
        try Task.checkCancellation()
        let folders = Set(names.compactMap { $0.split(separator: "/").first.map(String.init) })
        let exact = folders.filter { $0 == model || $0 == "openai_whisper_\(model)" || $0 == "openai_whisper-\(model)" }
        let matches = exact.isEmpty ? folders : Set(exact)
        guard matches.count == 1, let folder = matches.first else {
            throw CopilotError.message("固定模型版本中未找到唯一匹配项，请输入完整模型标识或导入本地目录。")
        }
        let snapshot = try await hub.snapshot(from: repo, revision: modelRevision,
                                              matching: [folder + "/*"], progressHandler: progress)
        try Task.checkCancellation()
        try verifyDownloadMetadata(snapshot: snapshot, files: names.filter { $0.hasPrefix(folder + "/") }, revision: modelRevision)
        return snapshot.appendingPathComponent(folder, isDirectory: true)
    }

    static func tokenizerCandidates(modelFolder: URL, root: URL, repository: String) -> [URL] {
        var candidates = [modelFolder.appendingPathComponent("Tokenizer", isDirectory: true), modelFolder,
                          root.appendingPathComponent("models/" + repository, isDirectory: true)]
        // Recognize the existing Hub cache tree when importing a model downloaded by diagnostics.
        let models = modelFolder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if models.lastPathComponent == "models" {
            candidates.append(models.appendingPathComponent(repository, isDirectory: true))
        }
        return candidates
    }

    static func localTokenizerFolder(modelFolder: URL, root: URL, repository: String) throws -> URL? {
        for folder in tokenizerCandidates(modelFolder: modelFolder, root: root, repository: repository) {
            // config.json alone is normally the acoustic model config, not a bundled tokenizer.
            if ["tokenizer.json", "tokenizer_config.json"].contains(where: {
                FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
            }) {
                try validateTokenizerFiles(folder)
                return folder
            }
        }
        return nil
    }

    static func validateTokenizerFiles(_ folder: URL) throws {
        for name in tokenizerFiles {
            let file = folder.appendingPathComponent(name)
            guard FileManager.default.isReadableFile(atPath: file.path) else {
                throw CopilotError.message("本地分词资源不完整，缺少 \(name)。请导入完整 Tokenizer 目录后重试。")
            }
            let attributes = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard attributes.isRegularFile == true, let size = attributes.fileSize, size > 0, size <= 50_000_000 else {
                throw CopilotError.message("分词文件为空、过大或不是普通文件：\(name)")
            }
        }
    }

    static func prepareTokenizer(modelFolder: URL, root: URL, metadata: WhisperModelMetadata,
                                 allowDownload: Bool, progress: @escaping @Sendable (String) async -> Void)
        async throws -> (URL, LocalWhisperTokenizer) {
        try Task.checkCancellation()
        var folder = try localTokenizerFolder(modelFolder: modelFolder, root: root, repository: metadata.tokenizerRepository)
        if folder == nil {
            guard allowDownload else {
                throw CopilotError.message("缺少配套分词资源 \(metadata.tokenizerRepository)。请将 config.json、tokenizer.json、tokenizer_config.json 放入模型的 Tokenizer 子目录，或选择下载并准备；此次未联网。")
            }
            await progress("正在下载配套分词资源…")
            try Task.checkCancellation()
            let revision = try await tokenizerRevision(repository: metadata.tokenizerRepository)
            let downloaded = try await HubApiWrapper(downloadBase: root).snapshot(from: .init(id: metadata.tokenizerRepository),
                revision: revision, matching: tokenizerFiles)
            try verifyDownloadMetadata(snapshot: downloaded, files: tokenizerFiles, revision: revision)
            folder = downloaded
        }
        try Task.checkCancellation()
        guard let folder else { throw CopilotError.message("分词资源准备失败。") }
        try validateTokenizerFiles(folder)
        // This public factory parses local files and throws on errors. Never call the Hub fallback factory.
        let base: TokenizerWrapper
        do { base = try await AutoTokenizerWrapper.from(modelFolder: folder) }
        catch { throw CopilotError.message("本地分词文件无法解析，请重新导入完整资源。未自动下载替换文件。") }
        try Task.checkCancellation()
        return (folder, try LocalWhisperTokenizer(base: base, vocabularySize: metadata.vocabularySize))
    }

    private static func tokenizerRevision(repository: String) async throws -> String {
        if repository == "openai/whisper-large-v3" { return largeV3TokenizerRevision }
        // Other explicitly selected families resolve a commit before download, so one preparation cannot mix revisions.
        var request = URLRequest(url: URL(string: "https://huggingface.co/api/models/" + repository)!)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let revision = object["sha"] as? String,
              revision.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil else {
            throw CopilotError.message("无法确认配套分词资源版本，请稍后重试或离线导入。")
        }
        return revision
    }

    static func verifyDownloadMetadata(snapshot: URL, files: [String], revision: String) throws {
        guard !files.isEmpty else { throw CopilotError.message("下载未包含所需模型文件。") }
        for file in files {
            try Task.checkCancellation()
            let metadata = snapshot.appendingPathComponent(".cache/huggingface/download/" + file + ".metadata")
            let commit = try String(contentsOf: metadata, encoding: .utf8).split(separator: "\n").first.map(String.init)
            guard commit == revision, FileManager.default.isReadableFile(atPath: snapshot.appendingPathComponent(file).path) else {
                throw CopilotError.message("下载缓存与指定资源版本不一致，未启用。请重新准备资源。")
            }
        }
    }
}
