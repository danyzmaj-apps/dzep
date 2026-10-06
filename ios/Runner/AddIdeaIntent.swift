import AppIntents
import UIKit

/// "Hey Siri, add an idea to Ideja" / the Action Button: asks for the idea,
/// saves it without opening the app.
///
/// The Flutter session isn't reachable from here, so this posts to the
/// add-idea edge function with the device token lib/mobile.dart registered
/// at sign-in (UserDefaults "flutter.ideja_device_token"). Offline, the idea
/// is queued in "flutter.ideja_pending" and the app saves it on next open.
struct AddIdeaIntent: AppIntent {
  static let title: LocalizedStringResource = "Add Idea"
  static let description = IntentDescription("Drop an idea into Ideja.")
  static let openAppWhenRun = false

  @Parameter(title: "Idea", requestValueDialog: "What's the idea?")
  var text: String

  static var parameterSummary: some ParameterSummary {
    Summary("Add \(\.$text) to Ideja")
  }

  func perform() async throws -> some IntentResult & ProvidesDialog {
    let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return .result(dialog: "Nothing to save.") }
    let defaults = UserDefaults.standard
    guard let token = defaults.string(forKey: "flutter.ideja_device_token") else {
      return .result(dialog: "Open Ideja and sign in first.")
    }
    let createdAt = ISO8601DateFormatter().string(from: Date())
    do {
      var request = URLRequest(url: URL(string: "https://tgqmhieundubwtyvsnih.supabase.co/functions/v1/add-idea")!)
      request.httpMethod = "POST"
      request.timeoutInterval = 8
      request.setValue("application/json", forHTTPHeaderField: "content-type")
      request.setValue("sb_publishable_THRH7YNiM27mZTwXcWY7Rg_emvQ5ncw", forHTTPHeaderField: "apikey")
      request.setValue(token, forHTTPHeaderField: "x-ideja-token")
      request.httpBody = try JSONSerialization.data(withJSONObject: ["title": title, "created_at": createdAt])
      let (_, response) = try await URLSession.shared.data(for: request)
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      if status == 401 { return .result(dialog: "Ideja needs you to sign in again.") }
      guard status == 201 else { throw URLError(.badServerResponse) }
      return .result(dialog: "Saved to Ideja.")
    } catch {
      let entry = String(data: try JSONSerialization.data(withJSONObject: ["title": title]), encoding: .utf8)!
      defaults.set((defaults.stringArray(forKey: "flutter.ideja_pending") ?? []) + [entry], forKey: "flutter.ideja_pending")
      return .result(dialog: "Saved. It'll sync next time you open Ideja.")
    }
  }
}

struct IdejaShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: AddIdeaIntent(),
      phrases: [
        "Add an idea to \(.applicationName)",
        "Add idea to \(.applicationName)",
        "New \(.applicationName) idea",
        "New idea in \(.applicationName)",
      ],
      shortTitle: "Add Idea",
      systemImageName: "lightbulb"
    )
  }
}
