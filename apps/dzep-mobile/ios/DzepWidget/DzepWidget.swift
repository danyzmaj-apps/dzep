import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

// MARK: - New idea (a tap target)

struct TapEntry: TimelineEntry {
  let date: Date
}

struct TapProvider: TimelineProvider {
  func placeholder(in context: Context) -> TapEntry { TapEntry(date: .now) }
  func getSnapshot(in context: Context, completion: @escaping (TapEntry) -> Void) { completion(TapEntry(date: .now)) }
  func getTimeline(in context: Context, completion: @escaping (Timeline<TapEntry>) -> Void) {
    completion(Timeline(entries: [TapEntry(date: .now)], policy: .never))
  }
}

struct AddIdeaView: View {
  @Environment(\.widgetFamily) private var family

  var body: some View {
    switch family {
    case .accessoryCircular:
      ZStack {
        AccessoryWidgetBackground()
        Image(systemName: "lightbulb.fill").font(.title2)
      }
    case .accessoryRectangular:
      HStack(spacing: 6) {
        Image(systemName: "lightbulb.fill")
        Text("New idea").font(.headline)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    default:
      VStack(alignment: .leading, spacing: 8) {
        Text("💡").font(.system(size: 34))
        Spacer()
        Text("New idea").font(.headline).foregroundStyle(.white)
        Text("Tap to drop it").font(.caption).foregroundStyle(Color(white: 0.6))
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
  }
}

/// Every size opens dzep://add: the add sheet with the keyboard up.
struct NewIdeaWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "DzepAddIdea", provider: TapProvider()) { _ in
      AddIdeaView()
        .widgetURL(URL(string: "dzep://add"))
        .containerBackground(Color(red: 0.09, green: 0.094, blue: 0.114), for: .widget)
    }
    .configurationDisplayName("New idea")
    .description("Opens Džep ready to type.")
    .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
  }
}

// MARK: - Todos (interactive)

/// Ticks a todo off from the Home Screen: hides it from the widget at once,
/// then tells the server; offline, the app replays it on next open.
struct CompleteTodoIntent: AppIntent {
  static let title: LocalizedStringResource = "Complete Todo"
  static let isDiscoverable = false

  @Parameter(title: "Todo ID") var id: String

  init() {}
  init(id: String) { self.id = id }

  func perform() async throws -> some IntentResult {
    DzepShared.todos.removeAll { $0.id == id }
    let action = ["action": "done", "id": id]
    if await DzepShared.send(action) == .failed { DzepShared.queue(action) }
    return .result()
  }
}

struct TodosEntry: TimelineEntry {
  let date: Date
  let todos: [DzepShared.Todo]
  let signedIn: Bool
}

struct TodosProvider: TimelineProvider {
  func placeholder(in context: Context) -> TodosEntry {
    TodosEntry(date: .now, todos: [.init(id: "1", title: "Review PR"), .init(id: "2", title: "Reply to Marko")], signedIn: true)
  }
  func getSnapshot(in context: Context, completion: @escaping (TodosEntry) -> Void) { completion(current()) }
  func getTimeline(in context: Context, completion: @escaping (Timeline<TodosEntry>) -> Void) {
    // The app reloads this widget whenever its todos change.
    completion(Timeline(entries: [current()], policy: .never))
  }
  private func current() -> TodosEntry {
    TodosEntry(date: .now, todos: DzepShared.todos, signedIn: DzepShared.token != nil)
  }
}

struct TodosView: View {
  @Environment(\.widgetFamily) private var family
  let entry: TodosEntry

  private var limit: Int { family == .systemLarge ? 9 : 4 }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("Todos").font(.headline).foregroundStyle(.white)
        if !entry.todos.isEmpty {
          Text("\(entry.todos.count)").font(.subheadline).foregroundStyle(Color(white: 0.55))
        }
        Spacer()
        Link(destination: URL(string: "dzep://add?kind=todo")!) {
          Image(systemName: "plus.circle.fill").font(.title3).foregroundStyle(Color(red: 0.49, green: 0.61, blue: 1))
        }
      }
      if !entry.signedIn {
        Text("Open Džep and sign in.").font(.caption).foregroundStyle(Color(white: 0.6))
      } else if entry.todos.isEmpty {
        Text("All done 🎉").font(.subheadline).foregroundStyle(Color(white: 0.6))
      }
      ForEach(entry.todos.prefix(limit), id: \.id) { todo in
        HStack(spacing: 8) {
          Button(intent: CompleteTodoIntent(id: todo.id)) {
            Image(systemName: "circle").font(.body).foregroundStyle(Color(white: 0.55))
          }
          .buttonStyle(.plain)
          Text(todo.title).font(.subheadline).foregroundStyle(.white).lineLimit(1)
        }
      }
      if entry.todos.count > limit {
        Text("+\(entry.todos.count - limit) more").font(.caption).foregroundStyle(Color(white: 0.55))
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

struct TodosWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "DzepTodos", provider: TodosProvider()) { entry in
      TodosView(entry: entry)
        .widgetURL(URL(string: "dzep://todos"))
        .containerBackground(Color(red: 0.09, green: 0.094, blue: 0.114), for: .widget)
    }
    .configurationDisplayName("Todos")
    .description("Your open todos. Tap a circle to tick one off.")
    .supportedFamilies([.systemMedium, .systemLarge])
  }
}

