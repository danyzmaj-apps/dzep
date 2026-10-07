import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

/// One turn of a conversation; an answer grows while it streams.
class ChatMessage {
  ChatMessage({required this.fromUser, this.text = '', this.error});

  factory ChatMessage.fromJson(Map<String, dynamic> j) =>
      ChatMessage(fromUser: j['user'] == true, text: j['text'] as String? ?? '', error: j['error'] as String?);

  final bool fromUser;
  String text;

  /// Set when the answer failed; the turn is left out of later requests.
  String? error;

  Map<String, dynamic> toJson() => {'user': fromUser, 'text': text, 'error': ?error};
}

/// A saved quick-question chat.
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
  final DateTime createdAt;
  DateTime updatedAt;
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

/// Quick questions (4 in the popup, Chats in the main window): DeepSeek's
/// OpenAI-compatible chat API, streamed. Conversations are kept on this Mac
/// (`chats.json` next to the ideas cache) so any of them can be continued.
class Chat extends ChangeNotifier {
  Chat(this._key);

  /// The API key from Settings, read on every send.
  final String Function() _key;

  static final Uri _endpoint = Uri.parse('https://api.deepseek.com/chat/completions');
  static const model = 'deepseek-flash';

  /// Newest activity first.
  List<Conversation> get conversations => _conversations;
  final List<Conversation> _conversations = [];

  /// The conversation the popup shows; null for a fresh one.
  Conversation? get current => _current;
  Conversation? _current;

  /// The conversation an answer is streaming into.
  Conversation? get streaming => _streaming;
  Conversation? _streaming;
  HttpClient? _client;

  bool get busy => _streaming != null;

  /// A DeepSeek key is set in Settings.
  bool get hasKey => _key().isNotEmpty;

  File? _file;
  Timer? _saveTimer;

  Future<void> load(File file) async {
    _file = file;
    try {
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      _conversations
        ..clear()
        ..addAll([for (final c in json['conversations'] as List) Conversation.fromJson(c as Map<String, dynamic>)]);
      notifyListeners();
    } on PathNotFoundException {
      // First run.
    } on Object catch (e) {
      debugPrint('Džep: unreadable chats file: $e');
    }
  }

  /// The popup starts over; the old conversation stays in Chats.
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
    _conversations.remove(c);
    if (_current == c) _current = null;
    _scheduleSave();
    notifyListeners();
  }

  /// Asks [text] in [into] (default: the popup's conversation, or a new one),
  /// which becomes the current conversation.
  Future<void> send(String text, {Conversation? into}) async {
    final key = _key();
    final question = text.trim();
    if (key.isEmpty || busy || question.isEmpty) return;
    final now = DateTime.now();
    final c = into ?? _current ?? Conversation(id: const Uuid().v4(), createdAt: now, updatedAt: now);
    if (!_conversations.contains(c)) _conversations.insert(0, c);
    _current = c;
    c.messages.add(ChatMessage(fromUser: true, text: question));
    _touch(c);
    final history = [
      {'role': 'system', 'content': _system()},
      for (final m in c.messages)
        if (m.error == null && m.text.isNotEmpty) {'role': m.fromUser ? 'user' : 'assistant', 'content': m.text},
    ];
    final reply = ChatMessage(fromUser: false);
    c.messages.add(reply);
    final client = _client = HttpClient();
    _streaming = c;
    notifyListeners();
    try {
      final req = await client.postUrl(_endpoint);
      req.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer $key')
        ..contentType = ContentType.json;
      req.add(
        utf8.encode(
          jsonEncode({
            'model': model,
            'stream': true,
            // A quick answer, not a pondered one.
            'thinking': {'type': 'disabled'},
            'messages': history,
          }),
        ),
      );
      final res = await req.close();
      if (res.statusCode != HttpStatus.ok) {
        throw _ChatError(_describe(res.statusCode, await utf8.decodeStream(res)));
      }
      // Server-sent events: `data: {chunk}` lines, then `data: [DONE]`.
      await for (final line in res.transform(utf8.decoder).transform(const LineSplitter())) {
        if (_client != client) return;
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data == '[DONE]') break;
        if (jsonDecode(data) case {'choices': [{'delta': {'content': final String chunk}}, ...]}
            when chunk.isNotEmpty) {
          reply.text += chunk;
          notifyListeners();
        }
      }
      if (reply.text.isEmpty) throw const _ChatError('DeepSeek sent an empty answer.');
    } on Object catch (e) {
      if (_client != client) return;
      reply.error = e is _ChatError ? e.message : 'Couldn’t reach DeepSeek: $e';
    } finally {
      client.close(force: true);
      if (_client == client) {
        _client = null;
        _streaming = null;
        _touch(c);
        notifyListeners();
      }
    }
  }

  /// Stops the streaming answer, keeping what arrived.
  void _stop() {
    _client?.close(force: true);
    _client = null;
    _streaming = null;
  }

  void _touch(Conversation c) {
    c.updatedAt = DateTime.now();
    _conversations
      ..remove(c)
      ..insert(0, c);
    _scheduleSave();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 250), () => unawaited(_save()));
  }

  Future<void> _save() async {
    final file = _file;
    if (file == null) return;
    final json = jsonEncode({
      'conversations': [for (final c in _conversations) c.toJson()],
    });
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(json, flush: true);
    await tmp.rename(file.path);
  }

  String _system() {
    final now = DateTime.now();
    final today = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    return 'You answer quick questions from a software developer in a small popup on their Mac. '
        'Be brief and direct: lead with the answer, skip preamble. '
        'Use Markdown only when it helps (code blocks for code, short lists). Today is $today.';
  }

  static String _describe(int status, String body) {
    final message = switch (_tryDecode(body)) {
      {'error': {'message': final String m}} => m,
      _ => body.trim(),
    };
    return switch (status) {
      HttpStatus.unauthorized => 'DeepSeek rejected the API key (Settings in the main window).',
      HttpStatus.paymentRequired => 'DeepSeek: insufficient balance.',
      _ => 'DeepSeek error $status${message.isEmpty ? '' : ': $message'}',
    };
  }

  static Object? _tryDecode(String body) {
    try {
      return jsonDecode(body);
    } on FormatException {
      return null;
    }
  }
}

class _ChatError implements Exception {
  const _ChatError(this.message);
  final String message;
}
