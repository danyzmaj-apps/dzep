import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dzep/idea.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

/// Every row of a query, a page at a time: the API returns at most
/// `max_rows` (1000) per request, so a first sync of a big account would
/// otherwise stop there. [page] fetches rows `from`..`to` (inclusive) of a
/// stable order.
Future<List<Map<String, dynamic>>> fetchAll(
  Future<List<Map<String, dynamic>>> Function(int from, int to) page, {
  int size = 1000,
}) async {
  final all = <Map<String, dynamic>>[];
  while (true) {
    final rows = await page(all.length, all.length + size - 1);
    all.addAll(rows);
    if (rows.length < size) return all;
  }
}

enum SyncState { synced, syncing, offline }

/// The signed-in user's ideas: a JSON file on this Mac that every edit lands
/// in first (so capture never waits on the network), pushed to Supabase in
/// the background and kept current from the other Macs by realtime + pulls.
class IdeaStore extends ChangeNotifier {
  IdeaStore._(this._client, this.userId, this._file, this.device);

  static Future<IdeaStore> open(SupabaseClient client, String userId, String device) async {
    final dir = await getApplicationSupportDirectory();
    final store = IdeaStore._(client, userId, File('${dir.path}/ideas-$userId.json'), device);
    await store._load();
    store._start();
    return store;
  }

  final SupabaseClient _client;
  final String userId;
  final String device;
  final File _file;

  final Map<String, Idea> _ideas = {};
  DateTime? _cursor;
  RealtimeChannel? _channel;
  Timer? _pushTimer;
  Timer? _saveTimer;
  Timer? _pullTimer;
  bool _pushing = false;
  bool _closed = false;

  SyncState get syncState => _syncState;
  SyncState _syncState = SyncState.syncing;

  List<Idea> get _live => _ideas.values.where((i) => !i.deleted).toList();

  /// Live ideas (not todos or notes), newest first.
  List<Idea> get ideas =>
      _live.where((i) => i.kind == Kind.idea).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  /// Live notes, most recently edited first.
  List<Idea> get notes => _live.where((i) => i.isNote).toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  /// Open todos, newest first.
  List<Idea> get openTodos =>
      _live.where((i) => i.isTodo && !i.done).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  /// Done todos, most recently finished first.
  List<Idea> get doneTodos =>
      _live.where((i) => i.isTodo && i.done).toList()..sort((a, b) => b.doneAt!.compareTo(a.doneAt!));

  /// Every project name in use by ideas, sorted.
  List<String> get projects => ({
    for (final i in ideas)
      if (i.project.isNotEmpty) i.project,
  }.toList()..sort());

  Idea? byId(String id) {
    final i = _ideas[id];
    return i == null || i.deleted ? null : i;
  }

  // ---------------------------------------------------------------- edits

  Idea add({required String title, Kind kind = Kind.idea, String notes = '', String project = '', DateTime? remindAt}) {
    final now = DateTime.now().toUtc();
    final idea = Idea(
      id: const Uuid().v4(),
      kind: kind,
      title: title.trim(),
      notes: notes.trim(),
      project: kind == Kind.idea ? project.trim() : '',
      remindAt: kind == Kind.todo ? remindAt?.toUtc() : null,
      device: device,
      createdAt: now,
      updatedAt: now,
    );
    _ideas[idea.id] = idea;
    _changed(idea);
    return idea;
  }

  /// A new note with [text] (its first line becomes the title).
  Idea addNote(String text) => add(title: noteTitle(text), kind: Kind.note, notes: text);

  /// Replaces a note's text, and so its title.
  void editNote(Idea note, String text) => update(note, title: noteTitle(text), notes: text);

  /// Null leaves a field as it is; [remind] sets the reminder, `(at: null)`
  /// clears it. A done or deleted todo keeps its reminder (for Undo) but
  /// never notifies (see `pendingReminders`).
  void update(Idea idea, {String? title, String? notes, String? project, bool? done, ({DateTime? at})? remind}) {
    if (title != null) idea.title = title;
    if (notes != null) idea.notes = notes;
    if (project != null) idea.project = project.trim();
    if (done != null) idea.doneAt = done ? (idea.doneAt ?? DateTime.now().toUtc()) : null;
    if (remind != null) idea.remindAt = remind.at?.toUtc();
    _changed(idea);
  }

  void delete(Idea idea) {
    idea.deletedAt = DateTime.now().toUtc();
    _changed(idea);
  }

  void restore(Idea idea) {
    idea.deletedAt = null;
    _changed(idea);
  }

  void _changed(Idea idea) {
    idea
      ..dirty = true
      ..rev += 1
      // Shown at once as "edited just now"; the push brings the server's time.
      ..updatedAt = DateTime.now().toUtc();
    notifyListeners();
    _scheduleSave();
    _pushTimer?.cancel();
    _pushTimer = Timer(const Duration(milliseconds: 600), _push);
  }

