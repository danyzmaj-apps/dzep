import 'package:dzep_core/chat.dart';
import 'package:dzep_core/idea.dart';
import 'package:dzep_core/store.dart';
import 'package:dzep_mobile/mobile.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

// In-memory stand-ins for the signed-in app, after apps/dzep-macos-app/
// test/app_fakes.dart and test/chat_page_test.dart: no disk, no Supabase.

/// An [IdeaStore] in memory, holding what [put] seeds.
class FakeStore extends ChangeNotifier implements IdeaStore {
  final _items = <Idea>[];

  /// Seeds [idea] as it is (its own dates), unlike [add].
  void put(Idea idea) => _items.add(idea);

  @override
  String get userId => 'user';

  @override
  String get device => 'iPhone';

  @override
  SyncState get syncState => SyncState.synced;

  List<Idea> get _live => _items.where((i) => !i.deleted).toList();

  @override
  List<Idea> get ideas =>
      _live.where((i) => i.kind == Kind.idea).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  @override
  List<Idea> get notes => _live.where((i) => i.isNote).toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  @override
  List<Idea> get openTodos =>
      _live.where((i) => i.isTodo && !i.done).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  @override
  List<Idea> get doneTodos =>
      _live.where((i) => i.isTodo && i.done).toList()..sort((a, b) => b.doneAt!.compareTo(a.doneAt!));

  @override
  List<String> get projects => {
    for (final i in ideas)
      if (i.project.isNotEmpty) i.project,
  }.toList()..sort();

  @override
  Idea? byId(String id) => _live.where((i) => i.id == id).firstOrNull;

  @override
  Idea add({required String title, Kind kind = Kind.idea, String notes = '', String project = '', DateTime? remindAt}) {
    final now = DateTime.now();
    final idea = Idea(
      id: 'i${_items.length}',
      kind: kind,
      title: title,
      notes: notes,
      project: project,
      remindAt: remindAt,
      createdAt: now,
      updatedAt: now,
    );
    _items.add(idea);
    notifyListeners();
    return idea;
  }

  @override
  Idea addNote(String text) => add(title: noteTitle(text), kind: Kind.note, notes: text);

  @override
  void editNote(Idea note, String text) => update(note, title: noteTitle(text), notes: text);

  @override
  void update(Idea idea, {String? title, String? notes, String? project, bool? done, ({DateTime? at})? remind}) {
    if (title != null) idea.title = title;
    if (notes != null) idea.notes = notes;
    if (project != null) idea.project = project;
    if (done != null) idea.doneAt = done ? DateTime.now() : null;
    if (remind != null) idea.remindAt = remind.at;
    notifyListeners();
  }

  @override
  void delete(Idea idea) {
    idea.deletedAt = DateTime.now();
    notifyListeners();
  }

  @override
  void restore(Idea idea) {
    idea.deletedAt = null;
    notifyListeners();
  }

  @override
  Future<void> syncNow() async {}

  @override
  void receive(Map<String, dynamic> row) {}

  @override
  Future<void> close() async {}
}

/// A [ChatStore] holding [chats] that never sends; the server's AI is
/// connected.
class FakeChats extends ChangeNotifier implements ChatStore {
  @override
  String get userId => 'user';

  @override
  AiStatus? get ai => const AiStatus(connected: true, model: 'deepseek-chat');

  @override
  bool get aiMissing => false;

  @override
  Future<AiStatus?> checkAi() async => ai;

  final chats = <Conversation>[];

  @override
  List<Conversation> get conversations => [...chats]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  @override
  Conversation? byId(String id) => chats.where((c) => c.id == id).firstOrNull;

  @override
  Conversation? get current => null;

  @override
  Conversation? get streaming => null;

  @override
  bool get busy => false;

  @override
  void newChat() {}

  @override
  void resume(Conversation c) {}

  @override
  void delete(Conversation c) {}

  @override
  Future<void> restore(Conversation c) async {}

  @override
  Future<void> send(String text, {Conversation? into, List<ChatImage> images = const []}) async {}

  @override
  Future<Uint8List> image(String path) async => Uint8List(0);

  @override
  Future<void> syncNow() async {}

  @override
  Future<void> close() async {}
}

/// A phone signed in as [userName] to [store] and [chats], with nothing
/// behind it.
class FakeSession extends MobileSession {
  FakeSession._(SharedPreferences prefs, this._store, this._chats) : super(prefs, 'iPhone');

  static Future<FakeSession> create(FakeStore store, FakeChats chats) async {
    SharedPreferences.setMockInitialValues({});
    return FakeSession._(await SharedPreferences.getInstance(), store, chats);
  }

  final FakeStore _store;
  final FakeChats _chats;

  @override
  IdeaStore? get store => _store;

  @override
  ChatStore? get chats => _chats;

  @override
  String get userName => 'ana';

  @override
  String? get avatarUrl => null;
}
