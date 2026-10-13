import 'dart:async';

import 'package:dzep_core/live.dart';
import 'package:dzep_core/native.dart';
import 'package:dzep_core/terminal_remote.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// omp sessions as iPhone Live Activities (Lock Screen, Dynamic Island):
// ios/Shared/OmpActivity.swift. The app starts one when a prompt goes out
// from the phone or on "Follow on Lock Screen", and updates it itself while
// it's in front; otherwise the Mac tells the server (functions/push
// {action: activity}) and the server pushes to the activity's token. A push
// carries only what's below, never text: a Live Activity push can't be
// decrypted on the phone, so the relay would read it.

enum ActivityState { working, needs, done, ended }

/// What omp waits for, when it needs you.
enum ActivityKind { question, approval, plan }

typedef ActivityStatus = ({ActivityState state, ActivityKind? kind});

/// What a session's activity shows: omp asks something, works, or has
/// stopped (done). A picker the person opened from the phone isn't omp
/// asking.
ActivityStatus activityStatus({required bool busy, LiveAsk? ask}) => switch (ask?.kind) {
  AskKind.questions => (state: ActivityState.needs, kind: ActivityKind.question),
  AskKind.approval => (state: ActivityState.needs, kind: ActivityKind.approval),
  AskKind.plan => (state: ActivityState.needs, kind: ActivityKind.plan),
  AskKind.menu || null => (state: busy ? ActivityState.working : ActivityState.done, kind: null),
};

/// The same for a session in the Mac's state; null: it's gone (ended).
ActivityStatus summaryStatus(LiveSummary? s) =>
    s == null ? (state: ActivityState.ended, kind: null) : activityStatus(busy: s.busy, ask: s.ask);

/// The `state` and `kind` of a push or a channel call.
Map<String, dynamic> activityJson(ActivityStatus s) => {'state': s.state.name, 'kind': ?s.kind?.name};

/// iPhone: the sessions followed on the Lock Screen, kept current from
/// [TerminalRemote] while the app is in front, and their push tokens handed
/// to the server.
class LiveActivities extends ChangeNotifier {
  LiveActivities(this._client, this._remote) {
    _remote.addListener(_sync);
    unawaited(_load());
  }

  final SupabaseClient _client;
  final TerminalRemote _remote;

  /// Followed sessions: what each activity shows and since when. Null: one
  /// still running from before this launch, which only pushes have updated.
  final _shown = <String, ({ActivityStatus status, DateTime since})?>{};

  /// When a prompt last went to a session: omp may not have reported busy
  /// yet, so for a while "done" is taken to be from before it.
  final _prompted = <String, DateTime>{};
  static const _promptWait = Duration(seconds: 30);

  /// Push tokens already given to the server.
  final _registered = <String>{};

  bool following(String key) => _shown.containsKey(key);

  /// The activities running from before (and tokens iOS handed over before
  /// Dart listened).
  Future<void> _load() async {
    try {
      for (final a in await Native.liveActivities()) {
        _shown.putIfAbsent(a.key, () => null);
        final token = a.token;
        if (token != null) unawaited(_register(a.key, token));
      }
    } on MissingPluginException {
      return; // Not on an iPhone.
    }
    _sync();
    notifyListeners();
  }

  /// Starts following [key], shown as [title]; [status] if known better
  /// than the Mac's state (a prompt just sent). False: Live Activities are
  /// off for Džep, or the session isn't there.
  Future<bool> follow(String key, {required String title, ActivityStatus? status}) async {
    final s = _remote.session(key);
    if (s == null) return false;
    final shown = (status: status ?? summaryStatus(s), since: DateTime.now());
    final started = await Native.startActivity(
      key: key,
      title: title,
      project: s.cwd.split('/').lastWhere((p) => p.isNotEmpty, orElse: () => s.cwd),
      state: shown.status.state.name,
      kind: shown.status.kind?.name,
      since: shown.since,
    );
    if (started) {
      _shown[key] = shown;
      notifyListeners();
    }
    return started;
  }

  /// A prompt went to [key]: it's working now, followed from here on.
  Future<void> prompted(String key, {required String title}) async {
    _prompted[key] = DateTime.now();
    const working = (state: ActivityState.working, kind: null);
    if (!following(key)) {
      await follow(key, title: title, status: working);
    } else if (_shown[key]?.status.state != ActivityState.working) {
      await _show(key, working);
    }
  }

  /// The person stops following [key]: the activity goes at once.
  Future<void> stop(String key) async {
    _shown.remove(key);
    notifyListeners();
    await Native.endActivity(key, immediate: true);
  }

  /// From ios/Runner/AppDelegate.swift: activityToken, activityEnded.
  void onNative(String event, Map<Object?, Object?> args) {
    final key = args['key'] as String?;
    final token = args['token'] as String?;
    if (key == null) return;
    switch (event) {
      case 'activityToken' when token != null:
        unawaited(_register(key, token));
      case 'activityEnded':
        if (token != null) {
          _registered.remove(token);
          unawaited(_push({'action': 'activity_end', 'token': token}));
        }
        _shown.remove(key);
        _prompted.remove(key);
        notifyListeners();
    }
  }

  Future<void> _register(String key, String token) async {
    if (!_registered.add(token)) return;
    if (!await _push({'action': 'activity_register', 'token': token, 'session': key})) _registered.remove(token);
  }

  Future<bool> _push(Map<String, dynamic> body) async {
    try {
      await _client.functions.invoke('push', body: body);
      return true;
    } on Object catch (e) {
      debugPrint('Džep: Live Activity ${body['action']}: $e');
      return false;
    }
  }

  Future<void> _show(String key, ActivityStatus status) async {
    final since = DateTime.now();
    _shown[key] = (status: status, since: since);
    await Native.updateActivity(key: key, state: status.state.name, kind: status.kind?.name, since: since);
  }

  /// The Mac's state changed: each followed session's activity follows it.
  void _sync() {
    final macState = _remote.online && !_remote.fromCache;
    for (final key in _shown.keys.toList()) {
      final s = _remote.session(key);
      if (s == null) {
        if (!macState) continue;
        _shown.remove(key);
        _prompted.remove(key);
        unawaited(Native.endActivity(key));
        notifyListeners();
        continue;
      }
      final status = summaryStatus(s);
      final shown = _shown[key];
      final prompted = _prompted[key];
      if (status.state == ActivityState.done && prompted != null && DateTime.now().difference(prompted) < _promptWait) {
        continue;
      }
      if (status.state != ActivityState.done) _prompted.remove(key);
      if (shown == null) {
        // Pushes have kept it current; its timer stays.
        _shown[key] = (status: status, since: DateTime.now());
      } else if (shown.status != status) {
        unawaited(_show(key, status));
      }
    }
  }

  @override
  void dispose() {
    _remote.removeListener(_sync);
    super.dispose();
  }
}
