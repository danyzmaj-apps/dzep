import 'dart:async';
import 'dart:convert';

import 'package:dzep/chat.dart';
import 'package:dzep/idea.dart';
import 'package:dzep/native.dart';
import 'package:dzep/remind.dart';
import 'package:dzep/store.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// GitHub sign-in and the signed-in user's [IdeaStore] and [ChatStore]: what
/// the Mac and the iPhone app share.
class Session extends ChangeNotifier {
  Session(this.client, this.device);

  static const _redirect = 'dzep://login-callback';

  final SupabaseClient client;

  /// This machine's name, stamped on the ideas it creates.
  final String device;

  User? get user => _user;
  User? _user;
  IdeaStore? get store => _store;
  IdeaStore? _store;

  /// Quick-question chats; open whenever [store] is.
  ChatStore? get chats => _chats;
  ChatStore? _chats;
  StreamSubscription<AuthState>? _auth;

  String? authError;

  Future<void> startAuth() async {
    _auth = client.auth.onAuthStateChange.listen((s) => unawaited(_setUser(s.session?.user)));
    await _setUser(client.auth.currentUser);
  }

  /// Runs once a user's store is open (sign-in, or launch while signed in).
  @protected
  Future<void> onSignedIn(IdeaStore store) async {}

  /// Runs before signing out, while the session can still reach the server.
  @protected
  Future<void> onSigningOut() async {}

  /// Actions queued in the App Group (ios/Shared/DzepShared.swift) by what
  /// can't reach this session: the iPhone's Siri intents and widget while
  /// offline, the Mac's widget always. {action: add, kind, title} or
  /// {action: done, id}.
  Future<void> drainPending() async {
    final store = this.store;
    if (store == null) return;
    for (final raw in await Native.takePending()) {
      try {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        if (j['action'] == 'done') {
          final todo = store.byId(j['id'] as String? ?? '');
          if (todo != null && todo.isTodo) store.update(todo, done: true);
        } else {
          store.add(title: j['title'] as String? ?? '', kind: j['kind'] == 'todo' ? Kind.todo : Kind.idea);
        }
      } on Object catch (e) {
        debugPrint('Džep: dropped unreadable queued action: $e');
      }
    }
  }

  /// User changes apply one at a time: the auth stream's initial event and
  /// [startAuth] both arrive at launch, and two overlapping switches would
  /// each open a store (and register a device token).
  Future<void> _switching = Future.value();

  Future<void> _setUser(User? user) => _switching = _switching.then((_) => _applyUser(user));

  Future<void> _applyUser(User? user) async {
    if (user?.id == _user?.id) {
      _user = user ?? _user;
      return;
    }
    await _store?.close();
    await _chats?.close();
    _store = null;
    _chats = null;
    _user = user;
    if (user != null) {
      final store = _store = await IdeaStore.open(client, user.id, device);
      _chats = await ChatStore.open(client, user.id);
      store.addListener(() => _syncReminders(store));
      _syncReminders(store);
      unawaited(onSignedIn(store));
    } else {
      // Signed out: none of their todos may still go off here.
      _syncReminders(null);
    }
    notifyListeners();
  }

  /// The reminders this device was last asked to have pending.
  List<Reminder>? _reminders;
  bool _sendingReminders = false;

  /// Keeps this device's pending notifications equal to [pendingReminders]
  /// of the open store, on every change to it; native code only schedules.
  void _syncReminders(IdeaStore? store) {
    if (store != _store) return;
    final due = store == null ? const <Reminder>[] : pendingReminders(store.openTodos, DateTime.now());
    if (listEquals(due, _reminders)) return;
    _reminders = due;
    if (!_sendingReminders) unawaited(_sendReminders());
  }

  /// One native call at a time, always with the newest set: each call
  /// replaces every pending reminder, so an older set must never land last.
  Future<void> _sendReminders() async {
    _sendingReminders = true;
    List<Reminder>? sent;
    while (!identical(sent, _reminders)) {
      sent = _reminders!;
      try {
        await Native.setReminders(sent);
      } on Object catch (e) {
        debugPrint('Džep: reminders not scheduled: $e');
      }
    }
    _sendingReminders = false;
  }

  Future<void> signIn() async {
    authError = null;
    notifyListeners();
    try {
      await client.auth.signInWithOAuth(
        OAuthProvider.github,
        redirectTo: _redirect,
        authScreenLaunchMode: LaunchMode.externalApplication,
      );
    } on Object catch (e) {
      authError = 'Could not start GitHub sign-in: $e';
      notifyListeners();
    }
  }

  Future<void> signOut() async {
    try {
      await onSigningOut();
      await client.auth.signOut();
    } on Object {
      // Offline: the local session is gone all the same.
    }
    await _setUser(null);
  }

  String get userName {
    final meta = _user?.userMetadata ?? const {};
    return (meta['user_name'] ?? meta['preferred_username'] ?? meta['name'] ?? _user?.email ?? 'you') as String;
  }

  String? get avatarUrl => _user?.userMetadata?['avatar_url'] as String?;

  @override
  void dispose() {
    unawaited(_auth?.cancel());
    unawaited(_store?.close());
    unawaited(_chats?.close());
    super.dispose();
  }
}
