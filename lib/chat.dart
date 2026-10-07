import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

/// One turn of a conversation; an answer grows while it streams.
class ChatMessage {
  ChatMessage({required this.fromUser, this.text = '', this.error});

  factory ChatMessage.fromJson(Map<String, dynamic> j) =>
      ChatMessage(fromUser: j['user'] == true, text: j['text'] as String? ?? '', error: j['error'] as String?);

  factory ChatMessage.fromServer(Map<String, dynamic> row) => ChatMessage(
    fromUser: row['role'] == 'user',
    text: row['content'] as String? ?? '',
    error: row['error'] as String?,
  );

  final bool fromUser;
  String text;

  /// Set when the answer failed.
  String? error;

  Map<String, dynamic> toJson() => {'user': fromUser, 'text': text, 'error': ?error};
}

/// A quick-question chat (rows of `chats` + `chat_messages`).
class Conversation {
  Conversation({required this.id, required this.createdAt, required this.updatedAt, List<ChatMessage>? messages})
    : messages = messages ?? [];

  factory Conversation.fromJson(Map<String, dynamic> j) => Conversation(
    id: j['id'] as String,
    createdAt: DateTime.parse(j['createdAt'] as String),
    updatedAt: DateTime.parse(j['updatedAt'] as String),
    messages: [for (final m in j['messages'] as List) ChatMessage.fromJson(m as Map<String, dynamic>)],
  );

  final String id;
  DateTime createdAt;
  DateTime updatedAt;

  /// Replaced in place on sync: open screens hold this list.
  final List<ChatMessage> messages;

  /// The first question's first line.
  String get title {
    final first = messages.where((m) => m.fromUser).firstOrNull?.text ?? '';
    final line = first.split('\n').first.trim();
    return line.isEmpty ? 'New chat' : line;
  }

  /// The last answer that came through.
  String? get lastAnswer {
    for (final m in messages.reversed) {
      if (!m.fromUser && m.error == null && m.text.isNotEmpty) return m.text;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'messages': [for (final m in messages) m.toJson()],
  };
}

/// The signed-in user's quick-question chats, on the Mac and the iPhone.
/// Questions go to the `ask` edge function (supabase/functions/ask), which
/// holds the DeepSeek key, saves both turns and streams the answer back; this
/// store shows the stream and keeps every chat current through a cursor pull
/// on `chats` (a new message moves its chat's `updated_at`) and realtime. A
/// local cache shows them offline.
class ChatStore extends ChangeNotifier {
  ChatStore._(this._client, this.userId, this._file);

  static Future<ChatStore> open(SupabaseClient client, String userId) async {
    final dir = await getApplicationSupportDirectory();
    final store = ChatStore._(client, userId, File('${dir.path}/chats-$userId.json'));
    await store._load();
    store._start();
    return store;
  }

  final SupabaseClient _client;
  final String userId;
  final File _file;

  final Map<String, Conversation> _chats = {};
  DateTime? _cursor;

  /// Chats deleted here that the server hasn't heard about yet.
  final Set<String> _deletes = {};

  RealtimeChannel? _channel;
  Timer? _saveTimer;
  Timer? _pullTimer;
  Timer? _pullSoon;
  bool _pulling = false;
  bool _pullAgain = false;
  bool _closed = false;

  /// Newest activity first.
  List<Conversation> get conversations => _chats.values.toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  Conversation? byId(String id) => _chats[id];

  /// The conversation the popup shows; null for a fresh one.
  Conversation? get current => _current;
  Conversation? _current;

  /// The conversation an answer is streaming into.
  Conversation? get streaming => _streaming;
  Conversation? _streaming;

  /// Completes to stop the streaming answer (the server still saves it).
  Completer<void>? _abort;

  bool get busy => _streaming != null;

  /// The popup starts over; the old conversation stays in the list.
  void newChat() {
    _current = null;
    notifyListeners();
  }

