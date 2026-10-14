import AppIntents
import SwiftUI
import WidgetKit
import notify

// The Mac's Todos widget (desktop and Notification Center). Same look as the
// iPhone's (apps/dzep-mobile/ios/DzepWidget), but a tick never touches the network: the
// menu-bar app is always running and has the session, so it applies them.

/// Ticks a todo off: hides it from the widget at once and queues it in the App
/// Group for the app, which takes the queue as soon as it hears `queued` (or on
/// next launch, if it isn't running).
struct CompleteTodoIntent: AppIntent {
  static let title: LocalizedStringResource = "Complete Todo"
  static let isDiscoverable = false

  @Parameter(title: "Todo ID") var id: String

  init() {}
  init(id: String) { self.id = id }

  func perform() async throws -> some IntentResult {
    // Signed out since the widget last drew: there's nothing to tick.
    guard DzepShared.snapshot != nil else { return .result() }
    DzepShared.todos.removeAll { $0.id == id }
    DzepShared.queue(["action": "done", "id": id])
    notify_post(DzepShared.queued)
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
    // The app reloads this widget whenever its open todos change.
    completion(Timeline(entries: [current()], policy: .never))
  }
  private func current() -> TodosEntry {
    let snapshot = DzepShared.snapshot
    return TodosEntry(date: .now, todos: snapshot ?? [], signedIn: snapshot != nil)
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

/// No widget URL: the Mac app handles no links besides sign-in, so a click
/// outside a circle simply opens Džep.
@main
struct TodosWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "DzepTodos", provider: TodosProvider()) { entry in
      TodosView(entry: entry)
        .containerBackground(Color(red: 0.09, green: 0.094, blue: 0.114), for: .widget)
    }
    .configurationDisplayName("Todos")
    .description("Your open todos. Click a circle to tick one off.")
    .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
  }
}
