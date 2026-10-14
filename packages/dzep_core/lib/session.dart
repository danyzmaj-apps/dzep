import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:dzep_core/backend.dart';
import 'package:dzep_core/chat.dart';
import 'package:dzep_core/live.dart' show imageBucket;
import 'package:dzep_core/native.dart';
import 'package:dzep_core/remind.dart';
import 'package:dzep_core/store.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The connected [Backend], signing in (GitHub on the Mac, the Mac's code on
/// a phone) and the signed-in user's [IdeaStore] and [ChatStore]: what the
/// Mac and the phone apps share.
class Session extends ChangeNotifier {
  Session(this.device);

  static const _redirect = 'dzep://login-callback';

  /// Whether this device signs in with GitHub (the Mac). A phone doesn't: it
  /// signs in only with a code from the Mac (functions/pair), so it neither
  /// needs GitHub on its server nor handles OAuth callbacks.
  bool get signsInWithGithub => true;

  /// The Supabase project this device syncs through; null until one is set
  /// up (the setup screen shows then).
  Backend? get backend => _backend;
  Backend? _backend;

  /// Only while [backend] is set.
  SupabaseClient get client => Supabase.instance.client;

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

  /// Why the last user is gone, once they are (signed out here, the server
  /// ended the session, the account was deleted); null after a sign-in. The
  /// phone shows it on its scan screen.
  String? get signedOutReason => _signedOutReason;
  String? _signedOutReason;

  /// Set by [signOut] and [deleteAccount] just before the user goes.
  String? _leaving;

  /// Launch: opens the backend this device was set up with, if any, and
  /// listens for setup links (`dzep://setup?url=…&key=…[&code=…]`).
  Future<void> start() async {
    _links = AppLinks().uriLinkStream.listen((uri) {
      if (Backend.fromLink(uri) != null) unawaited(connectLink(uri));
    });
    final saved = await Backend.load();
    if (saved != null) await connect(saved);
  }

  StreamSubscription<Uri>? _links;

  /// A setup link: connects to its server and, with a sign-in code (the
  /// Mac's QR), signs in too. A phone takes only links with a code. Problems
  /// land in [authError].
  Future<void> connectLink(Uri uri) async {
    final backend = Backend.fromLink(uri);
    if (backend == null) return;
    final code = Backend.pairingCode(uri);
    if (_user != null) {
      if (backend != _backend) authError = 'Sign out before switching to ${backend.host}.';
      notifyListeners();
      return;
    }
    if (code == null && !signsInWithGithub) {
      authError = 'That link has no sign-in code. On your Mac, open Džep: Settings → Set up phone…';
      notifyListeners();
      return;
    }
    if (backend != _backend) {
      final problem = await backend.check(github: signsInWithGithub);
      if (problem != null) {
        authError = problem;
        notifyListeners();
        return;
      }
      await connect(backend);
    }
    if (code == null) return;
    authError = null;
    notifyListeners();
    try {
      final data = (await client.functions.invoke('pair', body: {'action': 'redeem', 'code': code})).data;
      if (data case {'token_hash': final String hash}) {
        await client.auth.verifyOTP(type: OtpType.magiclink, tokenHash: hash);
        return;
      }
      authError = _serverTooOld;
    } on FunctionException catch (e) {
      authError = switch (e) {
        // A server from before codes: no function, or the old one that
        // wanted a signed-in caller.
        FunctionException(status: 404 || 401) => _serverTooOld,
        _ => pairingProblem(e),
      };
    } on AuthException {
      authError = 'That code was used up while signing in. Make a new one on your Mac (Settings → Set up phone…).';
    } on Object catch (e) {
      authError = 'Sign-in failed: $e';
    }
    notifyListeners();
  }

  static const _serverTooOld =
      'Your server is older than this app. Update it from your Mac (docs/SELF_HOSTING.md), then make a new code.';

  /// A setup link that also signs a new device in (functions/pair, action
  /// create): works once, for 10 minutes. Only while signed in. Fails with a
  /// [PairingException] that says why.
  Future<Uri> pairingLink() async {
    final data = await _pair({'action': 'create'});
    if (data case {'code': final String code}) return _backend!.linkWithCode(code);
    throw const PairingException("The server didn't send a code. Update it (docs/SELF_HOSTING.md), then retry.");
  }

  /// A reusable code for App Store / Play review (functions/pair, action
  /// reviewer): signs into this server's separate demo account, not this
  /// user's, for [days]. Its [ReviewerCode.link] is known only now.
  Future<ReviewerCode> createReviewerCode({required int days, String label = ''}) async {
    final data = await _pair({'action': 'reviewer', 'days': days, 'label': label});
    if (data case {'code': final String code} when data is Map<String, dynamic>) {
      return ReviewerCode.fromJson(data, link: _backend!.linkWithCode(code));
    }
    throw const PairingException("The server didn't send a code. Update it (docs/SELF_HOSTING.md), then retry.");
  }

