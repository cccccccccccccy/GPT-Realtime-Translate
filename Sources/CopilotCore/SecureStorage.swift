import Foundation
import Security
import CryptoKit

public struct CredentialStore: Sendable {
    private let service: String
    public init(service: String = "org.researchcopilot.credentials") { self.service = service }

    public func read(_ account: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Self.failure(status) }
        return result as? Data
    }

    public func write(_ data: Data, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query; add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw Self.failure(added) }
        } else if status != errSecSuccess { throw Self.failure(status) }
    }

    public func delete(_ account: String) throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.failure(status) }
    }

    public func apiKey(for configuration: TextProviderConfiguration) throws -> String {
        guard let data = try read(configuration.credentialAccount),
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { throw CopilotError.missingCredential }
        return value
    }

    private static func failure(_ status: OSStatus) -> CopilotError {
        .message("钥匙串访问失败（\(status)），请检查应用访问权限。")
    }
}

public protocol MeetingStorage: Sendable {
    func save(_ meeting: MeetingSession) async throws
    func load(_ id: UUID) async throws -> MeetingSession
    func delete(_ id: UUID) async throws
    func listIDs() async throws -> [UUID]
    func saveConfiguration(_ configuration: AppConfiguration) async throws
    func loadConfiguration() async throws -> AppConfiguration?
    func saveProfile(_ profile: ResearchProfile) async throws
    func loadProfile() async throws -> ResearchProfile?
}

public actor MeetingRepository: MeetingStorage {
    public let directory: URL
    private let key: SymmetricKey
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(directory: URL, key: SymmetricKey) throws {
        self.directory = directory; self.key = key
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        encoder.outputFormatting = [.sortedKeys]
    }

    public static func applicationDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true).appendingPathComponent("ResearchCopilot", isDirectory: true)
    }

    public static func openDefault(credentials: CredentialStore) throws -> MeetingRepository {
        let account = "local-storage-key-v1"
        let raw: Data
        if let stored = try credentials.read(account) {
            guard stored.count == 32 else { throw CopilotError.message("本地加密密钥格式异常，未覆盖原有数据。") }
            raw = stored
        } else {
            let directory = try applicationDirectory()
            if FileManager.default.fileExists(atPath: directory.path) {
                let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                guard !files.contains(where: { $0.pathExtension == "meeting" || $0.pathExtension == "encrypted" }) else {
                    throw CopilotError.message("发现已有加密记录，但钥匙串中缺少原密钥。请恢复原钥匙串后重试；未创建新密钥或覆盖记录。")
                }
            }
            raw = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            try credentials.write(raw, account: account)
        }
        return try MeetingRepository(directory: applicationDirectory(), key: SymmetricKey(data: raw))
    }

    public func save(_ meeting: MeetingSession) throws { try write(meeting, name: meeting.id.uuidString + ".meeting") }
    public func load(_ id: UUID) throws -> MeetingSession {
        let meeting: MeetingSession = try read(name: id.uuidString + ".meeting")
        guard meeting.schemaVersion == 1, meeting.id == id else {
            throw CopilotError.message("会议记录版本或标识不匹配，未修改原文件。")
        }
        return meeting
    }
    public func delete(_ id: UUID) throws { try FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString + ".meeting")) }

    public func listIDs() throws -> [UUID] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "meeting" }
            .sorted { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast >
                      (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast }
            .compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) }
    }

    public func saveConfiguration(_ configuration: AppConfiguration) throws { try write(configuration, name: "settings.encrypted") }
    public func loadConfiguration() throws -> AppConfiguration? {
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("settings.encrypted").path) else { return nil }
        return try read(name: "settings.encrypted")
    }
    public func saveProfile(_ profile: ResearchProfile) throws { try write(profile, name: "profile.encrypted") }
    public func loadProfile() throws -> ResearchProfile? {
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("profile.encrypted").path) else { return nil }
        return try read(name: "profile.encrypted")
    }

    private func write<T: Encodable>(_ object: T, name: String) throws {
        let clear = try encoder.encode(object)
        let sealed = try AES.GCM.seal(clear, using: key, authenticating: Data(name.utf8))
        guard let data = sealed.combined else { throw CopilotError.message("加密失败，文字记录尚未保存。") }
        let file = directory.appendingPathComponent(name)
        try data.write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func read<T: Decodable>(name: String) throws -> T {
        let sealed = try AES.GCM.SealedBox(combined: Data(contentsOf: directory.appendingPathComponent(name)))
        let clear = try AES.GCM.open(sealed, using: key, authenticating: Data(name.utf8))
        return try decoder.decode(T.self, from: clear)
    }
}
