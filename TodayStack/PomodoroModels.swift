import Foundation

public struct PomodoroSettings: Codable, Equatable, Hashable, Sendable {
    public static let defaultFocusDurationSeconds = 25 * 60
    public static let defaultExtensionDurationSeconds = 25 * 60

    private var storedFocusDurationSeconds: Int
    private var storedExtensionDurationSeconds: Int

    public var focusDurationSeconds: Int {
        get { storedFocusDurationSeconds }
        set { storedFocusDurationSeconds = max(1, newValue) }
    }

    public var extensionDurationSeconds: Int {
        get { storedExtensionDurationSeconds }
        set { storedExtensionDurationSeconds = max(1, newValue) }
    }

    public init(
        focusDurationSeconds: Int = PomodoroSettings.defaultFocusDurationSeconds,
        extensionDurationSeconds: Int = PomodoroSettings.defaultExtensionDurationSeconds
    ) {
        storedFocusDurationSeconds = max(1, focusDurationSeconds)
        storedExtensionDurationSeconds = max(1, extensionDurationSeconds)
    }

    private enum CodingKeys: String, CodingKey {
        case focusDurationSeconds
        case extensionDurationSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let focusDurationSeconds = try container.decode(Int.self, forKey: .focusDurationSeconds)
        let extensionDurationSeconds = try container.decode(Int.self, forKey: .extensionDurationSeconds)

        guard focusDurationSeconds > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .focusDurationSeconds,
                in: container,
                debugDescription: "Focus duration must be greater than zero"
            )
        }
        guard extensionDurationSeconds > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .extensionDurationSeconds,
                in: container,
                debugDescription: "Extension duration must be greater than zero"
            )
        }

        storedFocusDurationSeconds = focusDurationSeconds
        storedExtensionDurationSeconds = extensionDurationSeconds
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(focusDurationSeconds, forKey: .focusDurationSeconds)
        try container.encode(extensionDurationSeconds, forKey: .extensionDurationSeconds)
    }
}

/// A stable snapshot of the task a focus session was started from.
///
/// `occurrenceID` identifies the task on one day. `lineageID` stays stable when
/// an unfinished task is carried to another day, allowing statistics to group
/// those occurrences without losing the original title and habit snapshots.
public struct FocusTaskReference: Codable, Equatable, Hashable, Sendable {
    public let occurrenceID: String
    public let lineageID: String
    public let dateKey: String
    public let titleSnapshot: String
    public let habitIDSnapshot: String?
    public let habitNameSnapshot: String?

    public init(
        occurrenceID: String,
        lineageID: String,
        dateKey: String,
        titleSnapshot: String,
        habitIDSnapshot: String? = nil,
        habitNameSnapshot: String? = nil
    ) {
        self.occurrenceID = occurrenceID
        self.lineageID = lineageID
        self.dateKey = dateKey
        self.titleSnapshot = titleSnapshot
        self.habitIDSnapshot = habitIDSnapshot
        self.habitNameSnapshot = habitNameSnapshot
    }
}

/// Durable aggregate for one focus session, including all of its extensions.
public struct FocusRun: Codable, Equatable, Identifiable, Hashable, Sendable {
    public let id: String
    public let task: FocusTaskReference
    public let startedAt: Date
    public internal(set) var focusedSeconds: Int
    public internal(set) var extensionCount: Int

    public init(
        id: String,
        task: FocusTaskReference,
        startedAt: Date,
        focusedSeconds: Int = 0,
        extensionCount: Int = 0
    ) {
        self.id = id
        self.task = task
        self.startedAt = startedAt
        self.focusedSeconds = max(0, focusedSeconds)
        self.extensionCount = max(0, extensionCount)
    }
}

/// The only valid persisted phases for a timer that has not been archived.
public enum ActiveFocusTimer: Codable, Equatable, Hashable, Sendable {
    case running(
        run: FocusRun,
        intervalStartedAt: Date,
        deadline: Date,
        cycleDurationSeconds: Int,
        cycleFocusedSeconds: Int
    )
    case paused(
        run: FocusRun,
        remainingSeconds: Int,
        cycleDurationSeconds: Int,
        cycleFocusedSeconds: Int,
        pausedAt: Date
    )
    case awaitingDecision(run: FocusRun, reachedAt: Date)
}

public enum FocusOutcome: String, Codable, Equatable, Hashable, Sendable {
    case completedTask
    case stopped
}

public struct FocusRecord: Codable, Equatable, Identifiable, Hashable, Sendable {
    public let id: String
    public let task: FocusTaskReference
    public let startedAt: Date
    public let endedAt: Date
    public let focusedSeconds: Int
    public let extensionCount: Int
    public let outcome: FocusOutcome

    public init(
        id: String,
        task: FocusTaskReference,
        startedAt: Date,
        endedAt: Date,
        focusedSeconds: Int,
        extensionCount: Int,
        outcome: FocusOutcome
    ) {
        self.id = id
        self.task = task
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.focusedSeconds = max(0, focusedSeconds)
        self.extensionCount = max(0, extensionCount)
        self.outcome = outcome
    }
}

public struct PomodoroState: Codable, Equatable, Sendable {
    public var settings: PomodoroSettings
    public var activeTimer: ActiveFocusTimer?
    public var records: [FocusRecord]

    public init(
        settings: PomodoroSettings = PomodoroSettings(),
        activeTimer: ActiveFocusTimer? = nil,
        records: [FocusRecord] = []
    ) {
        self.settings = settings
        self.activeTimer = activeTimer
        self.records = records
    }
}

/// Ephemeral UI state derived from persisted timer state and an injected clock.
public enum FocusPresentation: Codable, Equatable, Sendable {
    case idle
    case running(
        task: FocusTaskReference,
        remainingSeconds: Int,
        focusedSeconds: Int,
        cycleProgress: Double,
        extensionCount: Int
    )
    case paused(
        task: FocusTaskReference,
        remainingSeconds: Int,
        focusedSeconds: Int,
        cycleProgress: Double,
        extensionCount: Int
    )
    case awaitingDecision(task: FocusTaskReference, focusedSeconds: Int, extensionCount: Int)
}
