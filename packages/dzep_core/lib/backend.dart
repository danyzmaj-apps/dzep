import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dzep_core/native.dart';
import 'package:flutter/foundation.dart';

/// The Supabase project Džep syncs through: each user runs their own (see
/// docs/SELF_HOSTING.md). The Mac enters it on its setup screen or opens a
/// setup link (`dzep://setup?url=…&key=…`, printed by tool/setup-backend.sh);
/// a phone learns it only from the Mac's code, a setup link with a sign-in
/// code in it (`…&code=…`, functions/pair). Kept in the App Group, where the
/// iPhone's widget reads it too
/// (apps/dzep-mobile/ios/Shared/DzepShared.swift).
@immutable
class Backend {
  const Backend({required this.url, required this.key});

  /// The project URL, `https://<ref>.supabase.co` or a self-hosted origin,
  /// without a trailing slash.
  final String url;

  /// The project's publishable (or legacy anon) key: safe in a client; row
  /// level security guards the data.
  final String key;

  /// [url] and [key] as typed, or a reason they can't be used.
  static ({Backend? backend, String? error}) parse(String url, String key) {
    final k = key.trim();
    var u = url.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    // The Data API URL from the dashboard works too.
    u = u.replaceFirst(RegExp(r'/(rest|auth|functions)/v1$'), '');
    final uri = Uri.tryParse(u);
    if (u.isEmpty || uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return (backend: null, error: 'Enter your project URL, like https://abcdefgh.supabase.co.');
    }
    if (uri.scheme != 'https' && !(uri.scheme == 'http' && _isLocal(uri.host))) {
      return (backend: null, error: 'The project URL must start with https:// (http:// only for a local server).');
    }
    if (uri.path.isNotEmpty || uri.hasQuery || uri.hasFragment) {
      return (backend: null, error: 'Use the project URL alone, without a path.');
    }
    if (k.isEmpty) return (backend: null, error: 'Enter the publishable key.');
    if (k.startsWith('sb_secret_') || _jwtRole(k) == 'service_role') {
      return (
        backend: null,
        error: 'That is a secret key. Use the publishable (or anon) key: never put a secret key in an app.',
      );
    }
    return (backend: Backend(url: u, key: k), error: null);
  }

  /// A `dzep://setup?url=…&key=…` link (its sign-in code, if any, is
  /// [pairingCode]'s).
  static Backend? fromLink(Uri uri) {
    if (uri.scheme != 'dzep' || uri.host != 'setup') return null;
    final url = uri.queryParameters['url'];
    final key = uri.queryParameters['key'];
    if (url == null || key == null) return null;
    return parse(url, key).backend;
  }

  /// The sign-in code in a setup link (the Mac's QR), if it has one.
  static String? pairingCode(Uri uri) {
    if (fromLink(uri) == null) return null;
    final code = uri.queryParameters['code']?.trim() ?? '';
    return code.isEmpty ? null : code;
  }

  Uri get link => Uri(scheme: 'dzep', host: 'setup', queryParameters: {'url': url, 'key': key});

  /// [link] with a sign-in code: what the Mac's QR holds.
  Uri linkWithCode(String code) =>
      Uri(scheme: 'dzep', host: 'setup', queryParameters: {'url': url, 'key': key, 'code': code});

  /// The host, for display.
  String get host => Uri.parse(url).host;

  static bool _isLocal(String host) =>
      host == 'localhost' ||
      host.endsWith('.local') ||
      RegExp(r'^(127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)').hasMatch(host);

  static String? _jwtRole(String key) {
    final parts = key.split('.');
    if (parts.length != 3) return null;
    try {
      final payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
      return payload is Map ? payload['role'] as String? : null;
    } on Object {
      return null;
    }
  }

  /// Asks the project's auth server for its settings: reachable, the key is
  /// accepted and, for a device that signs in with it ([github], the Mac),
  /// GitHub sign-in is on. Null when all is well, else what's wrong.
  Future<String?> check({bool github = true}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.getUrl(Uri.parse('$url/auth/v1/settings'));
      req.headers.set('apikey', key);
      final res = await req.close().timeout(const Duration(seconds: 10));
      final body = await utf8.decodeStream(res);
      if (res.statusCode == 401 || res.statusCode == 403) {
        return 'The project refused this key. Copy the publishable key from Project Settings → API Keys.';
      }
      if (res.statusCode == 404) return 'No Supabase project answers at this URL.';
      if (res.statusCode != 200) return 'The project answered with an error (${res.statusCode}).';
      final settings = jsonDecode(body);
      final external = settings is Map ? settings['external'] : null;
      if (github && !(external is Map && external['github'] == true)) {
        return 'GitHub sign-in is off on this project. Run tool/setup-backend.sh again, or turn it on under '
            'Authentication → Sign In / Providers (docs/SELF_HOSTING.md).';
      }
      return null;
    } on SocketException {
      return "Couldn't reach $host. Check the URL and your connection.";
    } on HandshakeException {
      return "Couldn't make a secure connection to $host.";
    } on TimeoutException {
      return '$host took too long to answer.';
    } on FormatException {
      return "That URL doesn't look like a Supabase project.";
    } finally {
      client.close(force: true);
    }
  }

  /// The backend this device was connected to, if any.
  static Future<Backend?> load() async {
    final saved = await Native.getBackend();
    if (saved == null) return null;
    return parse(saved.url, saved.key).backend;
  }

  Future<void> save() => Native.setBackend(url: url, key: key);

  static Future<void> clear() => Native.setBackend();

  @override
  bool operator ==(Object other) => other is Backend && other.url == url && other.key == key;

  @override
  int get hashCode => Object.hash(url, key);
}