  /// This user's reviewer codes that still work, newest first.
  Future<List<ReviewerCode>> reviewerCodes() async {
    final data = await _pair({'action': 'list'});
    if (data case {'codes': final List<dynamic> codes}) {
      return [for (final c in codes.whereType<Map<String, dynamic>>()) ReviewerCode.fromJson(c)];
    }
    throw const PairingException("The server didn't list the codes. Update it (docs/SELF_HOSTING.md), then retry.");
  }

  /// Stops reviewer code [id] from working.
  Future<void> revokeReviewerCode(String id) => _pair({'action': 'revoke', 'id': id});

  Future<Object?> _pair(Map<String, Object> body) async {
    try {
      return (await client.functions.invoke('pair', body: body)).data;
    } on Object catch (e) {
      throw PairingException(pairingProblem(e));
    }
  }

  /// Opens [backend] (and remembers it): the one saved at launch, the setup
  /// screen's, or a setup link's. Switching needs the user signed out.
  Future<void> connect(Backend backend) async {
    if (_user != null) throw StateError('Sign out before switching projects.');
    await _close();
    await Supabase.initialize(
      url: backend.url,
      publishableKey: backend.key,
      // A phone never takes an OAuth callback: it signs in with codes only.
      authOptions: FlutterAuthClientOptions(detectSessionInUri: signsInWithGithub),
    );
    await backend.save();
    _backend = backend;
    authError = null;
    notifyListeners();
    _auth = client.auth.onAuthStateChange.listen(
      (s) {
        // The server refused to refresh the session (signed out elsewhere,
        // account deleted, refresh token revoked or expired).
        if (s.signOutReason case SignOutReason.sessionExpired || SignOutReason.sessionMissing) {
          _leaving ??= 'Your sign-in ended on the server. Scan a new code from your Mac.';
        }
        unawaited(_setUser(s.session?.user));
      },
      // A failed OAuth callback (expired code, sign-up refused) lands here.
      onError: (Object e) {
        authError = e is AuthException ? e.message : 'Sign-in failed: $e';
        notifyListeners();
      },
    );
    final hadSession = client.auth.currentSession != null;
    await _freshSession();
    // Refused while restoring at launch, before anything was listening.
    if (hadSession && client.auth.currentSession == null) {
      _leaving ??= 'Your sign-in ended on the server. Scan a new code from your Mac.';
    }
    await _setUser(client.auth.currentUser);
  }

  /// Makes the restored session good for Realtime before anything joins a
  /// channel (the stores' live updates, the terminal bridge's private
  /// topic). supabase_flutter hands the token to Realtime only after
  /// `initialize` returns, and not at all when it expired while the app was
  /// closed; a channel joined before that joins as nobody, and a private one
  /// then never hears a thing (the phone's Terminal tab spun forever).
  Future<void> _freshSession() async {
    final session = client.auth.currentSession;
    if (session == null) return;
    try {
      if (session.isExpired) await client.auth.refreshSession();
      await client.realtime.setAuth(client.auth.currentSession?.accessToken);
    } on Object catch (e) {
      // Offline: the stores still work from their caches and catch up.
      debugPrint('Džep: session not refreshed: $e');
    }
  }

  /// Signs out and forgets the backend: the setup screen shows again.
  Future<void> disconnect() async {
    if (_user != null) await signOut();
    await _close();
    await Backend.clear();
    _backend = null;
    authError = null;
    notifyListeners();
  }

  Future<void> _close() async {
    if (_backend == null) return;
    await _auth?.cancel();
    _auth = null;
    await Supabase.instance.dispose();
  }

  /// Runs once a user's store is open (sign-in, or launch while signed in).
  @protected
  Future<void> onSignedIn(IdeaStore store) async {}

  /// Runs before signing out, while the session can still reach the server.
  @protected
  Future<void> onSigningOut() async {}

  /// Actions queued in the App Group (apps/dzep-mobile/ios/Shared/DzepShared.swift) by what
  /// can't reach this session: the phones' widgets and notification Done
  /// actions while offline, the Mac's widget always. Only {action: done, id}.
  Future<void> drainPending() async {
    final store = this.store;
    if (store == null) return;
    for (final raw in await Native.takePending()) {
      try {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        if (j['action'] == 'done') {
          final todo = store.byId(j['id'] as String? ?? '');
          if (todo != null && todo.isTodo) store.update(todo, done: true);
        }
      } on Object catch (e) {
        debugPrint('Džep: dropped unreadable queued action: $e');
      }
    }
  }

  /// User changes apply one at a time: the auth stream's initial event and
  /// [connect]'s own check both arrive at launch, and two overlapping
  /// switches would each open a store (and register a device token).
  Future<void> _switching = Future.value();

  Future<void> _setUser(User? user) => _switching = _switching.then((_) => _applyUser(user));

