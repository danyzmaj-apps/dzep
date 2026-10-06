import 'dart:ui' show Color;

/// Where an idea is in its life. Inbox is where every new idea lands.
enum Status {
  inbox('Inbox', Color(0xFF8B93A7)),
  building('Building', Color(0xFFFBBF24)),
  shipped('Shipped', Color(0xFF4ADE80)),
  dropped('Dropped', Color(0xFF5B606C));

  const Status(this.label, this.color);

  final String label;
  final Color color;

  static Status parse(String? name) => Status.values.firstWhere((s) => s.name == name, orElse: () => Status.inbox);
}

/// Ideas go through [Status]; todos are just open or done ([Idea.doneAt]).
enum Kind { idea, todo }

/// One row of the `ideas` table: an idea or a todo ([kind]). [updatedAt] is
/// the server's clock once synced; [dirty] marks local changes the server
/// hasn't seen, [rev] tells a push whether the row changed again while it
/// was in flight.
class Idea {
  Idea({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.kind = Kind.idea,
    this.notes = '',
    this.project = '',
    this.status = Status.inbox,
    this.device = '',
    this.doneAt,
    this.deletedAt,
    this.dirty = false,
    this.rev = 0,
  });

  factory Idea.fromServer(Map<String, dynamic> row) => Idea(
    id: row['id'] as String,
    kind: row['kind'] == 'todo' ? Kind.todo : Kind.idea,
    title: row['title'] as String? ?? '',
    notes: row['notes'] as String? ?? '',
    project: row['project'] as String? ?? '',
    status: Status.parse(row['status'] as String?),
    device: row['device'] as String? ?? '',
    createdAt: DateTime.parse(row['created_at'] as String),
    updatedAt: DateTime.parse(row['updated_at'] as String),
    doneAt: row['done_at'] == null ? null : DateTime.parse(row['done_at'] as String),
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
  Status status;
  String device;
  final DateTime createdAt;
  DateTime updatedAt;
  DateTime? doneAt;
  DateTime? deletedAt;
  bool dirty;
  int rev;

  bool get deleted => deletedAt != null;
  bool get isTodo => kind == Kind.todo;
  bool get done => doneAt != null;

  /// Takes the server's copy of this row (same id).
  void absorb(Idea server) {
    title = server.title;
    notes = server.notes;
    project = server.project;
    status = server.status;
    device = server.device;
    updatedAt = server.updatedAt;
    doneAt = server.doneAt;
    deletedAt = server.deletedAt;
  }

  /// The columns a push writes; user_id and updated_at are the server's.
  Map<String, dynamic> toServer() => {
    'id': id,
    'kind': kind.name,
    'title': title,
    'notes': notes,
    'project': project,
    'status': status.name,
    'device': device,
    'created_at': createdAt.toUtc().toIso8601String(),
    'done_at': doneAt?.toUtc().toIso8601String(),
    'deleted_at': deletedAt?.toUtc().toIso8601String(),
  };

  Map<String, dynamic> toLocal() => {
    ...toServer(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
    'dirty': dirty,
    'rev': rev,
  };

  /// The JSON the terminal API (`/idea`, `/todo`) sees.
  Map<String, dynamic> toApi() => {
    'id': id,
    'kind': kind.name,
    'title': title,
    'notes': notes,
    'project': project,
    'status': status.name,
    'done': done,
    'created_at': createdAt.toUtc().toIso8601String(),
  };
}
