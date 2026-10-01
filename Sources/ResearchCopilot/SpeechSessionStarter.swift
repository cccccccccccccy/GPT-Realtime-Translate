import Foundation
import CopilotCore
import CopilotSpeech

@MainActor
protocol SpeechSessionStarting {
    func start(configuration: AppConfiguration, profile: ResearchProfile,
               local: WhisperKitProvider, localReady: Bool,
               emit: @escaping @Sendable (SpeechEvent) async -> Void) async throws -> any SpeechRecognitionProvider
}

/// Keeps production credential/model startup separate from capture lifecycle tests.
@MainActor
struct SpeechSessionStarter: SpeechSessionStarting {
    func start(configuration: AppConfiguration, profile: ResearchProfile,
               local: WhisperKitProvider, localReady: Bool,
               emit: @escaping @Sendable (SpeechEvent) async -> Void) async throws -> any SpeechRecognitionProvider {
        if configuration.speechProvider == .whisperKit {
            guard localReady else { throw CopilotError.message("请先在设置中准备本地语音模型。") }
            // ASR glossary prompts remain off after the recorded quality comparisons.
            try await local.start(silence: configuration.vadSilenceSeconds, emit: emit)
            return local
        }
        guard let data = try CredentialStore().read(OpenAITranscriptionProvider.credentialAccount),
              let key = String(data: data, encoding: .utf8) else { throw CopilotError.missingCredential }
        let cloud = OpenAITranscriptionProvider()
        try await cloud.start(key: key, model: configuration.openAISpeechModel,
                              microphone: configuration.captureMicrophone,
                              silence: configuration.vadSilenceSeconds,
                              terminology: profile.terminology, emit: emit)
        return cloud
    }
}
