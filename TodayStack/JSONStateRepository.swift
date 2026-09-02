import Foundation

public enum JSONRepositoryError: LocalizedError, Equatable {
    case malformed(URL, String)
    case unsupportedSchema(Int)

    public var errorDescription: String? {
        switch self {
        case .malformed:
            return "Daybud could not read state.json. The original file was preserved."
        case .unsupportedSchema(let version):
            return "Daybud does not support state schema version \(version). The original file was preserved."
        }
    }
}

/// A small, synchronous JSON repository. AppStore serializes access on the main actor;
/// the lock also protects callers that use the repository directly in tests or tools.
public final class JSONStateRepository: @unchecked Sendable {
    public let directoryURL: URL
    public let stateURL: URL
    public let todayURL: URL

    private let fileManager: FileManager
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directoryURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let directory = directoryURL ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".today-stack", isDirectory: true)
        self.directoryURL = directory
        self.stateURL = directory.appendingPathComponent("state.json")
        self.todayURL = directory.appendingPathComponent("today.json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    public func load() throws -> AppState {
        lock.lock()
        defer { lock.unlock() }

        guard fileManager.fileExists(atPath: stateURL.path) else {
            return AppState()
        }

        do {
            let data = try Data(contentsOf: stateURL)
            let storedVersion = try decoder.decode(SchemaEnvelope.self, from: data).schemaVersion
            guard storedVersion == 1 || storedVersion == AppState.currentSchemaVersion else {
                throw JSONRepositoryError.unsupportedSchema(storedVersion)
            }
            let state = try decoder.decode(AppState.self, from: data)
            guard state.schemaVersion == AppState.currentSchemaVersion else {
                throw JSONRepositoryError.unsupportedSchema(state.schemaVersion)
            }
            if storedVersion < AppState.currentSchemaVersion {
                try saveUnlocked(state)
            }
            return state
        } catch let error as JSONRepositoryError {
            throw error
        } catch {
            // Deliberately do not write an empty replacement here. The caller can
            // surface the error and the user's original state remains untouched.
            throw JSONRepositoryError.malformed(stateURL, error.localizedDescription)
        }
    }

    public func save(_ state: AppState) throws {
        lock.lock()
        defer { lock.unlock() }

        guard state.schemaVersion == AppState.currentSchemaVersion else {
            throw JSONRepositoryError.unsupportedSchema(state.schemaVersion)
        }

        try saveUnlocked(state)
    }

    private func saveUnlocked(_ state: AppState) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try encoder.encode(state)
        let temporaryURL = directoryURL.appendingPathComponent("state.json.\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporaryURL, options: .atomic)
            if fileManager.fileExists(atPath: stateURL.path) {
                _ = try fileManager.replaceItemAt(stateURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: stateURL)
            }
        } catch {
            // A failed write must not disturb an existing canonical state file.
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private struct SchemaEnvelope: Decodable {
        let schemaVersion: Int
    }

    public func readTodayFile() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard fileManager.fileExists(atPath: todayURL.path) else { return nil }
        return try Data(contentsOf: todayURL)
    }
}
