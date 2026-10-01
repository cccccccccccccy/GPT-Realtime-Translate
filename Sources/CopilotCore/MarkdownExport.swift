import Foundation
import CryptoKit

public enum MarkdownExport {
    public static func render(_ meeting: MeetingSession) -> String {
        var lines = ["# " + escape(meeting.title), "", "开始时间：\(meeting.startedAt.formatted())", "",
                     "本人发言：" + (meeting.microphoneIncluded ? "曾开启麦克风采集；具体缺口见下方记录。" : "未采集，不能确认实际回答。"), ""]
        if !meeting.gaps.isEmpty {
            lines += ["## 记录缺口", ""]
            lines += meeting.gaps.map { "- \(timestamp($0.time))：\(escape($0.reason))" }
            lines += [""]
        }
        if let summary = meeting.summary {
            lines += ["## 会议总结", "", meeting.summaryStale ? "⚠️ 原文有更新，以下总结需要重新生成。" : "AI 根据实际记录整理；请核对重要结论。", ""]
            for (title, entries) in [("主题", summary.topics), ("专家问题", summary.questions), ("记录到的本人回答", summary.actualAnswers),
                                      ("明确决定", summary.decisions), ("待办", summary.actions), ("未解决问题", summary.unresolved)] {
                lines += ["### " + title, ""]
                if entries.isEmpty { lines += ["未记录到。", ""]; continue }
                for entry in entries {
                    lines += ["- " + escape(entry.text) + "（来源：" + citationLinks(entry.sourceIDs, meeting: meeting, snapshots: meeting.summaryEvidence) + "）"]
                    if title == "待办" { lines += ["  负责人：\(escape(entry.displayedOwner))；日期：\(escape(entry.displayedDeadline))"] }
                }
                lines += [""]
            }
            lines += changedEvidence(meeting.summaryEvidence, meeting: meeting)
        }
        lines += ["## 实际转写与翻译", "", "转写可能有误；远端音轨不代表已确认的说话人身份。", ""]
        for segment in meeting.segments {
            lines += ["<a id=\"\(anchor(segment.id))\"></a>", "", "### \(timestamp(segment.start)) · \(segment.track.title)", "",
                      "片段：\(escape(segment.id))；修订：\(segment.revision)" + (segment.isFinal ? "" : "；未确认片段"), "",
                      escape(segment.text), ""]
            if segment.timingApproximate == true { lines += ["时间定位说明：部分词语缺少独立时长，已借用相邻词定位；片段时间不精确。", ""] }
            if let translation = segment.translation { lines += ["译文：" + escape(translation), ""] }
        }
        if !meeting.profile.facts.isEmpty {
            lines += ["## 用户录入的研究信息（不代表会议发言）", ""]
            for fact in meeting.profile.facts {
                lines += ["- **\(fact.kind.title)**：\(escape(fact.content))", "  录入来源：\(escape(fact.origin))", ""]
            }
        }
        lines += ["## AI 回答建议（不代表实际发言）", ""]
        for answer in meeting.answers {
            lines += ["### " + escape(answer.content.coreQuestion), "",
                      "模型：\(escape(answer.provider)) / \(escape(answer.model))" + (answer.stale ? "；来源已更新" : ""), "",
                      escape(answer.content.english), "", escape(answer.content.chinese), "",
                      "来源：" + citationLinks(answer.sources.map(\.id), meeting: meeting, references: answer.sources, snapshots: answer.evidenceSegments), ""]
            lines += changedEvidence(answer.evidenceSegments, meeting: meeting)
            if let facts = answer.evidenceFacts, !facts.isEmpty {
                lines += ["生成时采用的研究信息：", ""]
                lines += facts.map { "- \($0.kind.title)：\(escape($0.content))（录入来源：\(escape($0.origin))）" }
                lines += [""]
            } else if !answer.content.factIDs.isEmpty && answer.evidenceFacts == nil {
                lines += ["旧记录未保存生成时的研究事实快照。", ""]
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func anchor(_ id: String) -> String {
        "transcript-" + SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func citationLinks(_ ids: [String], meeting: MeetingSession,
                                      references: [SourceReference] = [], snapshots: [TranscriptSegment]? = nil) -> String {
        CitationResolver.resolve(ids, in: meeting, references: references, snapshots: snapshots).map { citation in
            guard citation.current != nil else { return escape(citation.label) }
            return "[\(escape(citation.label))](#\(anchor(citation.id)))"
        }.joined(separator: "，")
    }

    private static func changedEvidence(_ snapshots: [TranscriptSegment]?, meeting: MeetingSession) -> [String] {
        let changed = (snapshots ?? []).filter { snapshot in
            !meeting.segments.contains { $0.reference == snapshot.reference }
        }
        guard !changed.isEmpty else { return [] }
        return ["生成时采用的旧版原文（当前记录已变化）：", ""] + changed.flatMap {
            ["- \(timestamp($0.start)) · \($0.track.title) · 修订 \($0.revision)：\(escape($0.text))", ""]
        }
    }

    public static func timestamp(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds.isFinite ? seconds : 0))
        return String(format: "%02d:%02d:%02d", whole / 3600, (whole / 60) % 60, whole % 60)
    }

    private static func escape(_ text: String) -> String {
        // Keep transcript text from injecting headings, HTML, image URLs or links into exported notes.
        var result = text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        for character in ["\\", "`", "*", "_", "[", "]", "#", "!"] {
            result = result.replacingOccurrences(of: character, with: "\\" + character)
        }
        return result.replacingOccurrences(of: "\n", with: "  \n")
    }
}
