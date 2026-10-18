import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dzep_core/store.dart' show fetchAll, refreshIfExpired;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

/// One turn of a conversation; an answer grows while it streams. A question
/// may carry images: their paths in the private `chat` bucket.
class ChatMessage {
  ChatMessage({required this.fromUser, this.text = '', this.error, this.images = const []});

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
    fromUser: j['user'] == true,
    text: j['text'] as String? ?? '',
    error: j['error'] as String?,
    images: [for (final p in j['images'] as List? ?? const []) p as String],
  );

  factory ChatMessage.fromServer(Map<String, dynamic> row) => ChatMessage(
    fromUser: row['role'] == 'user',
    text: row['content'] as String? ?? '',
    error: row['error'] as String?,
    images: [for (final p in row['images'] as List? ?? const []) p as String],
  );

  final bool fromUser;
  String text;

  /// Set when the answer failed.
  String? error;

  final List<String> images;

  Map<String, dynamic> toJson() => {
    'user': fromUser,
    'text': text,
    'error': ?error,
    if (images.isNotEmpty) 'images': images,
  };
}

/// The private Storage bucket chat images live in (`<user id>/<uuid>.<ext>`).
const chatImageBucket = 'chat';

/// An image about to be asked about: its bytes and their type.
class ChatImage {
  const ChatImage(this.bytes, this.mime);
  final Uint8List bytes;

  /// image/png, image/jpeg, image/gif or image/webp.
  final String mime;

  String get extension => switch (mime) {
    'image/jpeg' => 'jpg',
    'image/gif' => 'gif',
    'image/webp' => 'webp',
    _ => 'png',
  };
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
    final first = messages.where((m) => m.fromUser).firstOrNull;
    final line = (first?.text ?? '').split('\n').first.trim();
    if (line.isEmpty) return first != null && first.images.isNotEmpty ? 'Image' : 'New chat';
    return line;
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

/// Whether the server can answer questions: the `ask` function has an AI
/// key. Its `{"action": "status"}` answer, also as cached.
@immutable
class AiStatus {
  const AiStatus({required this.connected, this.model, this.baseUrl});

  /// Null when [json] isn't a status (an older server answers the status
  /// request with an error).
  static AiStatus? fromJson(Object? json) => switch (json) {
    {'configured': final bool connected} => AiStatus(
      connected: connected,
      model: json['model'] as String?,
      baseUrl: json['base_url'] as String?,
    ),
    _ => null,
  };

  final bool connected;
  final String? model;

  /// The provider's API, e.g. `https://api.deepseek.com`.
  final String? baseUrl;

  Map<String, dynamic> toJson() => {'configured': connected, 'model': ?model, 'base_url': ?baseUrl};

  @override
  bool operator ==(Object other) =>
      other is AiStatus && other.connected == connected && other.model == model && other.baseUrl == baseUrl;

  @override
  int get hashCode => Object.hash(connected, model, baseUrl);
}

/// The signed-in user's quick-question chats, on the Mac and the phone.
/// Questions go to the `ask` edge function (supabase/functions/ask), which
/// holds the AI provider's key, saves both turns and streams the answer back;
/// this store shows the stream and keeps every chat current through a cursor
/// pull on `chats` (a new message moves its chat's `updated_at`) and
/// realtime. A local cache shows them offline.
class ChatStore extends ChangeNotifier {
  ChatStore._(this._client, this.userId, this._file);

  static Future<ChatStore> open(SupabaseClient client, String userId) async {
    final dir = await getApplicationSupportDirectory();
    final store = await cached(client, userId, File('${dir.path}/chats-$userId.json'));
    store._start();
    return store;
  }

  /// The store as its cache [file] has it, not syncing yet ([open] starts
  /// that).
  @visibleForTesting
  static Future<ChatStore> cached(SupabaseClient client, String userId, File file) async {
    final store = ChatStore._(client, userId, file);
    await store._load();
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

  /// What the server last said about its AI; null until it has said (an
  /// older server never does, and Ask then works as it always did).
  AiStatus? get ai => _ai;
  AiStatus? _ai;

  /// The server has no AI connected: Ask shows how to connect one instead
  /// of a question field that would fail.
  bool get aiMissing => _ai?.connected == false;

  /// Asks the server whether Ask is set up; when it can't be reached (or
  /// can't say) the last answer stands.
  Future<AiStatus?> checkAi() async {
    if (_closed) return _ai;
    try {
      final res = await _client.functions.invoke('ask', body: {'action': 'status'});
      final status = AiStatus.fromJson(res.data);
      if (status != null) _setAi(status);
    } on Object catch (e) {
      debugPrint('Džep: AI status unknown: $e');
    }
    return _ai;
  }

  void _setAi(AiStatus status) {
    if (status == _ai || _closed) return;
    _ai = status;
    notifyListeners();
    _scheduleSave();
  }

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
    unawaited(_deletesPushed = _pushDeletes());
  }

  /// The delete in flight, so [restore] lands after it.
  Future<void> _deletesPushed = Future.value();

  /// Undoes [delete]: [c] is back in the list, and on the server once the
  /// delete has reached it.
  Future<void> restore(Conversation c) async {
    if (_closed) return;
    _chats[c.id] = c;
    _deletes.remove(c.id);
    notifyListeners();
    _scheduleSave();
    await _deletesPushed;
    try {
      await _client.from('chats').update({'deleted_at': null}).eq('id', c.id);
    } on Object catch (e) {
      debugPrint('Džep: chat restore not pushed: $e');
    }
  }

