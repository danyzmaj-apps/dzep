/// An idea (optionally under a project), a todo, which is open or done
/// ([Idea.doneAt]) and may carry a reminder ([Idea.remindAt]), or a note:
/// free text, kept whole in [Idea.notes] with its first line as the title.
enum Kind {
  idea,
  todo,
  note;

  static Kind parse(Object? name) => switch (name) {
    'todo' => Kind.todo,
    'note' => Kind.note,
    _ => Kind.idea,
  };
}

/// A note's title: its first non-empty line, without Markdown heading marks.
String noteTitle(String text) {
  final line = text.split('\n').map((l) => l.trim()).firstWhere((l) => l.isNotEmpty, orElse: () => '');
  return line.replaceFirst(RegExp(r'^#+\s*'), '');
}

/// `@name` tokens in the title: the first one is the project.
final _projectToken = RegExp(r'(^|\s)@([\w.-]+)');

/// A typed title split into the title itself and its project (`@name`).
({String title, String project}) parseTitle(String raw) {
  final m = _projectToken.firstMatch(raw);
  final title = raw.replaceAll(_projectToken, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  return (title: title, project: m?.group(2) ?? '');
}

/// One row of the `ideas` table: an idea, a todo or a note ([kind]).
/// [updatedAt] is the server's clock once synced; [dirty] marks local changes
/// the server hasn't seen, [rev] tells a push whether the row changed again
/// while it was in flight.
class Idea {
  Idea({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.kind = Kind.idea,
    this.notes = '',
    this.project = '',
    this.device = '',
    this.doneAt,
    this.remindAt,
    this.deletedAt,
    this.dirty = false,
    this.rev = 0,
  });

  factory Idea.fromServer(Map<String, dynamic> row) => Idea(
    id: row['id'] as String,
    kind: Kind.parse(row['kind']),
    title: row['title'] as String? ?? '',
    notes: row['notes'] as String? ?? '',
    project: row['project'] as String? ?? '',
    device: row['device'] as String? ?? '',
    createdAt: DateTime.parse(row['created_at'] as String),
    updatedAt: DateTime.parse(row['updated_at'] as String),
    doneAt: row['done_at'] == null ? null : DateTime.parse(row['done_at'] as String),
    remindAt: row['remind_at'] == null ? null : DateTime.parse(row['remind_at'] as String),
    deletedAt: row['deleted_at'] == null ? null : DateTime.parse(row['deleted_at'] as String),
  );

  factory Idea.fromLocal(Map<String, dynamic> json) => Idea.fromServer(json)
    ..dirty = json['dirty'] as bool? ?? false
    ..rev = json['rev'] as int? ?? 0;

  final String id;
  final Kind kind;
  String title;
  String notes;
  String project;
  String device;
  final DateTime createdAt;
  DateTime updatedAt;
  DateTime? doneAt;

  /// When this todo notifies (lib/remind.dart); kept once it has fired, so a
  /// row can show it as overdue.
  DateTime? remindAt;

  DateTime? deletedAt;
  bool dirty;
  int rev;

  bool get deleted => deletedAt != null;
  bool get isTodo => kind == Kind.todo;
  bool get isNote => kind == Kind.note;
  bool get done => doneAt != null;

  /// Takes the server's copy of this row (same id).
  void absorb(Idea server) {
    title = server.title;
    notes = server.notes;
    project = server.project;
    device = server.device;
    updatedAt = server.updatedAt;
    doneAt = server.doneAt;
    remindAt = server.remindAt;
    deletedAt = server.deletedAt;
  }

  /// The columns a push writes; user_id and updated_at are the server's.
  Map<String, dynamic> toServer() => {
    'id': id,
    'kind': kind.name,
    'title': title,
    'notes': notes,
    'project': project,
    'device': device,
    'created_at': createdAt.toUtc().toIso8601String(),
    'done_at': doneAt?.toUtc().toIso8601String(),
    'remind_at': remindAt?.toUtc().toIso8601String(),
    'deleted_at': deletedAt?.toUtc().toIso8601String(),
  };

  Map<String, dynamic> toLocal() => {
    ...toServer(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
    'dirty': dirty,
    'rev': rev,
  };

  /// The JSON the terminal API (`/idea`, `/do`) sees.
  Map<String, dynamic> toApi() => {
    'id': id,
    'kind': kind.name,
    'title': title,
    'notes': notes,
    'project': project,
    'done': done,
    'created_at': createdAt.toUtc().toIso8601String(),
  };
}