  /// Makes [c] the popup's conversation.
  void resume(Conversation c) {
    _current = c;
    notifyListeners();
  }

  void delete(Conversation c) {
    if (_streaming == c) _stop();
    _chats.remove(c.id);
    _deletes.add(c.id);
    if (_current == c) _current = null;
    notifyListeners();
    _scheduleSave();
    unawaited(_pushDeletes());
  }

  /// Asks [text] in [into] (default: the current conversation, or a new
  /// one), which becomes the current conversation.
  Future<void> send(String text, {Conversation? into}) async {
    final question = text.trim();
    if (busy || question.isEmpty || _closed) return;
    final now = DateTime.now().toUtc();
    final c = into ?? _current ?? Conversation(id: const Uuid().v4(), createdAt: now, updatedAt: now);
    _chats[c.id] = c;
    _deletes.remove(c.id);
    _current = c;
    c
      ..messages.add(ChatMessage(fromUser: true, text: question))
      ..updatedAt = now;
    final reply = ChatMessage(fromUser: false);
    c.messages.add(reply);
    final abort = _abort = Completer<void>();
    _streaming = c;
    notifyListeners();
    try {
      final res = await _client.functions.invoke(
        'ask',
        body: {'chat_id': c.id, 'question': question},
        abortSignal: abort.future,
      );
      final stream = res.data as Stream<List<int>>;
      await for (final line in stream.transform(utf8.decoder).transform(const LineSplitter())) {
        if (_abort != abort) return;
        if (!line.startsWith('data:')) continue;
        switch (jsonDecode(line.substring(5))) {
          case {'delta': final String delta}:
            reply.text += delta;
            notifyListeners();
          case {'error': final String message}:
            reply.error = message;
        }
      }
      if (reply.text.isEmpty) reply.error ??= 'The answer was cut off.';
    } on Object catch (e) {
      if (_abort != abort) return;
      reply.error = switch (e) {
        FunctionException(details: {'error': final String message}) => message,
        FunctionsFetchException() => 'Couldn’t reach the server. Check your connection.',
        FunctionException(:final status) => 'The server failed ($status).',
        _ => 'Couldn’t get an answer: $e',
      };
    } finally {
      if (_abort == abort) {
        _abort = null;
        _streaming = null;
        notifyListeners();
        _scheduleSave();
        // Swap the streamed turns for the saved ones.
        unawaited(_pull(refetch: c.id));
      }
    }
  }

  /// Stops the streaming answer; the server still saves it and the next pull
  /// brings it.
  void _stop() {
    final abort = _abort;
    _abort = null;
    _streaming = null;
    if (abort != null && !abort.isCompleted) abort.complete();
  }

  // ---------------------------------------------------------------- disk