  Future<void> _applyUser(User? user) async {
    final reason = _signedOutReason;
    if (user != null) {
      _signedOutReason = _leaving = null;
    } else if (_user != null || _leaving != null) {
      _signedOutReason = _leaving ?? 'Your sign-in ended. Scan a new code from your Mac.';
      _leaving = null;
    }
    if (user?.id == _user?.id) {
      _user = user ?? _user;
      if (_signedOutReason != reason) notifyListeners();
      return;
    }
    await _store?.close();
    await _chats?.close();
    _store = null;
    _chats = null;
    _user = user;
    if (user != null) {
      // Both open before either is published: screens read the chats
      // whenever the store is there.
      final store = await IdeaStore.open(client, user.id, device);
      final chats = await ChatStore.open(client, user.id);
      _store = store;
      _chats = chats;
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

  /// The server pushes this device's reminders (functions/push), so it
  /// schedules none itself: both would go off.
  bool _remindersByPush = false;
  bool get remindersByPush => _remindersByPush;

  @protected
  set remindersByPush(bool value) {
    if (value == _remindersByPush) return;
    _remindersByPush = value;
    _syncReminders(_store);
  }

  /// Keeps this device's pending notifications equal to [pendingReminders]
  /// of the open store, on every change to it; native code only schedules.
  void _syncReminders(IdeaStore? store) {
    if (store != _store) return;
    final due = store == null || _remindersByPush
        ? const <Reminder>[]
        : pendingReminders(store.openTodos, DateTime.now());
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
    _leaving ??= 'You signed out.';
    try {
      await onSigningOut();
      await client.auth.signOut();
    } on Object {
      // Offline: the local session is gone all the same.
    }
    await _setUser(null);
  }

  /// Deletes the account on the server with everything in it (ideas, todos,
  /// chats and their images, device tokens), then this device's copy, and
  /// signs out.
  Future<void> deleteAccount() async {
    final id = _user?.id;
    if (id == null) return;
    // Storage objects aren't tied to the user by a foreign key.
    for (final bucket in [imageBucket, chatImageBucket]) {
      try {
        while (true) {
          final files = await client.storage
              .from(bucket)
              .list(path: id, searchOptions: const SearchOptions(limit: 1000));
          if (files.isEmpty) break;
          await client.storage.from(bucket).remove([for (final f in files) '$id/${f.name}']);
        }
      } on Object catch (e) {
        debugPrint('Džep: $bucket images not removed: $e');
      }
    }
    await client.rpc<void>('delete_my_account');
    _leaving = 'Your account was deleted.';
    await signOut();
    final dir = await getApplicationSupportDirectory();
    for (final name in ['ideas-$id.json', 'chats-$id.json']) {
      final f = File('${dir.path}/$name');
      if (f.existsSync()) await f.delete();
    }
  }

  String get userName {
    final meta = _user?.userMetadata ?? const {};
    return (meta['user_name'] ?? meta['preferred_username'] ?? meta['name'] ?? _user?.email ?? 'you') as String;
  }

  String? get avatarUrl => _user?.userMetadata?['avatar_url'] as String?;

  @override
  void dispose() {
    unawaited(_auth?.cancel());
    unawaited(_links?.cancel());
    unawaited(_store?.close());
    unawaited(_chats?.close());
    super.dispose();
  }
}

/// Why a pairing or reviewer code couldn't be made (or listed, or revoked),
/// worded for the person.
class PairingException implements Exception {
  const PairingException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// A reusable code for App Store / Play review: signs into the server's demo
/// account, a separate account that sees none of the owner's data. [link]
/// (the setup link with the code) is known only right after it is made:
/// the server keeps a hash.
@immutable
class ReviewerCode {
  const ReviewerCode({required this.id, required this.label, required this.expiresAt, this.lastUsedAt, this.link});

  factory ReviewerCode.fromJson(Map<String, dynamic> j, {Uri? link}) => ReviewerCode(
    id: j['id'] as String,
    label: j['label'] as String? ?? '',
    expiresAt: DateTime.parse(j['expires_at'] as String).toLocal(),
    lastUsedAt: switch (j['last_used_at']) {
      final String at => DateTime.parse(at).toLocal(),
      _ => null,
    },
    link: link,
  );

  final String id;
  final String label;
  final DateTime expiresAt;
  final DateTime? lastUsedAt;
  final Uri? link;
}

/// What a failed call to functions/pair means: the function's own reason
/// (not signed in, a used-up code), an older server without it, or no
/// connection.
String pairingProblem(Object error) => switch (error) {
  FunctionsFetchException() => "Couldn't reach your server. Check your connection.",
  FunctionException(details: {'error': final String message}) => message,
  FunctionException(status: 404) => 'Your server is older than this app. Update it (docs/SELF_HOSTING.md), then retry.',
  FunctionException(:final status) => 'Your server failed ($status).',
  _ => "Couldn't make a code: $error",
};
