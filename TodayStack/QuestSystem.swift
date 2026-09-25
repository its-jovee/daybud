import Foundation

public enum TaskPurpose: Codable, Equatable, Hashable, Sendable {
    case regular
    case sidequest
    case mainQuest(String)

    public var questID: String? {
        if case .mainQuest(let id) = self { return id }
        return nil
    }
}

public struct MainQuest: Codable, Equatable, Identifiable, Sendable {
    public enum Status: String, Codable, CaseIterable, Sendable { case active, completed, archived }
    public var id = UUID().uuidString
    public var title: String
    public var emoji = ""
    public var description = ""
    public var status: Status = .active
    public var deadline: Date?
    public var currentValue: Double = 0
    public var progressHighWater: Double = 0
    public var targetValue: Double?
    public var unit = ""
    public var createdAt = Date()
    public var completedAt: Date?

    public var progressLabel: String {
        guard let targetValue else { return "Next actions" }
        if unit.hasPrefix("$") {
            return "$\(currentValue.formatted()) / $\(targetValue.formatted()) \(unit.dropFirst().trimmingCharacters(in: .whitespaces))".trimmingCharacters(in: .whitespaces)
        }
        return "\(currentValue.formatted()) / \(targetValue.formatted()) \(unit)".trimmingCharacters(in: .whitespaces)
    }
}

public struct QuestReward: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var name: String
    public var emoji = ""
    public var price: Int
    public var description = ""
    public var isArchived = false

    public static let gaming = QuestReward(id: "default-gaming-hour", name: "1 hour gaming", emoji: "🎮", price: 60)
}

public struct CoinTransaction: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var amount: Int
    public var title: String
    public var date: String
    public var timestamp: Date
    public var rewardID: String?
}

public struct QuestActivity: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case mainAction, progress, completedQuest, sidequest }
    public var id = UUID().uuidString
    public var questID: String?
    public var kind: Kind
    public var title: String
    public var date: String
    public var timestamp: Date
    public var valueChange: Double = 0
    public var isMainProgress: Bool { kind != .sidequest }
}

public struct QuestState: Codable, Equatable, Sendable {
    public init() {}
    public var quests: [MainQuest] = []
    public var rewards: [QuestReward] = [.gaming]
    public var transactions: [CoinTransaction] = []
    public var activities: [QuestActivity] = []
    // Completion claims survive undo, reclassification, deletion and carryover.
    public var claimedTasks: Set<String> = []
    public var claimedHabitDays: Set<String> = []
    public var balance: Int { transactions.reduce(0) { $0 + $1.amount } }
    public var activeQuests: [MainQuest] { quests.filter { $0.status == .active } }
}

public enum QuestError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

public enum QuestEngine {
    public static let twoQuestMessage = "You already have two Main Quests. What stops being a Main Quest?"