  // ---------------------------------------------------------------- disk

  Future<void> _load() async {
    if (!_file.existsSync()) return;
    try {
      final json = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
      final cursor = json['cursor'] as String?;
      _cursor = cursor == null ? null : DateTime.parse(cursor);
      for (final raw in json['ideas'] as List<dynamic>) {
        final idea = Idea.fromLocal(raw as Map<String, dynamic>);
        _ideas[idea.id] = idea;
      }
    } on Object catch (e) {
      // A damaged cache is only a cache: the server has everything synced.
      debugPrint('Džep: local cache unreadable ($e), starting from the server');
      _cursor = null;
      _ideas.clear();
    }
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 250), () => unawaited(_save()));
  }

  Future<void> _save() async {
    final json = jsonEncode({
      'cursor': _cursor?.toUtc().toIso8601String(),
      'ideas': [for (final i in _ideas.values) i.toLocal()],
    });
    await _file.parent.create(recursive: true);
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(json, flush: true);
    await tmp.rename(_file.path);
  }

  // ---------------------------------------------------------------- sync

  void _start() {
    _channel = _client
        .channel('ideas-$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'ideas',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'user_id', value: userId),
          callback: (payload) {
            if (payload.newRecord.isNotEmpty) _merge([payload.newRecord]);
          },
        )
        .subscribe((status, _) {
          // (Re)connected: catch up on anything missed while away.
          if (status == RealtimeSubscribeStatus.subscribed) unawaited(syncNow());
        });
    _pullTimer = Timer.periodic(const Duration(minutes: 2), (_) => unawaited(syncNow()));
    unawaited(syncNow());
  }

  Future<void> syncNow() async {
    await _push();
    await _pull();
  }

  Future<void> _pull() async {
    try {
      final since = (_cursor ?? DateTime.utc(2000)).toIso8601String();
      final rows = await fetchAll(
        (from, to) => _client
            .from('ideas')
            .select()
            .gt('updated_at', since)
            .order('updated_at', ascending: true)
            .order('id', ascending: true)
            .range(from, to),
      );
      _merge(rows);
      if (!_ideas.values.any((i) => i.dirty)) _setSync(SyncState.synced);
    } on Object catch (e) {
      debugPrint('Džep: pull failed: $e');
      _setSync(SyncState.offline);
    }
  }

  void _merge(List<Map<String, dynamic>> rows) {
    if (_closed || rows.isEmpty) return;
    for (final row in rows) {
      final incoming = Idea.fromServer(row);
      final local = _ideas[incoming.id];
      // Unpushed local edits win; the push that follows overwrites the server.
      // Known ideas update in place: open screens hold these objects, and an
      // edit made on a replaced one would never be pushed.
      if (local == null) {
        _ideas[incoming.id] = incoming;
      } else if (!local.dirty) {
        local.absorb(incoming);
      }
      if (_cursor == null || incoming.updatedAt.isAfter(_cursor!)) _cursor = incoming.updatedAt;
    }
    notifyListeners();
    _scheduleSave();
  }

  Future<void> _push() async {
    if (_pushing || _closed) return;
    final dirty = _ideas.values.where((i) => i.dirty).toList();
    if (dirty.isEmpty) return;
    _pushing = true;
    _setSync(SyncState.syncing);
    final revs = {for (final i in dirty) i.id: i.rev};
    try {
      final rows = await _client.from('ideas').upsert([for (final i in dirty) i.toServer()]).select();
      for (final row in rows) {
        final local = _ideas[row['id']];
        if (local == null) continue;
        local.updatedAt = DateTime.parse(row['updated_at'] as String);
        // Edited again while this push was in flight: stays dirty for the next.
        if (local.rev == revs[local.id]) local.dirty = false;
      }
      _scheduleSave();
      _setSync(_ideas.values.any((i) => i.dirty) ? SyncState.syncing : SyncState.synced);
    } on Object catch (e) {
      debugPrint('Džep: push failed: $e');
      _setSync(SyncState.offline);
      // Retry later; the edits are safe on disk.
      _pushTimer?.cancel();
      _pushTimer = Timer(const Duration(seconds: 20), _push);
    } finally {
      _pushing = false;
    }
    if (_ideas.values.any((i) => i.dirty) && _syncState != SyncState.offline) unawaited(_push());
  }

  void _setSync(SyncState s) {
    if (s == _syncState) return;
    _syncState = s;
    notifyListeners();
  }

  /// Stops syncing and flushes the cache (sign-out, quit).
  Future<void> close() async {
    _closed = true;
    _pushTimer?.cancel();
    _pullTimer?.cancel();
    _saveTimer?.cancel();
    await _save();
    final channel = _channel;
    if (channel != null) await _client.removeChannel(channel);
  }
}
