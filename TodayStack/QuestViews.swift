import AppKit
import SwiftUI

/// A single scroll surface that grows naturally, then stops at the screen's available height.
struct DaybudContentScroll<Content: View>: View {
    @State private var contentHeight: CGFloat = 480
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0, content: content)
                .frame(maxWidth: .infinity)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                })
        }
        .frame(height: min(contentHeight, max(280, (NSScreen.main?.visibleFrame.height ?? 850) - 170)))
        .onPreferenceChange(ContentHeightKey.self) { if $0 > 0 { contentHeight = $0 } }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct MainQuestsSection: View {
    @ObservedObject var store: AppStore
    var onManage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Main Quests", systemImage: "flag")
                    .font(.subheadline.weight(.semibold))
                if store.mainQuestStreak > 0 {
                    Label("\(store.mainQuestStreak)d", systemImage: "flame")
                        .font(.caption2).foregroundStyle(.secondary)
                        .help("Days moving a Main Quest forward")
                }
                Spacer()
                Button("Manage", action: onManage).buttonStyle(.borderless).font(.caption)
            }
            if store.state.questSystem.activeQuests.isEmpty {
                Button(action: onManage) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("What would move your life forward?").font(.callout.weight(.medium))
                        Text("Choose up to two Main Quests.").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain)
            }
            ForEach(store.state.questSystem.activeQuests) { quest in
                Button(action: onManage) { QuestCard(quest: quest, store: store) }.buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Manage \(quest.title). \(quest.progressLabel)")
                    .accessibilityAddTraits(.isButton)
            }
        }.padding(.horizontal, 14).padding(.bottom, 14)
    }
}

private struct QuestCard: View {
    let quest: MainQuest
    @ObservedObject var store: AppStore

    private var linked: [TaskItem] {
        store.todayPlan.tasks.filter { $0.purpose.questID == quest.id }
    }
    private var advanced: Bool {
        store.state.questSystem.activities.contains { $0.questID == quest.id && $0.date == store.todayDateKey && $0.isMainProgress }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if !quest.emoji.isEmpty { Text(quest.emoji) }
                Text(quest.title).font(.callout.weight(.semibold)).lineLimit(2)
                Spacer(minLength: 0)
                if advanced { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Advanced today") }
            }
            HStack {
                Text(quest.targetValue == nil ? "\(linked.filter(\.isCompleted).count)/\(linked.count) actions today" : quest.progressLabel)
                Spacer()
                Text(advanced ? "Advanced today" : "One step today").foregroundStyle(advanced ? Color.green : .secondary)
            }.font(.caption2)
            ProgressView(value: quest.targetValue.map { min(quest.currentValue / $0, 1) } ?? Double(linked.filter(\.isCompleted).count) / Double(max(linked.count, 1)))
                .controlSize(.small).tint(advanced ? .green : .accentColor)
                .animation(.easeInOut(duration: 0.25), value: quest.currentValue)
            if let next = (linked + store.state.laterTasks.filter { $0.purpose.questID == quest.id }).first(where: { !$0.isCompleted }) {
                Text("\(store.state.laterTasks.contains { $0.id == next.id } ? "In Later" : "Next") · \(next.title)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            } else {
                Text("Add a next action in Manage").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
    }
}

struct QuestHubView: View {
    @ObservedObject var store: AppStore
    var convertingTask: TaskItem?
    var onClose: () -> Void
    @State private var draft: MainQuest?
    @State private var attachingTaskID: String?
    @State private var selectedQuestID: String?
    @State private var showPast = false
    @State private var completionReceipt: String?

    var body: some View {
        DaybudContentScroll {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button("Back", systemImage: "chevron.left", action: onClose).buttonStyle(.borderless)
                    Spacer()
                    Text("Main Quests").font(.headline)
                    Spacer()
                    Button("New", systemImage: "plus") { beginNew() }.buttonStyle(.borderless)
                }
                Text("Two priorities. Real movement.").font(.caption).foregroundStyle(.secondary)
                if let completionReceipt { Label(completionReceipt, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green) }
                if let draft {
                    QuestEditor(quest: draft, isNew: !store.state.questSystem.quests.contains(where: { $0.id == draft.id }), onCancel: { self.draft = nil; attachingTaskID = nil }) { edited in
                        if store.saveQuest(edited, attachingTaskID: attachingTaskID) {
                            self.draft = nil; attachingTaskID = nil; selectedQuestID = edited.id
                        }
                    }.id(draft.id)
                } else {
                    ForEach(store.state.questSystem.activeQuests) { quest in
                        questRow(quest)
                    }
                    if store.state.questSystem.activeQuests.isEmpty {
                        Text("Choose an outcome, then attach the concrete actions that move it forward.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Create a Main Quest") { beginNew() }
                    }
                    DisclosureGroup("Completed & archived", isExpanded: $showPast) {
                        ForEach(store.state.questSystem.quests.filter { $0.status != .active }) { quest in
                            questRow(quest)
                        }
                    }.font(.caption)
                }
            }.padding(14)
        }
        .onAppear {
            if let convertingTask {
                draft = MainQuest(title: convertingTask.title)
                attachingTaskID = convertingTask.id
            }
        }
    }

