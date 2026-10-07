import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// One turn of the quick-question chat; an answer grows while it streams.
class ChatMessage {
  ChatMessage({required this.fromUser, this.text = ''});
  final bool fromUser;
  String text;

  /// Set when the answer failed; the turn is left out of later requests.
  String? error;
}

/// The popup's quick question (4 in the chooser): DeepSeek's
/// OpenAI-compatible chat API, streamed. It lives on the controller, so a
/// conversation survives hiding the popup; [clear] starts over.
class Chat extends ChangeNotifier {
  Chat(this._key);

  /// The API key from Settings, read on every send.
  final String Function() _key;

  static final Uri _endpoint = Uri.parse('https://api.deepseek.com/chat/completions');
  static const model = 'deepseek-flash';

  final List<ChatMessage> messages = [];

  /// An answer is streaming.
  bool get busy => _client != null;
  HttpClient? _client;

  /// Bumped by [clear]; a stream from an older conversation stops writing.
  int _gen = 0;

  Future<void> send(String text) async {
    final key = _key();
    final question = text.trim();
    if (key.isEmpty || busy || question.isEmpty) return;
    messages.add(ChatMessage(fromUser: true, text: question));
    final history = [
      {'role': 'system', 'content': _system()},
      for (final m in messages)
        if (m.error == null && m.text.isNotEmpty) {'role': m.fromUser ? 'user' : 'assistant', 'content': m.text},
    ];
    final reply = ChatMessage(fromUser: false);
    messages.add(reply);
    final gen = _gen;
    final client = _client = HttpClient();
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
        if (gen != _gen) return;
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
      if (gen != _gen) return;
      reply.error = e is _ChatError ? e.message : 'Couldn’t reach DeepSeek: $e';
    } finally {
      client.close(force: true);
      if (gen == _gen) {
        _client = null;
        notifyListeners();
      }
    }
  }

  /// Drops the conversation and stops a streaming answer.
  void clear() {
    _gen++;
    _client?.close(force: true);
    _client = null;
    messages.clear();
    notifyListeners();
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
