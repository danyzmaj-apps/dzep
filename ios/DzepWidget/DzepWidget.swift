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

@main
struct DzepWidgets: WidgetBundle {
  var body: some Widget {
    TodosWidget()
    NewIdeaWidget()
  }
}
