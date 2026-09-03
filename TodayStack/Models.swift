import Foundation

/// The two supported ways a habit can be evaluated.
public enum HabitFrequency: Codable, Hashable, Sendable {
    case daily
    case weeklyTarget(Int)

    private enum CodingKeys: String, CodingKey {
        case type
        case target
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "daily":
            self = .daily
        case "weeklyTarget":
            let target = try container.decode(Int.self, forKey: .target)
            guard (1...7).contains(target) else {
                throw DecodingError.dataCorruptedError(forKey: .target, in: container, debugDescription: "Weekly target must be between 1 and 7")
            }
            self = .weeklyTarget(target)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown habit frequency")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .daily:
            try container.encode("daily", forKey: .type)
        case .weeklyTarget(let target):
            try container.encode("weeklyTarget", forKey: .type)
            try container.encode(target, forKey: .target)
        }
    }

    public var label: String {
        switch self {
        case .daily:
            return "Daily"
        case .weeklyTarget(let target):
            return "\(target) days per week"
        }
    }
}

public struct TaskItem: Codable, Equatable, Identifiable, Hashable, Sendable {
    public let id: String
    /// Stable identity shared by each daily occurrence of a carried task.
    /// Pomodoro records use this to keep their relationship to the task even
    /// when an unfinished occurrence rolls into a new day with a fresh ID.
    public let lineageID: String
    public var title: String
    public var habitID: String?
    public var isCompleted: Bool

    public init(
        id: String = UUID().uuidString,
        lineageID: String? = nil,
        title: String,
        habitID: String? = nil,
        isCompleted: Bool = false
    ) {
        self.id = id
        self.lineageID = lineageID ?? id
        self.title = title
        self.habitID = habitID
        self.isCompleted = isCompleted
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case lineageID
        case title
        case habitID
        case isCompleted
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        lineageID = try container.decodeIfPresent(String.self, forKey: .lineageID) ?? id
        title = try container.decode(String.self, forKey: .title)
        habitID = try container.decodeIfPresent(String.self, forKey: .habitID)
        isCompleted = try container.decode(Bool.self, forKey: .isCompleted)
    }
}

public struct DayPlan: Codable, Equatable, Hashable, Sendable {
    public var date: String
    public var tasks: [TaskItem]

    public init(date: String, tasks: [TaskItem] = []) {
        self.date = date
        self.tasks = tasks
    }
}

public struct Habit: Codable, Equatable, Identifiable, Hashable, Sendable {
    public let id: String
    public var slug: String
    public var name: String
    public var frequency: HabitFrequency
    public var iconName: String?

    public init(
        id: String = UUID().uuidString,
        slug: String,
        name: String,
        frequency: HabitFrequency = .daily,
        iconName: String? = nil
    ) {
        self.id = id
        self.slug = slug
        self.name = name
        self.frequency = frequency
        self.iconName = iconName
    }
}

public enum HabitSessionSource: String, Codable, Hashable, Sendable {
    case manual
    case task
}

public struct HabitSession: Codable, Equatable, Identifiable, Hashable, Sendable {
    public let id: String
    public let habitID: String
    public let date: String
    /// A task ID is present only when completion created this session.
    public let taskID: String?
    public let source: HabitSessionSource

    public init(id: String = UUID().uuidString, habitID: String, date: String, taskID: String? = nil, source: HabitSessionSource? = nil) {
        self.id = id
        self.habitID = habitID
        self.date = date
        self.taskID = taskID
        self.source = source ?? (taskID == nil ? .manual : .task)
    }
}

public struct AppState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 3

    public var schemaVersion: Int
    public var days: [String: DayPlan]
    public var laterTasks: [TaskItem]
    public var habits: [Habit]
    public var sessions: [HabitSession]
    public var pomodoro: PomodoroState

    public init(
        schemaVersion: Int = AppState.currentSchemaVersion,
        days: [String: DayPlan] = [:],
        laterTasks: [TaskItem] = [],
        habits: [Habit] = [],
        sessions: [HabitSession] = [],
        pomodoro: PomodoroState = PomodoroState()
    ) {
        self.schemaVersion = schemaVersion
        self.days = days
        self.laterTasks = laterTasks
        self.habits = habits
        self.sessions = sessions
        self.pomodoro = pomodoro
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case days
        case laterTasks
        case habits
        case sessions
        case pomodoro
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard (1...Self.currentSchemaVersion).contains(storedVersion) else {
            schemaVersion = storedVersion
            days = [:]
            laterTasks = []
            habits = []
            sessions = []
            pomodoro = PomodoroState()
            return
        }

        schemaVersion = Self.currentSchemaVersion
        days = try container.decodeIfPresent([String: DayPlan].self, forKey: .days) ?? [:]
        laterTasks = try container.decodeIfPresent([TaskItem].self, forKey: .laterTasks) ?? []
        habits = try container.decodeIfPresent([Habit].self, forKey: .habits) ?? []
        sessions = try container.decodeIfPresent([HabitSession].self, forKey: .sessions) ?? []
        pomodoro = try container.decodeIfPresent(PomodoroState.self, forKey: .pomodoro) ?? PomodoroState()
    }
}

public struct ImportedTask: Codable, Equatable, Sendable {
    public var id: String?
    public var title: String
    public var habitSlug: String?

    public init(id: String? = nil, title: String, habitSlug: String? = nil) {
        self.id = id
        self.title = title
        self.habitSlug = habitSlug
    }
}

public struct TodayImportFile: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var date: String
    public var mode: String
    public var tasks: [ImportedTask]

    public init(schemaVersion: Int = TodayImportFile.currentSchemaVersion, date: String, mode: String = "replace", tasks: [ImportedTask] = []) {
        self.schemaVersion = schemaVersion
        self.date = date
        self.mode = mode
        self.tasks = tasks
    }
}

public enum DateKey {
    public static let format = "yyyy-MM-dd"

    public static func string(from date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    public static func date(from key: String, calendar: Calendar) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter.date(from: key)
    }

    public static func normalized(_ key: String, calendar: Calendar) -> String? {
        guard let date = date(from: key, calendar: calendar) else { return nil }
        return string(from: date, calendar: calendar)
    }
}
