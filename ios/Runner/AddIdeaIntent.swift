import AppIntents
import WidgetKit

/// "Hey Siri, add an idea / a todo / a note to Džep" and the Action Button: asks for
/// the text and saves it without opening the app, through the `device` edge
/// function (the Flutter session isn't reachable from here). Offline, the
/// action is queued in the App Group and the app saves it on next open.
private func add(kind: String, text: String) async -> String {
  let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !title.isEmpty else { return "Nothing to save." }
  let action = [
    "action": "add", "kind": kind, "title": title,
    "created_at": ISO8601DateFormatter().string(from: Date()),
  ]
  switch await DzepShared.send(action) {
  case .done:
    if kind == "todo" { WidgetCenter.shared.reloadAllTimelines() }
    return switch kind {
    case "todo": "Todo added."
    case "note": "Note saved."
    default: "Saved to Džep."
    }
  case .signedOut:
    return "Open Džep and sign in first."
  case .failed:
    DzepShared.queue(action)
    return "Saved. It'll sync next time you open Džep."
  }
}

struct AddIdeaIntent: AppIntent {
  static let title: LocalizedStringResource = "Add Idea"
  static let description = IntentDescription("Drop an idea into Džep.")
  static let openAppWhenRun = false

  @Parameter(title: "Idea", requestValueDialog: "What's the idea?")
  var text: String

  static var parameterSummary: some ParameterSummary {
    Summary("Add idea \(\.$text) to Džep")
  }

  func perform() async throws -> some IntentResult & ProvidesDialog {
    .result(dialog: IntentDialog(stringLiteral: await add(kind: "idea", text: text)))
  }
}

struct AddTodoIntent: AppIntent {
  static let title: LocalizedStringResource = "Add Todo"
  static let description = IntentDescription("Add a todo to Džep.")
  static let openAppWhenRun = false

  @Parameter(title: "Todo", requestValueDialog: "What's the todo?")
  var text: String

  static var parameterSummary: some ParameterSummary {
    Summary("Add todo \(\.$text) to Džep")
  }

  func perform() async throws -> some IntentResult & ProvidesDialog {
    .result(dialog: IntentDialog(stringLiteral: await add(kind: "todo", text: text)))
  }
}

struct AddNoteIntent: AppIntent {
  static let title: LocalizedStringResource = "Add Note"
  static let description = IntentDescription("Write a quick note in Džep.")
  static let openAppWhenRun = false

  @Parameter(title: "Note", requestValueDialog: "What's the note?")
  var text: String

  static var parameterSummary: some ParameterSummary {
    Summary("Add note \(\.$text) to Džep")
  }

  func perform() async throws -> some IntentResult & ProvidesDialog {
    .result(dialog: IntentDialog(stringLiteral: await add(kind: "note", text: text)))
  }
}

struct DzepShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: AddTodoIntent(),
      phrases: [
        "Add a todo to \(.applicationName)",
        "Add todo to \(.applicationName)",
        "New \(.applicationName) todo",
      ],
      shortTitle: "Add Todo",
      systemImageName: "checklist"
    )
    AppShortcut(
      intent: AddIdeaIntent(),
      phrases: [
        "Add an idea to \(.applicationName)",
        "Add idea to \(.applicationName)",
        "New \(.applicationName) idea",
      ],
      shortTitle: "Add Idea",
      systemImageName: "lightbulb"
    )
    AppShortcut(
      intent: AddNoteIntent(),
      phrases: [
        "Add a note to \(.applicationName)",
        "Add note to \(.applicationName)",
        "New \(.applicationName) note",
      ],
      shortTitle: "Add Note",
      systemImageName: "note.text"
    )
  }
}
