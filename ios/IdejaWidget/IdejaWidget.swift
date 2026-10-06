import SwiftUI
import WidgetKit

/// A tap target, not a dashboard: every size opens ideja://add, which drops
/// you straight into the add sheet with the keyboard up.
struct Entry: TimelineEntry {
  let date: Date
}

struct Provider: TimelineProvider {
  func placeholder(in context: Context) -> Entry { Entry(date: .now) }
  func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(Entry(date: .now)) }
  func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
    completion(Timeline(entries: [Entry(date: .now)], policy: .never))
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

struct IdejaWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "IdejaAddIdea", provider: Provider()) { _ in
      AddIdeaView()
        .widgetURL(URL(string: "ideja://add"))
        .containerBackground(Color(red: 0.09, green: 0.094, blue: 0.114), for: .widget)
    }
    .configurationDisplayName("New idea")
    .description("Opens Ideja ready to type.")
    .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
  }
}

@main
struct IdejaWidgets: WidgetBundle {
  var body: some Widget {
    IdejaWidget()
  }
}
