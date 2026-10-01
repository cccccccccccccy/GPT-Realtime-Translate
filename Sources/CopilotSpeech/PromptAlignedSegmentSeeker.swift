import Foundation
import CoreML
@preconcurrency import WhisperKit
import CopilotCore

/// WhisperKit 1.1.0 strips the previous-text prompt from decodingResult.tokens but leaves
/// its rows in the alignment cache. Match the cache to those filtered tokens before DTW.
/// Keep this adapter tied to the pinned version and recheck the real-audio regression on upgrades.
final class PromptAlignedSegmentSeeker: SegmentSeeking {
    private let base = SegmentSeeker()

    func findSeekPointAndSegments(decodingResult: DecodingResult, options: DecodingOptions,
                                 allSegmentsCount: Int, currentSeek: Int, segmentSize: Int,
                                 sampleRate: Int, timeToken: Int, specialToken: Int,
                                 tokenizer: WhisperTokenizer) -> (Int, [TranscriptionSegment]?) {
        base.findSeekPointAndSegments(decodingResult: decodingResult, options: options,
            allSegmentsCount: allSegmentsCount, currentSeek: currentSeek, segmentSize: segmentSize,
            sampleRate: sampleRate, timeToken: timeToken, specialToken: specialToken, tokenizer: tokenizer)
    }

    func addWordTimestamps(segments: [TranscriptionSegment], alignmentWeights: MLMultiArray,
                           tokenizer: WhisperTokenizer, seek: Int, segmentSize: Int,
                           prependPunctuations: String, appendPunctuations: String,
                           lastSpeechTimestamp: Float, options: DecodingOptions,
                           timings: TranscriptionTimings) throws -> [TranscriptionSegment]? {
        let promptCount = options.usePrefillPrompt
            ? (options.promptTokens?.suffix(Constants.maxTokenContext / 2 - 1)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }.count ?? 0) : 0
        let offset = promptCount == 0 ? 0 : promptCount + 1 // <|startofprev|>
        let aligned = try Self.removingLeadingRows(offset, from: alignmentWeights)
        return try base.addWordTimestamps(segments: segments, alignmentWeights: aligned,
            tokenizer: tokenizer, seek: seek, segmentSize: segmentSize,
            prependPunctuations: prependPunctuations, appendPunctuations: appendPunctuations,
            lastSpeechTimestamp: lastSpeechTimestamp, options: options, timings: timings)
    }

    static func removingLeadingRows(_ offset: Int, from source: MLMultiArray) throws -> MLMultiArray {
        guard offset > 0 else { return source }
        guard source.shape.count == 2, source.strides[1].intValue == 1,
              source.shape[0].intValue > offset else { throw CopilotError.invalidResponse }
        let rows = source.shape[0].intValue - offset, columns = source.shape[1].intValue
        let bytes: Int
        switch source.dataType {
        case .float16: bytes = 2
        case .float32, .int32: bytes = 4
        case .double: bytes = 8
        default: throw CopilotError.invalidResponse
        }
        let result = try MLMultiArray(shape: [NSNumber(value: rows), NSNumber(value: columns)], dataType: source.dataType)
        source.withUnsafeMutableBytes { sourceBytes, sourceStrides in
            result.withUnsafeMutableBytes { resultBytes, resultStrides in
                for row in 0..<rows {
                    let from = sourceBytes.baseAddress!.advanced(by: (row + offset) * sourceStrides[0] * bytes)
                    let to = resultBytes.baseAddress!.advanced(by: row * resultStrides[0] * bytes)
                    memcpy(to, from, columns * bytes)
                }
            }
        }
        return result
    }
}
