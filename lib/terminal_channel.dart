import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Receives one broadcast: the payload's fields at the top level, next to
/// `event` and `type`.
typedef TopicHandler = void Function(Map<String, dynamic> payload);

/// The private Realtime topic `terminal:<user id>` (RLS: the user's own
/// topic only), kept joined while open.
///
/// realtime_client drops a channel for good once the server closes it, and a
/// rejoin with a token that expired while the Mac slept or the phone was away
/// is refused for good: the channel then looks subscribed and carries
/// nothing. So whenever the channel isn't joined (an error, a close, a join
/// that times out or never answers), this makes a new one, with a fresh token,
/// after 1 s, 2 s, 4 s … up to [_maxWait].
class TerminalChannel {
  TerminalChannel(this._client, this._userId, this._handlers, {required this.name, this.onJoined});

  final SupabaseClient _client;
  final String _userId;
  final Map<String, TopicHandler> _handlers;

  /// Who this is, in the log.
  final String name;

  /// The channel joined (true), or stopped being joined (false).
  final void Function({required bool joined})? onJoined;

  static const _firstWait = Duration(seconds: 1);
  static const _maxWait = Duration(seconds: 30);

  /// How often to look for a channel that isn't joined, and how long a join
  /// may take before it counts as stuck.
  static const _check = Duration(seconds: 10);
  static const _stuck = Duration(seconds: 20);

  RealtimeChannel? _ch;
  DateTime _joinedAt = DateTime.now();
  bool _open = false;
  bool _joining = false;
  bool _joined = false;
  Timer? _retry;
  Timer? _watchdog;
  Duration _wait = _firstWait;

  /// Bumped by [open] and [close]: a join still waiting on a token from
  /// before (the app left and came back within it) must not make a second
  /// channel; realtime_client delivers a topic to every channel on it.
  int _gen = 0;

  bool get joined => _joined;

  void open() {
    if (_open) return;
    _open = true;
    final gen = ++_gen;
    debugPrint('Džep: $name: open');
    _wait = _firstWait;
    unawaited(_join(gen));
    _watchdog = Timer.periodic(_check, (_) {
      // A join that never got an answer, not even a timeout.
      if (!_open || _joining || _retry != null || _ch == null || _joined) return;
      if (DateTime.now().difference(_joinedAt) >= _stuck) _again('no answer to the join');
    });
  }

  Future<void> close() async {
    if (!_open) return;
    _open = false;
    _gen++;
    debugPrint('Džep: $name: close');
    _watchdog?.cancel();
    _retry?.cancel();
    _watchdog = null;
    _retry = null;
    _setJoined(joined: false);
    final ch = _ch;
    _ch = null;
    if (ch != null) await _client.removeChannel(ch);
  }

  /// Drops [event] if the channel isn't joined: whoever waits on an answer
  /// times out, and the other side catches up after the next join.
  Future<void> send(String event, Map<String, dynamic> payload) async {
    final ch = _ch;
    if (ch == null || !_joined) return;
    await ch.sendBroadcastMessage(event: event, payload: payload);
  }

  Future<void> _join(int gen) async {
    bool stale() => !_open || gen != _gen;
    _joining = true;
    try {
      // A token that expired while asleep would be refused.
      if (_client.auth.currentSession?.isExpired ?? false) {
        try {
          await _client.auth.refreshSession();
        } on Object catch (e) {
          debugPrint('Džep: $name: token refresh: $e');
        }
      }
      if (stale()) return;
      final token = _client.auth.currentSession?.accessToken;
      if (token != null) await _client.realtime.setAuth(token);
      if (stale()) return;
      final ch = _client.channel('terminal:$_userId', opts: const RealtimeChannelConfig(private: true));
      for (final MapEntry(:key, :value) in _handlers.entries) {
        ch.onBroadcast(event: key, callback: value);
      }
      _ch = ch;
      _joinedAt = DateTime.now();
      ch.subscribe((status, error) {
        // A channel already replaced (its close comes after removeChannel).
        if (!identical(_ch, ch)) return;
        debugPrint('Džep: $name: ${status.name}${error == null ? '' : ' $error'}');
        if (status == RealtimeSubscribeStatus.subscribed) {
          _wait = _firstWait;
          _setJoined(joined: true);
        } else {
          _again(status.name);
        }
      });
    } on Object catch (e) {
      if (!stale()) _again('$e');
    } finally {
      if (gen == _gen) _joining = false;
    }
  }

  void _again(String why) {
    if (!_open || _retry != null) return;
    _setJoined(joined: false);
    final old = _ch;
    _ch = null;
    if (old != null) {
      unawaited(_client.removeChannel(old).then((_) {}, onError: (Object e) => debugPrint('Džep: $name: $e')));
    }
    final wait = _wait;
    _wait = _wait * 2 > _maxWait ? _maxWait : _wait * 2;
    debugPrint('Džep: $name: joining again in ${wait.inSeconds} s ($why)');
    final gen = _gen;
    _retry = Timer(wait, () {
      _retry = null;
      if (gen == _gen) unawaited(_join(gen));
    });
  }

  void _setJoined({required bool joined}) {
    if (_joined == joined) return;
    _joined = joined;
    debugPrint('Džep: $name: ${joined ? 'joined' : 'not joined'}');
    onJoined?.call(joined: joined);
  }
}