    private func beginNew() {
        guard store.state.questSystem.activeQuests.count < 2 else {
            // Run the same validation as other entry points to show the actionable error.
            store.saveQuest(MainQuest(title: "New Main Quest")); return
        }
        attachingTaskID = nil
        draft = MainQuest(title: "")
    }

    private func questRow(_ quest: MainQuest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                selectedQuestID = selectedQuestID == quest.id ? nil : quest.id
            } label: {
                HStack {
                    Text("\(quest.emoji) \(quest.title)").font(.callout.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.down").font(.caption2)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Text(quest.targetValue != nil ? quest.progressLabel : quest.status.rawValue.capitalized)
                .font(.caption).foregroundStyle(.secondary)
            if quest.status != .active {
                Text(quest.status.rawValue.capitalized).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
            }
            if selectedQuestID == quest.id {
                if !quest.description.isEmpty { Text(quest.description).font(.caption).textSelection(.enabled) }
                if let deadline = quest.deadline { Text("Due \(deadline.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary) }
                if quest.status == .active {
                    QuestActionsEditor(store: store, quest: quest)
                }
                HStack {
                    Button("Edit") { draft = quest }
                    if quest.status == .active {
                        Button(store.state.questSystem.transactions.contains { $0.id == "quest:\(quest.id)" } ? "Complete" : "Complete · +50") {
                            let alreadyRewarded = store.state.questSystem.transactions.contains { $0.id == "quest:\(quest.id)" }
                            if store.setQuestStatus(id: quest.id, status: .completed) {
                                completionReceipt = alreadyRewarded ? "Main Quest complete." : "Main Quest complete. +50 Coins."
                                showPast = true
                            }
                        }
                        Menu("More") {
                            Button("Archive quest") { store.setQuestStatus(id: quest.id, status: .archived) }
                            Button("Archive & detach actions") { store.setQuestStatus(id: quest.id, status: .archived, demoteTasks: true) }
                        }.fixedSize()
                    } else {
                        Button("Activate") { store.setQuestStatus(id: quest.id, status: .active) }
                    }
                }.controlSize(.small)
            }
        }.padding(10).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct QuestEditor: View {
    @State var quest: MainQuest
    let isNew: Bool
    var onCancel: () -> Void
    var onSave: (MainQuest) -> Void
    @State private var hasTarget = false
    @State private var hasDeadline = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isNew ? "New Main Quest" : "Edit Main Quest").font(.headline)
            HStack {
                TextField("Emoji", text: $quest.emoji).frame(width: 48).accessibilityLabel("Quest emoji")
                TextField("Outcome title", text: $quest.title).accessibilityLabel("Quest title")
            }
            TextField("Description (optional)", text: $quest.description, axis: .vertical).lineLimit(2...4)
            Toggle("Measurable target", isOn: $hasTarget)
            if hasTarget {
                HStack {
                    if isNew { TextField("Current", value: $quest.currentValue, format: .number).accessibilityLabel("Starting value") }
                    TextField("Target", value: Binding(get: { quest.targetValue ?? 1 }, set: { quest.targetValue = $0 }), format: .number)
                        .accessibilityLabel("Quest target")
                    TextField("Unit", text: $quest.unit).accessibilityLabel("Quest unit")
                }
            }
            Toggle("Deadline", isOn: $hasDeadline)
            if hasDeadline {
                DatePicker("Due", selection: Binding(get: { quest.deadline ?? Date() }, set: { quest.deadline = $0 }), displayedComponents: .date)
            }
            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button(isNew ? "Create quest" : "Save quest") {
                    var edited = quest
                    edited.targetValue = hasTarget ? (quest.targetValue ?? 1) : nil
                    edited.deadline = hasDeadline ? (quest.deadline ?? Date()) : nil
                    onSave(edited)
                }.disabled(quest.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.textFieldStyle(.roundedBorder).controlSize(.small)
            .padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
            .onAppear { hasTarget = quest.targetValue != nil; hasDeadline = quest.deadline != nil }
    }
}

private struct QuestActionsEditor: View {
    @ObservedObject var store: AppStore
    let quest: MainQuest
    @State private var value: Double = 0
    @State private var actionTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if quest.targetValue != nil {
                HStack {
                    TextField("Current value", value: $value, format: .number).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Update quest value")
                    Button("Update progress") { store.updateQuestProgress(id: quest.id, value: value) }
                }
                Text("New progress earns +10 Coins once per day.").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(store.todayPlan.tasks.filter { $0.purpose.questID == quest.id }) { task in
                HStack {
                    Image(systemName: task.isCompleted ? "checkmark.circle" : "circle").foregroundStyle(.secondary)
                    Text(task.title).font(.caption)
                    Spacer()
                    Button { store.assignTask(id: task.id, purpose: .regular) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Detach \(task.title)")
                }
            }
            Menu("Attach an existing task…") {
                ForEach((store.todayPlan.tasks + store.state.laterTasks).filter { !$0.isCompleted && $0.purpose.questID != quest.id }) { task in
                    Button(task.title) { store.assignTask(id: task.id, purpose: .mainQuest(quest.id)) }
                }
            }
            HStack {
                TextField("New next action", text: $actionTitle).textFieldStyle(.roundedBorder)
                Button("Add action") {
                    if store.addTask(title: actionTitle, purpose: .mainQuest(quest.id)) != nil { actionTitle = "" }
                }.disabled(actionTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.controlSize(.small).onAppear { value = quest.currentValue }
    }
}

struct RewardShopView: View {
    @ObservedObject var store: AppStore
    var onClose: () -> Void
    @State private var editing: QuestReward?
    @State private var redeeming: QuestReward?
    @State private var redemptionID = UUID().uuidString
    @State private var showHistory = false
    @State private var showArchived = false
    @State private var receipt: String?

    var body: some View {
        DaybudContentScroll {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button("Back", systemImage: "chevron.left", action: onClose).buttonStyle(.borderless)
                    Spacer()
                    Label("\(store.state.questSystem.balance) Coins", systemImage: "circle.circle").font(.headline)
                }
                Picker("Rewards", selection: $showHistory) {
                    Text("Reward Shop").tag(false)
                    Text("Coin history").tag(true)
                }.pickerStyle(.segmented)
                if let receipt { Label(receipt, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green) }
                if showHistory {
                    if store.state.questSystem.transactions.isEmpty {
                        Text("Your first Main Quest action earns 10 Coins. Every transaction will appear here.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(store.state.questSystem.transactions.reversed()) { entry in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title).font(.callout)
                                Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(entry.amount > 0 ? "+\(entry.amount)" : "\(entry.amount)")
                                .font(.callout.monospacedDigit()).foregroundStyle(entry.amount > 0 ? Color.green : .secondary)
                        }
                        Divider()
                    }
                } else if let editing {
                    RewardEditor(reward: editing, onCancel: { self.editing = nil }) { reward in
                        if store.saveReward(reward) { self.editing = nil }
                    }.id(editing.id)
                } else {
                    Text("Leisure, deliberately earned. No rules about how you enjoy it.").font(.caption).foregroundStyle(.secondary)
                    if let redeeming {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Redeem \(redeeming.name) for \(redeeming.price) Coins?").font(.callout.weight(.medium))
                            HStack {
                                Button("Cancel") { self.redeeming = nil }
                                Spacer()
                                Button("Redeem reward") {
                                    if store.redeemReward(id: redeeming.id, requestID: redemptionID) {
                                        receipt = "Redeemed \(redeeming.name). Enjoy!"
                                        self.redeeming = nil
                                    }
                                }
                            }
                        }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                    }
                    ForEach(store.state.questSystem.rewards.filter { showArchived || !$0.isArchived }) { reward in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("\(reward.emoji) \(reward.name)").font(.callout.weight(.medium))
                                Spacer()
                                Menu {
                                    Button("Edit reward") { editing = reward }
                                    Button(reward.isArchived ? "Restore reward" : "Archive reward") {
                                        var changed = reward; changed.isArchived.toggle(); store.saveReward(changed)
                                    }
                                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
                            }
                            if !reward.description.isEmpty { Text(reward.description).font(.caption).foregroundStyle(.secondary) }
                            HStack {
                                Text(reward.isArchived ? "Archived" : "\(reward.price) Coins").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button(store.state.questSystem.balance >= reward.price ? "Redeem" : "\(reward.price - store.state.questSystem.balance) Coins to go") {
                                    redemptionID = UUID().uuidString; redeeming = reward; receipt = nil
                                }.disabled(reward.isArchived || store.state.questSystem.balance < reward.price || redeeming != nil)
                            }
                        }.padding(10).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                    }
                    HStack {
                        Button("Add reward", systemImage: "plus") { editing = QuestReward(name: "", price: 60) }
                        Spacer()
                        Toggle("Archived", isOn: $showArchived).toggleStyle(.checkbox).font(.caption)
                    }
                    Text("Main action +10 · New progress +10/day\nHabit +1/day · Main Quest complete +50")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }.padding(14).controlSize(.small)
        }
    }
}

private struct RewardEditor: View {
    @State var reward: QuestReward
    var onCancel: () -> Void
    var onSave: (QuestReward) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Reward details").font(.headline)
            HStack {
                TextField("Emoji", text: $reward.emoji).frame(width: 50)
                TextField("Reward name", text: $reward.name)
            }
            TextField("Description (optional)", text: $reward.description, axis: .vertical)
            HStack { Text("Coins"); TextField("Price", value: $reward.price, format: .number).accessibilityLabel("Reward price") }
            HStack { Button("Cancel", action: onCancel); Spacer(); Button("Save reward") { onSave(reward) } }
        }.textFieldStyle(.roundedBorder)
    }
}

struct QuestWeeklyReviewView: View {
    let state: QuestState
    let today: String
    let calendar: Calendar

    private var weekStart: String {
        guard let date = DateKey.date(from: today, calendar: calendar), let week = calendar.dateInterval(of: .weekOfYear, for: date) else { return today }
        return DateKey.string(from: week.start, calendar: calendar)
    }
    private var activities: [QuestActivity] { state.activities.filter { $0.date >= weekStart && $0.date <= today } }
    private var transactions: [CoinTransaction] { state.transactions.filter { $0.date >= weekStart && $0.date <= today } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Did my Main Quests move?").font(.headline)
            Text("This calendar week").font(.caption2).foregroundStyle(.secondary)
            ForEach(state.quests.filter { quest in quest.status == .active || activities.contains { $0.questID == quest.id } }) { quest in
                let events = activities.filter { $0.questID == quest.id }
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(quest.emoji) \(quest.title)").font(.caption.weight(.semibold))
                    Text(events.isEmpty ? "No movement yet — one next action is enough." : "\(events.filter { $0.kind == .mainAction }.count) actions · +\(events.reduce(0) { $0 + $1.valueChange }.formatted()) \(quest.unit)\(events.contains { $0.kind == .completedQuest } ? " · Completed" : "")")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if state.quests.isEmpty { Text("Choose a Main Quest to start your weekly review.").font(.caption).foregroundStyle(.secondary) }
            Text("\(Set(activities.filter(\.isMainProgress).map(\.date)).count) Main Quest days · \(activities.filter { $0.kind == .mainAction }.count) main actions")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Earned \(transactions.filter { $0.amount > 0 }.reduce(0) { $0 + $1.amount })")
                Text("Spent \(-transactions.filter { $0.amount < 0 }.reduce(0) { $0 + $1.amount })")
                Spacer()
                Text("\(state.balance) Coins").fontWeight(.semibold)
            }.font(.caption2.monospacedDigit())
        }.padding(12).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
    }
}
