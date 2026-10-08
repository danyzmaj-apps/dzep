import 'package:dzep/backend.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Backend.parse', () {
    test('normalizes the project URL', () {
      for (final url in [
        'https://abc.supabase.co',
        ' https://abc.supabase.co/ ',
        'https://abc.supabase.co/rest/v1/',
        'https://abc.supabase.co/auth/v1',
      ]) {
        expect(Backend.parse(url, 'sb_publishable_x').backend?.url, 'https://abc.supabase.co', reason: url);
      }
    });

    test('allows plain http only for local servers', () {
      expect(Backend.parse('http://127.0.0.1:54321', 'k').backend, isNotNull);
      expect(Backend.parse('http://192.168.1.20:54321', 'k').backend, isNotNull);
      expect(Backend.parse('http://abc.supabase.co', 'k').error, isNotNull);
    });

    test('rejects secret keys', () {
      expect(Backend.parse('https://abc.supabase.co', 'sb_secret_abc').error, contains('secret'));
      // A legacy service_role JWT: {"role":"service_role"}.
      const serviceRole = 'eyJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIn0.sig';
      expect(Backend.parse('https://abc.supabase.co', serviceRole).error, contains('secret'));
      const anon = 'eyJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoiYW5vbiJ9.sig';
      expect(Backend.parse('https://abc.supabase.co', anon).backend, isNotNull);
    });

    test('rejects garbage', () {
      expect(Backend.parse('', 'k').error, isNotNull);
      expect(Backend.parse('abc.supabase.co', 'k').error, isNotNull);
      expect(Backend.parse('https://abc.supabase.co/x', 'k').error, isNotNull);
      expect(Backend.parse('https://abc.supabase.co', ' ').error, isNotNull);
    });
  });

  test('setup links round-trip', () {
    const b = Backend(url: 'https://abc.supabase.co', key: 'sb_publishable_x');
    expect(Backend.fromLink(b.link), b);
    expect(Backend.fromLink(Uri.parse('dzep://todos')), isNull);
    expect(Backend.fromLink(Uri.parse('dzep://setup?url=https://abc.supabase.co')), isNull);
  });
}
