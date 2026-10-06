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

/// One idea. [updatedAt] is the server's clock once synced; [dirty] marks
/// local changes the server hasn't seen, [rev] tells a push whether the idea
/// changed again while it was in flight.
class Idea {
  Idea({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.notes = '',
    this.project = '',
    this.status = Status.inbox,
    this.device = '',
    this.deletedAt,
    this.dirty = false,
    this.rev = 0,
  });

  factory Idea.fromServer(Map<String, dynamic> row) => Idea(
    id: row['id'] as String,
    title: row['title'] as String? ?? '',
    notes: row['notes'] as String? ?? '',
    project: row['project'] as String? ?? '',
    status: Status.parse(row['status'] as String?),
    device: row['device'] as String? ?? '',
    createdAt: DateTime.parse(row['created_at'] as String),
    updatedAt: DateTime.parse(row['updated_at'] as String),
    deletedAt: row['deleted_at'] == null ? null : DateTime.parse(row['deleted_at'] as String),
  );

  factory Idea.fromLocal(Map<String, dynamic> json) => Idea.fromServer(json)
    ..dirty = json['dirty'] as bool? ?? false
    ..rev = json['rev'] as int? ?? 0;

  final String id;
  String title;
  String notes;
  String project;
  Status status;
  String device;
  final DateTime createdAt;
  DateTime updatedAt;
  DateTime? deletedAt;
  bool dirty;
  int rev;

  bool get deleted => deletedAt != null;

  /// The columns a push writes; user_id and updated_at are the server's.
  Map<String, dynamic> toServer() => {
    'id': id,
    'title': title,
    'notes': notes,
    'project': project,
    'status': status.name,
    'device': device,
    'created_at': createdAt.toUtc().toIso8601String(),
    'deleted_at': deletedAt?.toUtc().toIso8601String(),
  };

  Map<String, dynamic> toLocal() => {
    ...toServer(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
    'dirty': dirty,
    'rev': rev,
  };

  /// The JSON the terminal API (`/idea`) sees.
  Map<String, dynamic> toApi() => {
    'id': id,
    'title': title,
    'notes': notes,
    'project': project,
    'status': status.name,
    'created_at': createdAt.toUtc().toIso8601String(),
  };
}