  Future<void> _load() async {
    if (!_file.existsSync()) return;
    try {
      final json = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
      final cursor = json['cursor'] as String?;
      _cursor = cursor == null ? null : DateTime.parse(cursor);
      _deletes.addAll([for (final id in json['deletes'] as List? ?? const []) id as String]);
      for (final raw in json['chats'] as List) {
        final c = Conversation.fromJson(raw as Map<String, dynamic>);
        _chats[c.id] = c;
      }
    } on Object catch (e) {
      // Only a cache: the server has every chat.
      debugPrint('Džep: chats cache unreadable ($e), starting from the server');
      _cursor = null;
      _chats.clear();
    }
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 250), () => unawaited(_save()));
  }

  Future<void> _save() async {
    final json = jsonEncode({
      'cursor': _cursor?.toUtc().toIso8601String(),
      'deletes': _deletes.toList(),
      'chats': [for (final c in _chats.values) c.toJson()],
    });
    await _file.parent.create(recursive: true);
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(json, flush: true);
    await tmp.rename(_file.path);
  }

  // ---------------------------------------------------------------- sync

  void _start() {
    _channel = _client
        .channel('chats-$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'chats',
          filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'user_id', value: userId),
          callback: (_) {
            // A burst (question, answer) becomes one pull.
            _pullSoon?.cancel();
            _pullSoon = Timer(const Duration(milliseconds: 300), () => unawaited(syncNow()));
          },
        )
        .subscribe((status, _) {
          if (status == RealtimeSubscribeStatus.subscribed) unawaited(syncNow());
        });
    _pullTimer = Timer.periodic(const Duration(minutes: 2), (_) => unawaited(syncNow()));
    unawaited(syncNow());
  }

  Future<void> syncNow() async {
    await _pushDeletes();
    await _pull();
  }

  Future<void> _pushDeletes() async {
    if (_deletes.isEmpty || _closed) return;
    final ids = _deletes.toList();
    try {
      await _client.from('chats').update({'deleted_at': DateTime.now().toUtc().toIso8601String()}).inFilter('id', ids);
      _deletes.removeAll(ids);
      _scheduleSave();
    } on Object catch (e) {
      debugPrint('Džep: chat delete not pushed yet: $e');
    }
  }

  /// Chats changed since the cursor, each with all its messages; [refetch]
  /// also brings that one chat whatever the cursor says.
  Future<void> _pull({String? refetch}) async {
    if (_closed) return;
    if (_pulling) {
      _pullAgain = true;
      return;
    }
    _pulling = true;
    try {
      final rows = [
        ...await _client
            .from('chats')
            .select()
            .gt('updated_at', (_cursor ?? DateTime.utc(2000)).toIso8601String())
            .order('updated_at', ascending: true),
      ];
      if (refetch != null && !rows.any((r) => r['id'] == refetch)) {
        rows.addAll(await _client.from('chats').select().eq('id', refetch));
      }
      final ids = [
        for (final r in rows)
          if (r['deleted_at'] == null) r['id'] as String,
      ];
      final messages = ids.isEmpty
          ? const <Map<String, dynamic>>[]
          : await _client
                .from('chat_messages')
                .select('chat_id, role, content, error, created_at')
                .inFilter('chat_id', ids)
                // postgrest's order() is newest first unless told otherwise.
                .order('created_at', ascending: true);
      _merge(rows, messages);
    } on Object catch (e) {
      debugPrint('Džep: chats pull failed: $e');
    } finally {
      _pulling = false;
    }
    if (_pullAgain) {
      _pullAgain = false;
      unawaited(_pull());
    }
  }

  void _merge(List<Map<String, dynamic>> rows, List<Map<String, dynamic>> messages) {
    if (_closed || rows.isEmpty) return;
    final byChat = <String, List<ChatMessage>>{};
    for (final m in messages) {
      (byChat[m['chat_id'] as String] ??= []).add(ChatMessage.fromServer(m));
    }
    for (final row in rows) {
      final id = row['id'] as String;
      final updatedAt = DateTime.parse(row['updated_at'] as String);
      if (_cursor == null || updatedAt.isAfter(_cursor!)) _cursor = updatedAt;
      if (_deletes.contains(id)) continue;
      if (row['deleted_at'] != null) {
        final gone = _chats.remove(id);
        if (gone != null && _current == gone) _current = null;
        if (gone != null && _streaming == gone) _stop();
        continue;
      }
      final known = _chats[id];
      final c =
          known ?? Conversation(id: id, createdAt: DateTime.parse(row['created_at'] as String), updatedAt: updatedAt);
      _chats[id] = c;
      known?.updatedAt = updatedAt;
      // The streaming chat keeps its live turns; it's refetched when done.
      if (c == _streaming) continue;
      c.messages
        ..clear()
        ..addAll(byChat[id] ?? const []);
    }
    notifyListeners();
    _scheduleSave();
  }

  /// Stops syncing and flushes the cache (sign-out, quit).
  Future<void> close() async {
    _closed = true;
    _stop();
    _pullTimer?.cancel();
    _pullSoon?.cancel();
    _saveTimer?.cancel();
    await _save();
    final channel = _channel;
    if (channel != null) await _client.removeChannel(channel);
  }
}
