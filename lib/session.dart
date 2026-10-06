import 'dart:async';

import 'package:dzep/store.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// GitHub sign-in and the signed-in user's [IdeaStore]: what the Mac and the
/// iPhone app share.
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
    _store = null;
    _user = user;
    if (user != null) {
      final store = _store = await IdeaStore.open(client, user.id, device);
      unawaited(onSignedIn(store));
    }
    notifyListeners();
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
    super.dispose();
  }
}