    public static func saveQuest(_ quest: MainQuest, state: inout AppState) throws {
        guard !quest.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QuestError.invalid("Give your Main Quest a title.")
        }
        guard quest.currentValue.isFinite, quest.currentValue >= 0,
              quest.targetValue.map({ $0.isFinite && $0 > 0 }) ?? true else {
            throw QuestError.invalid("Use a positive target and a current value of zero or more.")
        }
        let existing = state.questSystem.quests.first { $0.id == quest.id }
        if quest.status == .active && existing?.status != .active && state.questSystem.activeQuests.count >= 2 {
            throw QuestError.invalid(twoQuestMessage)
        }
        // Progress and completion go through their ledger-aware commands, never the editor.
        if let existing {
            var edited = quest
            edited.currentValue = existing.currentValue
            edited.progressHighWater = existing.progressHighWater
            edited.status = existing.status
            edited.createdAt = existing.createdAt
            edited.completedAt = existing.completedAt
            state.questSystem.quests[state.questSystem.quests.firstIndex { $0.id == quest.id }!] = edited
        } else {
            guard quest.status == .active else { throw QuestError.invalid("New quests start active.") }
            var initial = quest
            initial.progressHighWater = quest.currentValue
            state.questSystem.quests.append(initial)
        }
    }

    public static func assign(taskID: String, purpose: TaskPurpose, date: String, state: inout AppState) throws {
        if let id = purpose.questID, !state.questSystem.activeQuests.contains(where: { $0.id == id }) {
            throw QuestError.invalid("Choose an active Main Quest.")
        }
        if let index = state.days[date]?.tasks.firstIndex(where: { $0.id == taskID }) {
            state.days[date]!.tasks[index].purpose = purpose
        } else if let index = state.laterTasks.firstIndex(where: { $0.id == taskID }) {
            state.laterTasks[index].purpose = purpose
        } else { throw QuestError.invalid("This task is no longer available.") }
    }

    public static func recordTask(_ task: TaskItem, date: String, now: Date, state: inout AppState) {
        guard task.isCompleted else { return }
        if state.questSystem.claimedTasks.insert(task.lineageID).inserted {
            let kind: QuestActivity.Kind?
            let amount: Int
            switch task.purpose {
            case .mainQuest(let id) where state.questSystem.activeQuests.contains(where: { $0.id == id }):
                kind = .mainAction; amount = 10
            case .sidequest: kind = .sidequest; amount = 2
            default: kind = nil; amount = 0
            }
            if let kind {
                state.questSystem.activities.append(QuestActivity(questID: task.purpose.questID, kind: kind, title: task.title, date: date, timestamp: now))
                award(id: "task:\(task.lineageID)", amount: amount, title: task.title, date: date, now: now, state: &state)
            }
        }
        if let habitID = task.habitID { recordHabit(habitID, date: date, now: now, state: &state) }
    }

    public static func recordHabit(_ id: String, date: String, now: Date, state: inout AppState) {
        guard let habit = state.habits.first(where: { $0.id == id }),
              state.questSystem.claimedHabitDays.insert("\(id):\(date)").inserted else { return }
        award(id: "habit:\(id):\(date)", amount: 1, title: habit.name, date: date, now: now, state: &state)
    }

    public static func updateProgress(id: String, value: Double, date: String, now: Date, state: inout AppState) throws {
        guard let index = state.questSystem.quests.firstIndex(where: { $0.id == id && $0.status == .active }),
              state.questSystem.quests[index].targetValue != nil else { throw QuestError.invalid("Choose an active quest with a measurable target.") }
        guard value.isFinite, value >= 0 else { throw QuestError.invalid("Enter a number of zero or more.") }
        let quest = state.questSystem.quests[index]
        // Only new high-water progress earns or advances the streak. Corrections stay possible.
        let highWater = max(quest.currentValue, quest.progressHighWater)
        state.questSystem.quests[index].currentValue = value
        if value > highWater {
            state.questSystem.quests[index].progressHighWater = value
            state.questSystem.activities.append(QuestActivity(questID: id, kind: .progress, title: quest.title, date: date, timestamp: now, valueChange: value - highWater))
            award(id: "progress:\(id):\(date)", amount: 10, title: "Progress · \(quest.title)", date: date, now: now, state: &state)
        }
    }

    public static func setStatus(id: String, status: MainQuest.Status, demoteTasks: Bool = false, date: String, now: Date, state: inout AppState) throws {
        guard let index = state.questSystem.quests.firstIndex(where: { $0.id == id }) else { throw QuestError.invalid("Quest not found.") }
        let quest = state.questSystem.quests[index]
        guard quest.status != status else { return }
        if status == .active && state.questSystem.activeQuests.count >= 2 { throw QuestError.invalid(twoQuestMessage) }
        if status == .completed && quest.status != .active { throw QuestError.invalid("Activate this quest before completing it.") }
        state.questSystem.quests[index].status = status
        if status == .completed {
            state.questSystem.quests[index].completedAt = now
            let key = "quest:\(id)"
            if !state.questSystem.transactions.contains(where: { $0.id == key }) {
                state.questSystem.activities.append(QuestActivity(questID: id, kind: .completedQuest, title: quest.title, date: date, timestamp: now))
                award(id: key, amount: 50, title: "Completed · \(quest.title)", date: date, now: now, state: &state)
            }
        }
        if demoteTasks {
            for key in state.days.keys where key >= date {
                for i in state.days[key]!.tasks.indices where state.days[key]!.tasks[i].purpose.questID == id && !state.days[key]!.tasks[i].isCompleted {
                    state.days[key]!.tasks[i].purpose = .sidequest
                }
            }
            for i in state.laterTasks.indices where state.laterTasks[i].purpose.questID == id {
                state.laterTasks[i].purpose = .sidequest
            }
        }
    }

    public static func saveReward(_ reward: QuestReward, state: inout AppState) throws {
        guard !reward.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, (1...1_000_000).contains(reward.price) else {
            throw QuestError.invalid("Give the reward a name and a price between 1 and 1,000,000 Coins.")
        }
        if let index = state.questSystem.rewards.firstIndex(where: { $0.id == reward.id }) {
            state.questSystem.rewards[index] = reward
        } else { state.questSystem.rewards.append(reward) }
    }

    public static func redeem(id: String, requestID: String, date: String, now: Date, state: inout AppState) throws {
        let key = "redeem:\(requestID)"
        guard !state.questSystem.transactions.contains(where: { $0.id == key }) else { return }
        guard let reward = state.questSystem.rewards.first(where: { $0.id == id && !$0.isArchived }), reward.price > 0 else {
            throw QuestError.invalid("This reward is no longer available.")
        }
        guard state.questSystem.balance >= reward.price else { throw QuestError.invalid("You need \(reward.price - state.questSystem.balance) more Coins for this reward.") }
        state.questSystem.transactions.append(CoinTransaction(id: key, amount: -reward.price, title: "\(reward.emoji) \(reward.name)", date: date, timestamp: now, rewardID: id))
    }

    private static func award(id: String, amount: Int, title: String, date: String, now: Date, state: inout AppState) {
        guard !state.questSystem.transactions.contains(where: { $0.id == id }) else { return }
        state.questSystem.transactions.append(CoinTransaction(id: id, amount: amount, title: title, date: date, timestamp: now))
    }
}
