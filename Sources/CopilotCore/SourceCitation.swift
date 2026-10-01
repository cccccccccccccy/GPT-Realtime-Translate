import Foundation

/// A citation distinguishes the evidence used for generation from the current transcript.
public struct SourceCitation: Identifiable, Sendable {
    public let id: String
    public let current: TranscriptSegment?
    public let snapshot: TranscriptSegment?
    public let expectedRevision: Int?
    public var changed: Bool {
        guard let current, let expectedRevision else { return false }
        return current.revision != expectedRevision
    }
    public var label: String {
        guard let segment = current ?? snapshot else { return "来源不可用" }
        let suffix = current == nil ? " · 来源不可用" : changed ? " · 已更正" : expectedRevision == nil ? " · 版本未记录" : ""
        return "\(MarkdownExport.timestamp(segment.start)) · \(segment.track.title)" + suffix
    }
}

public enum CitationResolver {
    public static func resolve(_ ids: [String], in meeting: MeetingSession,
                               references: [SourceReference] = [], snapshots: [TranscriptSegment]? = nil) -> [SourceCitation] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }.map { id in
            let snapshot = snapshots?.first { $0.id == id }
            return SourceCitation(id: id, current: meeting.segments.first { $0.id == id }, snapshot: snapshot,
                                  expectedRevision: snapshot?.revision ?? references.first { $0.id == id }?.revision)
        }
    }
}