// MARK: - Coding session (Live Activity)

/// The app's colours (packages/dzep_core/lib/ui.dart's C).
private enum Palette {
  static let win = Color(red: 0x17 / 255, green: 0x18 / 255, blue: 0x1D / 255)
  static let dim = Color(red: 0x8A / 255, green: 0x8F / 255, blue: 0x9C / 255)
  static let accent = Color(red: 0x7C / 255, green: 0x9C / 255, blue: 0xFF / 255)
  static let ok = Color(red: 0x4A / 255, green: 0xDE / 255, blue: 0x80 / 255)
  static let warn = Color(red: 0xFB / 255, green: 0xBF / 255, blue: 0x24 / 255)
}

private typealias SessionState = SessionActivity.ContentState

extension SessionActivity.ContentState {
  fileprivate var color: Color {
    switch state {
    case .working: Palette.accent
    case .needs: Palette.warn
    case .done: Palette.ok
    case .ended: Palette.dim
    }
  }

  fileprivate var symbol: String {
    switch state {
    case .working: "sparkles"
    case .needs: "exclamationmark.bubble.fill"
    case .done: "checkmark.circle.fill"
    case .ended: "stop.circle"
    }
  }

  /// What it waits for, after "Needs you".
  fileprivate var waitsFor: String? {
    switch kind {
    case .question: "Question"
    case .approval: "Approval"
    case .plan: "Plan review"
    case nil: nil
    }
  }
}

/// Working with the time since it started, Needs you with what for,
/// Finished, or Ended. A stale one (no word for 8 hours) says so.
private struct SessionChip: View {
  let state: SessionState
  let stale: Bool

  var body: some View {
    HStack(spacing: 4) {
      if stale && state.state == .working {
        Text("No word lately")
      } else {
        switch state.state {
        case .working:
          Text("Working")
          Text(state.sinceDate, style: .timer).monospacedDigit()
        case .needs:
          Text(state.waitsFor.map { "Needs you · \($0)" } ?? "Needs you")
        case .done:
          Text("Finished")
        case .ended:
          Text("Ended")
        }
      }
    }
    .font(.caption.weight(.semibold))
    .foregroundStyle(stale ? Palette.dim : state.color)
    .lineLimit(1)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background((stale ? Palette.dim : state.color).opacity(0.15), in: Capsule())
  }
}

private struct SessionLockScreen: View {
  let context: ActivityViewContext<SessionActivity>

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: context.state.symbol).font(.title2).foregroundStyle(context.state.color)
      VStack(alignment: .leading, spacing: 2) {
        Text(context.attributes.title).font(.headline).foregroundStyle(.white).lineLimit(1)
        if !context.attributes.project.isEmpty {
          Text(context.attributes.project).font(.caption).foregroundStyle(Palette.dim).lineLimit(1)
        }
      }
      Spacer(minLength: 8)
      SessionChip(state: context.state, stale: context.isStale)
    }
    .padding(16)
  }
}

struct SessionLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: SessionActivity.self) { context in
      SessionLockScreen(context: context)
        .activityBackgroundTint(Palette.win)
        .activitySystemActionForegroundColor(.white)
        .widgetURL(context.attributes.link)
    } dynamicIsland: { context in
      let state = context.state
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Image(systemName: state.symbol).font(.title2).foregroundStyle(state.color).padding(.leading, 4)
        }
        DynamicIslandExpandedRegion(.center) {
          VStack(spacing: 2) {
            Text(context.attributes.title).font(.headline).lineLimit(1)
            if !context.attributes.project.isEmpty {
              Text(context.attributes.project).font(.caption).foregroundStyle(Palette.dim).lineLimit(1)
            }
          }
        }
        DynamicIslandExpandedRegion(.bottom) {
          SessionChip(state: state, stale: context.isStale)
        }
      } compactLeading: {
        Image(systemName: state.symbol).foregroundStyle(state.color)
      } compactTrailing: {
        switch state.state {
        case .working:
          Text(state.sinceDate, style: .timer)
            .monospacedDigit()
            .font(.caption2)
            .foregroundStyle(state.color)
            .frame(maxWidth: 44)
        case .needs:
          Text("Needs you").font(.caption2.weight(.semibold)).foregroundStyle(state.color)
        case .done:
          Text("Done").font(.caption2.weight(.semibold)).foregroundStyle(state.color)
        case .ended:
          Text("Ended").font(.caption2).foregroundStyle(state.color)
        }
      } minimal: {
        Image(systemName: state.symbol).foregroundStyle(state.color)
      }
      .widgetURL(context.attributes.link)
      .keylineTint(state.color)
    }
  }
}

@main
struct DzepWidgets: WidgetBundle {
  var body: some Widget {
    TodosWidget()
    NewIdeaWidget()
    SessionLiveActivity()
  }
}
