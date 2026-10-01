import CoreML
import Testing
@testable import CopilotSpeech

@Test func promptRowsAreRemovedWithoutChangingTokenAudioAlignment() throws {
    // Rows 0 and 1 represent previous-text context; actual speech starts at row 2.
    let cache = try MLMultiArray(shape: [5, 3], dataType: .float32)
    for row in 0..<5 {
        for column in 0..<3 { cache[[NSNumber(value: row), NSNumber(value: column)]] = NSNumber(value: row * 10 + column) }
    }
    let actual = try PromptAlignedSegmentSeeker.removingLeadingRows(2, from: cache)
    #expect(actual.shape.map(\.intValue) == [3, 3])
    #expect(actual[[0, 0]].intValue == 20)
    #expect(actual[[2, 2]].intValue == 42)
    #expect(cache[[0, 0]].intValue == 0)
    let unchanged = try PromptAlignedSegmentSeeker.removingLeadingRows(0, from: cache)
    #expect(unchanged === cache)
}
