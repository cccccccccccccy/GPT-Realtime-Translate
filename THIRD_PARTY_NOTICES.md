# Third-party notices

ResearchCopilot uses the WhisperKit library product from [Argmax OSS Swift](https://github.com/argmaxinc/argmax-oss-swift), pinned to 1.1.0, revision `1e2a163736dfa5a198e637ae44c114e1c6d5cc2d`. The upstream project is distributed under the MIT license, with additional third-party notices in its repository. The build does not depend on WhisperKit Pro.

Swift Package Manager also resolves [swift-argument-parser](https://github.com/apple/swift-argument-parser) as an upstream package dependency; see `Package.resolved` for the exact version. ResearchCopilot does not link the Argmax command-line product.

Model weights are downloaded separately by the user through the model preparation workflow. Model licenses and access policies are separate from library code licenses. Verify the selected model's documentation before redistribution.

`Sources/CopilotSpeech/LocalWhisperTokenizer.swift` adapts the WhisperKit 1.1.0 MIT-licensed word-splitting logic (Copyright 2024 Argmax, Inc.). It uses the public local tokenizer factory to avoid implicit network fallback and validates required vocabulary tokens. The upstream MIT license is included in `Resources/Licenses` and the built app.

This app has no affiliation with Zoom, OpenAI, DeepSeek, Argmax, or OpenCode. Provider names identify interoperable services.
