import 'dart:convert';
import 'dart:io';
import 'dart:ui' show FlutterView, Scene, SemanticsUpdate;

import 'package:dzep_core/apple_terminal.dart';
import 'package:dzep_core/backend.dart';
import 'package:dzep_core/chat.dart';
import 'package:dzep_core/ghostty.dart';
import 'package:dzep_core/idea.dart';
import 'package:dzep_core/iterm.dart';
import 'package:dzep_core/kitty.dart';
import 'package:dzep_core/session.dart';
import 'package:dzep_core/store.dart';
import 'package:dzep_core/tabs.dart';
import 'package:dzep_core/terminal.dart';
import 'package:dzep_core/terminals.dart';
import 'package:dzep_core/tmux.dart';
import 'package:dzep_core/ui.dart';
import 'package:dzep_core/wezterm.dart';
import 'package:dzep_macos/controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// An [IdeaStore] in memory: no disk, no Supabase.
class FakeStore extends ChangeNotifier implements IdeaStore {
  final _items = <Idea>[];

  /// The time of the last change; each add is stamped a minute after it.
  DateTime clock = DateTime.utc(2026, 10, 10, 9);

  @override
  String get userId => 'user';

  @override
  String get device => 'Mac';

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
  List<Idea> get doneTodos => _live.where((i) => i.isTodo && i.done).toList();

  @override
  List<String> get projects => {
    for (final i in ideas)
      if (i.project.isNotEmpty) i.project,
  }.toList()..sort();

  @override
  Idea? byId(String id) => _live.where((i) => i.id == id).firstOrNull;