  /// Asks [text] (and [images]) in [into] (default: the current
  /// conversation, or a new one), which becomes the current conversation.
  Future<void> send(String text, {Conversation? into, List<ChatImage> images = const []}) async {
    final question = text.trim();
    if (busy || (question.isEmpty && images.isEmpty) || _closed || aiMissing) return;
    final now = DateTime.now().toUtc();
    final c = into ?? _current ?? Conversation(id: const Uuid().v4(), createdAt: now, updatedAt: now);
    _chats[c.id] = c;
    _deletes.remove(c.id);
    _current = c;
    final paths = [for (final i in images) '$userId/${const Uuid().v4()}.${i.extension}'];
    // Shown from memory at once; the upload below makes them real.
    for (final (k, path) in paths.indexed) {
      _images[path] = Future.value(images[k].bytes);
    }
    c
      ..messages.add(ChatMessage(fromUser: true, text: question, images: paths))
      ..updatedAt = now;
    final reply = ChatMessage(fromUser: false);
    c.messages.add(reply);
    final abort = _abort = Completer<void>();
    _streaming = c;
    notifyListeners();
    // Only once the server has the question may a refetch replace these turns.
    var asked = false;
    try {
      try {
        await Future.wait([
          for (final (k, path) in paths.indexed)
            _client.storage
                .from(chatImageBucket)
                .uploadBinary(path, images[k].bytes, fileOptions: FileOptions(contentType: images[k].mime)),
        ]);
      } on Object catch (e) {
        if (_abort != abort) return;
        reply.error = switch (e) {
          StorageException(:final message) => 'The image didn’t upload: $message',
          _ => 'The image didn’t upload. Check your connection.',
        };
        return;
      }
      if (_abort != abort) return;
      asked = true;
      final res = await _client.functions.invoke(
        'ask',
        body: {'chat_id': c.id, 'question': question, if (paths.isNotEmpty) 'images': paths},
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
      if (e case FunctionException(details: {'configured': false})) {
        // The server saved nothing, so the images it would have kept go.
        if (paths.isNotEmpty) unawaited(_removeImages(paths));
        _setAi(const AiStatus(connected: false));
      }
    } finally {
      if (_abort == abort) {
        _abort = null;
        _streaming = null;
        notifyListeners();
        _scheduleSave();
        // Swap the streamed turns for the saved ones.
        if (asked) unawaited(_pull(refetch: c.id));
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

  Future<void> _removeImages(List<String> paths) async {
    try {
      await _client.storage.from(chatImageBucket).remove(paths);
    } on Object catch (e) {
      debugPrint('Džep: unused chat images not removed: $e');
    }
  }

  /// Image bytes by bucket path, fetched once per run (with the user's
  /// session: the bucket is private).
  final Map<String, Future<Uint8List>> _images = {};

  Future<Uint8List> image(String path) => _images.putIfAbsent(path, () async {
    try {
      return await _client.storage.from(chatImageBucket).download(path);
    } on Object {
      // A failed load may work later (offline now); don't keep the failure.
      unawaited(_images.remove(path));
      rethrow;
    }
  });

  // ---------------------------------------------------------------- disk

  Future<void> _load() async {
    if (!_file.existsSync()) return;
    try {
      final json = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
      final cursor = json['cursor'] as String?;
      _cursor = cursor == null ? null : DateTime.parse(cursor);
      _deletes.addAll([for (final id in json['deletes'] as List? ?? const []) id as String]);
      _ai = AiStatus.fromJson(json['ai']);
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
      'ai': ?_ai?.toJson(),
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
    // Until an AI is connected, each round also asks again: one set up
    // elsewhere (another Mac, the CLI) shows up by itself.
    _pullTimer = Timer.periodic(const Duration(minutes: 2), (_) {
      unawaited(syncNow());
      if (aiMissing) unawaited(checkAi());
    });
    unawaited(syncNow());
    unawaited(checkAi());
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
      final since = (_cursor ?? DateTime.utc(2000)).toIso8601String();
      final rows = await fetchAll(
        (from, to) => _client
            .from('chats')
            .select()
            .gt('updated_at', since)
            .order('updated_at', ascending: true)
            .order('id', ascending: true)
            .range(from, to),
      );
      if (refetch != null && !rows.any((r) => r['id'] == refetch)) {
        rows.addAll(await _client.from('chats').select().eq('id', refetch));
      }
      final ids = [
        for (final r in rows)
          if (r['deleted_at'] == null) r['id'] as String,
      ];
      // In chunks: the ids travel in the URL.
      final messages = <Map<String, dynamic>>[];
      for (var i = 0; i < ids.length; i += 100) {
        final chunk = ids.sublist(i, min(i + 100, ids.length));
        messages.addAll(
          await fetchAll(
            (from, to) => _client
                .from('chat_messages')
                .select('chat_id, role, content, error, images, created_at')
                .inFilter('chat_id', chunk)
                // postgrest's order() is newest first unless told otherwise.
                .order('created_at', ascending: true)
                .order('id', ascending: true)
                .range(from, to),
          ),
        );
      }
      _merge(rows, messages);
    } on Object catch (e) {
      debugPrint('Džep: chats pull failed: $e');
      // The next pull carries the fresh token.
      unawaited(refreshIfExpired(_client, e));
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
