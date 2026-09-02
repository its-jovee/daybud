import CryptoKit
import Foundation

public enum TodayImportError: LocalizedError, Equatable {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message):
            return "today.json is invalid: \(message)"
        }
    }
}

public struct TodayImportResult: Equatable, Sendable {
    public let state: AppState
    public let changed: Bool

    public init(state: AppState, changed: Bool) {
        self.state = state
        self.changed = changed
    }
}

public enum TodayImportService {
    private static let decoder = JSONDecoder()

    public static func parse(_ data: Data) throws -> TodayImportFile {
        do {
            let file = try decoder.decode(TodayImportFile.self, from: data)
            try validate(file)
            return file
        } catch let error as TodayImportError {
            throw error
        } catch {
            throw TodayImportError.invalid(error.localizedDescription)
        }
    }

    public static func applying(data: Data, to state: AppState, calendar: Calendar = .current) throws -> TodayImportResult {
        let file = try parse(data)
        return try applying(file: file, to: state, calendar: calendar)
    }

    public static func applying(file: TodayImportFile, to state: AppState, calendar: Calendar = .current) throws -> TodayImportResult {
        try validate(file)
        guard let date = DateKey.normalized(file.date, calendar: calendar) else {
            throw TodayImportError.invalid("date must use yyyy-MM-dd")
        }

        let oldPlan = state.days[date]
        let oldTasksByID = Dictionary(uniqueKeysWithValues: (oldPlan?.tasks ?? []).map { ($0.id, $0) })
        var seenIDs = Set<String>()
        var importedTasks: [TaskItem] = []
        importedTasks.reserveCapacity(file.tasks.count)

        for (index, imported) in file.tasks.enumerated() {
            let title = imported.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                throw TodayImportError.invalid("task titles cannot be empty")
            }

            let id: String
            if let suppliedID = imported.id?.trimmingCharacters(in: .whitespacesAndNewlines), !suppliedID.isEmpty {
                id = suppliedID
            } else {
                // Deterministic UUID generation means a repeated unchanged file is
                // a no-op while still producing a real UUID for an ID-less task.
                id = generatedID(date: date, index: index, title: title, habitSlug: imported.habitSlug)
            }
            guard seenIDs.insert(id).inserted else {
                throw TodayImportError.invalid("task IDs must be unique")
            }

            let habitID = imported.habitSlug.flatMap { slug in
                state.habits.first(where: { $0.slug == slug })?.id
            }
            let existingTask = oldTasksByID[id]
            let isCompleted = existingTask?.isCompleted ?? false
            importedTasks.append(TaskItem(
                id: id,
                lineageID: existingTask?.lineageID,
                title: title,
                habitID: habitID,
                isCompleted: isCompleted
            ))
        }

        var newState = state
        newState.days[date] = DayPlan(date: date, tasks: importedTasks)

        // Replace task-created sessions for incoming IDs while retaining the
        // original session ID when the linked habit is unchanged. Sessions for
        // omitted tasks are left in history, as habit activity is historical data.
        let incomingIDs = Set(importedTasks.map(\.id))
        let oldSessions = state.sessions
        var replacementByTaskID: [String: HabitSession] = [:]
        for task in importedTasks where task.isCompleted {
            guard let habitID = task.habitID else { continue }
            if let existing = oldSessions.first(where: {
                $0.date == date && $0.taskID == task.id && $0.habitID == habitID
            }) {
                replacementByTaskID[task.id] = existing
            } else {
                replacementByTaskID[task.id] = HabitSession(habitID: habitID, date: date, taskID: task.id, source: .task)
            }
        }

        var reconciledSessions: [HabitSession] = []
        var insertedTaskIDs = Set<String>()
        for session in oldSessions {
            guard session.date == date, let taskID = session.taskID, incomingIDs.contains(taskID) else {
                reconciledSessions.append(session)
                continue
            }
            if insertedTaskIDs.insert(taskID).inserted, let replacement = replacementByTaskID[taskID] {
                reconciledSessions.append(replacement)
            }
        }
        for task in importedTasks where replacementByTaskID[task.id] != nil && !insertedTaskIDs.contains(task.id) {
            reconciledSessions.append(replacementByTaskID[task.id]!)
        }
        newState.sessions = reconciledSessions

        return TodayImportResult(state: newState, changed: newState != state)
    }

    private static func validate(_ file: TodayImportFile) throws {
        guard file.schemaVersion == TodayImportFile.currentSchemaVersion else {
            throw TodayImportError.invalid("unsupported schemaVersion")
        }
        guard file.mode == "replace" else {
            throw TodayImportError.invalid("only mode=replace is supported")
        }
        guard DateKey.normalized(file.date, calendar: .current) != nil else {
            throw TodayImportError.invalid("date must use yyyy-MM-dd")
        }
    }

    private static func generatedID(date: String, index: Int, title: String, habitSlug: String?) -> String {
        let seed = "\(date)|\(index)|\(title)|\(habitSlug ?? "")"
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50 // UUID version 5 shape
        bytes[8] = (bytes[8] & 0x3f) | 0x80 // RFC 4122 variant
        func hex(_ range: Range<Int>) -> String {
            range.map { String(format: "%02x", bytes[$0]) }.joined()
        }
        return "\(hex(0..<4))-\(hex(4..<6))-\(hex(6..<8))-\(hex(8..<10))-\(hex(10..<16))"
    }
}
