import Foundation
import CopilotCore

extension MeetingController {
    static func forApplication() -> MeetingController {
        #if DEBUG
        if Bundle.main.object(forInfoDictionaryKey: "ResearchCopilotUIReview") as? Bool == true {
            return MeetingController(reviewOnly: true, repositoryFactory: {
                guard Bundle.main.bundleIdentifier == "org.researchcopilot.review",
                      let file = Bundle.main.url(forResource: "UIReviewMeeting", withExtension: "json") else {
                    throw CopilotError.message("界面验证材料缺失；未访问个人存储。")
                }
                return try UIReviewStorage(file: file)
            })
        }
        #endif
        return MeetingController()
    }
}

#if DEBUG
/// Isolated, synthetic UI validation. Never reads Keychain or the user's meeting directory.
private actor UIReviewStorage: MeetingStorage {
    private var records: [UUID: MeetingSession]
    init(file: URL) throws {
        let meeting = try JSONDecoder().decode(MeetingSession.self, from: Data(contentsOf: file))
        records = [meeting.id: meeting]
    }
    func save(_ meeting: MeetingSession) { records[meeting.id] = meeting }
    func load(_ id: UUID) throws -> MeetingSession {
        guard let meeting = records[id] else { throw CopilotError.message("验证记录不存在。") }
        return meeting
    }
    func listIDs() -> [UUID] { records.keys.sorted { $0.uuidString < $1.uuidString } }
    func delete(_ id: UUID) { records.removeValue(forKey: id) }
    func saveConfiguration(_ configuration: AppConfiguration) {}
    func loadConfiguration() -> AppConfiguration? { AppConfiguration() }
    func saveProfile(_ profile: ResearchProfile) {}
    func loadProfile() -> ResearchProfile? { records.values.first?.profile }
}
#endif