  @override
  Idea add({required String title, Kind kind = Kind.idea, String notes = '', String project = '', DateTime? remindAt}) {
    // Each one a minute newer, so the newest-first order is the reverse of adding.
    clock = clock.add(const Duration(minutes: 1));
    final idea = Idea(
      id: 'i${_items.length}',
      kind: kind,
      title: title,
      notes: notes,
      project: project,
      remindAt: remindAt,
      createdAt: clock,
      updatedAt: clock,
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
    if (done != null) idea.doneAt = done ? clock : null;
    if (remind != null) idea.remindAt = remind.at;
    notifyListeners();
  }

  @override
  void delete(Idea idea) {
    idea.deletedAt = clock;
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

/// A [ChatStore] holding [chats] (none to start) that never sends; the
/// server's AI is [ai].
class FakeChats extends ChangeNotifier implements ChatStore {
  @override
  String get userId => 'user';

  @override
  AiStatus? get ai => _ai;
  AiStatus? _ai;
  set ai(AiStatus? status) {
    _ai = status;
    notifyListeners();
  }

  @override
  bool get aiMissing => ai?.connected == false;

  /// What [checkAi] finds on the server; null: it can't be reached.
  AiStatus? server;

  @override
  Future<AiStatus?> checkAi() async {
    if (server case final s?) ai = s;
    return ai;
  }

  /// The saved chats, in any order.
  final chats = <Conversation>[];

  @override
  List<Conversation> get conversations => [...chats]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  @override
  Conversation? byId(String id) => chats.where((c) => c.id == id).firstOrNull;

  @override
  Conversation? get current => _current;
  Conversation? _current;

  @override
  Conversation? get streaming => null;

  @override
  bool get busy => false;

  @override
  void newChat() {
    _current = null;
    notifyListeners();
  }

  @override
  void resume(Conversation c) {
    _current = c;
    notifyListeners();
  }

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

/// An [AppController] signed in to [FakeStore] and [FakeChats], its native
/// side answered by [calls].
class FakeApp extends AppController {
  FakeApp._(SharedPreferences prefs, this._givenTerminals) : super(prefs, 'Mac');

  /// [terminals] stand in for the Mac's; none found by default. [tabs] is
  /// the saved popup strip (all four in order by default).
  static Future<FakeApp> create({String? popupMode, TabChoice<PopupMode>? tabs, Terminals? terminals}) async {
    SharedPreferences.setMockInitialValues({
      'popup_mode': ?popupMode,
      'popup_tabs_order': ?tabs?.orderNames,
      'popup_tabs_hidden': ?tabs?.hiddenNames,
    });
    final app = FakeApp._(await SharedPreferences.getInstance(), terminals);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dzep/native'),
      (call) async {
        app.calls.add(call.method);
        return null;
      },
    );
    return app;
  }

  /// The signed-in user's name; Session's own when null.
  String? name;

  @override
  String get userName => name ?? super.userName;

  final fakeStore = FakeStore();
  final fakeChats = FakeChats();

  /// What Dart asked the native side, in order.
  final calls = <String>[];

  /// What runs when the user goes without [signOut] here.
  Future<void> signedOutByServer() => onSignedOut();

  @override
  Backend get backend => const Backend(url: 'https://example.supabase.co', key: 'test');

  @override
  IdeaStore get store => fakeStore;

  @override
  ChatStore get chats => fakeChats;

  /// Unless given: no terminal here, no kitty sockets, no tmux, no apps to script.
  @override
  Terminals get terminals => _givenTerminals ?? _terminals;
  final Terminals? _givenTerminals;
  late final _terminals = Terminals(
    kitty: Kitty(socketDir: '/nonexistent-dzep-test', home: '/nonexistent-dzep-test'),
    tmux: Tmux(executable: '/nonexistent-dzep-test/tmux', socketDirs: const []),
    wezterm: WezTerm(executable: '/nonexistent-dzep-test/wezterm', socketDir: '/nonexistent-dzep-test'),
    iterm: ITerm(appPath: '/nonexistent-dzep-test/iTerm.app'),
    terminal: AppleTerminal(appPath: '/nonexistent-dzep-test/Terminal.app'),
    ghostty: Ghostty(appPath: '/nonexistent-dzep-test/Ghostty.app'),
    recency: () async => const [],
    snapshot: () async => Procs(const []),
  );

  /// The server's active reviewer codes, newest first, without links (the
  /// server keeps hashes); what was asked of it in [madeCodes] and [revoked].
  final reviewer = <ReviewerCode>[];
  final madeCodes = <({int days, String label})>[];
  final revoked = <String>[];

  /// Makes [createReviewerCode] and [revokeReviewerCode] fail with this.
  String? reviewerFailure;

  @override
  Future<ReviewerCode> createReviewerCode({required int days, String label = ''}) async {
    if (reviewerFailure case final f?) throw PairingException(f);
    madeCodes.add((days: days, label: label));
    final id = 'code-${madeCodes.length}';
    final expiresAt = DateTime.now().add(Duration(days: days));
    reviewer.insert(0, ReviewerCode(id: id, label: label, expiresAt: expiresAt));
    return ReviewerCode(
      id: id,
      label: label,
      expiresAt: expiresAt,
      link: backend.linkWithCode('REVW-${madeCodes.length}AAA-BBBB-CCCC-DDDD-EEEE-FFFF'),
    );
  }

  @override
  Future<List<ReviewerCode>> reviewerCodes() async => [...reviewer];

  @override
  Future<void> revokeReviewerCode(String id) async {
    if (reviewerFailure case final f?) throw PairingException(f);
    revoked.add(id);
    reviewer.removeWhere((c) => c.id == id);
  }
}

/// A `claude` that answers from [list] (its `plugin list --json`) and records
/// what it's asked; [fail] makes that command fail as `--json` reports it,
/// [modsOff] has its `plugin test` refuse as with mods switched off.
class FakeClaude {
  FakeClaude(this.path);
  final String path;
  String version = '2.1.296 (Claude Code)';
  List<Map<String, Object?>> list = [];
  String? fail;
  bool modsOff = false;

  /// What a login shell's `command -v claude` prints; null: nothing found.
  String? onPath;
  final calls = <String>[];

  Future<ProcessResult> run(String exe, List<String> args) async {
    if (exe == '/bin/zsh') {
      return ProcessResult(0, onPath == null ? 1 : 0, onPath ?? '', '');
    }
    expect(exe, path);
    final call = args.join(' ');
    calls.add(call);
    if (call == fail) {
      return ProcessResult(0, 1, '{"outcome":"failed","message":"Plugin \\"dzep\\" not found"}\n', '✘ Failed');
    }
    if (call == '--version') return ProcessResult(0, 0, '$version\n', '');
    if (args.take(2).join(' ') == 'plugin test' && modsOff) {
      return ProcessResult(
        0,
        1,
        '',
        'claude plugin test: hooks modules are turned off in this process: the rollout switch was saved off '
            'by an earlier session and is not refreshed yet.\n',
      );
    }
    if (call == 'plugin list --json') return ProcessResult(0, 0, jsonEncode(list), '');
    return ProcessResult(0, 0, '{"outcome":"ok"}\n', '');
  }
}

/// [child] as main.dart hosts a window: a [MaterialApp] with Džep's theme and
/// a [Toaster].
Widget window(Widget child) => MaterialApp(
  theme: appTheme(),
  home: Material(
    type: MaterialType.transparency,
    child: Toaster(child: child),
  ),
);

/// A second window for multi-view tests (the popup next to the main window):
/// it lays out like the view it's made from and draws nothing.
class SecondView extends TestFlutterView {
  SecondView(FlutterView view)
    : super(
        view: view,
        platformDispatcher: view.platformDispatcher as TestPlatformDispatcher,
        display: view.display as TestDisplay,
      );

  @override
  int get viewId => 100;

  @override
  void render(Scene scene, {Size? size}) {}

  @override
  void updateSemantics(SemanticsUpdate update) {}
}
