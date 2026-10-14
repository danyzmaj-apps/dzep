import 'package:dzep_core/account.dart';
import 'package:dzep_core/backend.dart';
import 'package:dzep_core/session.dart';
import 'package:dzep_mobile/mobile.dart';
import 'package:dzep_mobile/setup_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A phone with no session: [backend] it may know from before, [reason] it
/// lost the last one for.
class _Phone extends MobileSession {
  _Phone(SharedPreferences prefs, {this.known, this.reason}) : super(prefs, 'iPhone');
  final Backend? known;
  final String? reason;

  @override
  Backend? get backend => known;

  @override
  String? get signedOutReason => reason;
}

/// A [Session] whose [connectLink] signs in (or fails with [failure])
/// without a server.
class _FakeSession extends Session {
  _FakeSession({this.failure}) : super('iPhone');
  final String? failure;
  final links = <Uri>[];
  bool signedIn = false;

  @override
  Future<void> connectLink(Uri uri) async {
    links.add(uri);
    if (failure case final f?) {
      authError = f;
    } else {
      signedIn = true;
    }
    notifyListeners();
  }
}

const _server = 'https://abcdefgh.supabase.co';
final Uri _link = Uri.parse('dzep://setup?url=$_server&key=sb_publishable_x&code=K7QM-3XRT-AB12-CD34-EF56-GH78-JK90');

void main() {
  void phoneSize(WidgetTester tester) {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  Future<_FakeSession> pumpSetup(WidgetTester tester, {String? failure}) async {
    phoneSize(tester);
    final session = _FakeSession(failure: failure);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: session,
            builder: (_, _) => session.signedIn ? const Text('Signed in') : SetupPage(session: session),
          ),
        ),
      ),
    );
    return session;
  }

  Future<void> paste(WidgetTester tester, String text) async {
    await tester.tap(find.text('Paste a code instead'));
    await tester.pump();
    await tester.enterText(find.byType(TextField), text);
    await tester.tap(find.text('Sign in'));
    await tester.pump();
  }

  for (final (name, known) in [
    ('a new phone', null),
    ('a phone that knows its server', const Backend(url: _server, key: 'sb_publishable_x')),
  ]) {
    testWidgets('$name without a session offers only the Mac’s code, scanned or pasted, never GitHub', (tester) async {
      phoneSize(tester);
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(MobileApp(session: _Phone(await SharedPreferences.getInstance(), known: known)));
      expect(find.text('Scan the code from your Mac'), findsOneWidget);
      expect(find.text('Paste a code instead'), findsOneWidget);
      expect(find.byType(SignInPage), findsNothing);
      expect(find.byType(GithubButton), findsNothing);
      expect(find.textContaining('GitHub'), findsNothing);

      await tester.tap(find.text('Paste a code instead'));
      await tester.pump();
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byType(GithubButton), findsNothing);
      expect(find.textContaining('GitHub'), findsNothing);
      expect(find.textContaining('Publishable key'), findsNothing);

      await tester.tap(find.text('← Scan the code instead'));
      await tester.pump();
      expect(find.text('Scan the code from your Mac'), findsOneWidget);
    });
  }

  testWidgets('a phone that lost its session says why on the scan screen', (tester) async {
    phoneSize(tester);
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      MobileApp(session: _Phone(await SharedPreferences.getInstance(), reason: 'You signed out.')),
    );
    expect(find.text('You signed out.'), findsOneWidget);
    expect(find.text('Scan the code from your Mac'), findsOneWidget);
  });

  testWidgets('a pasted link with a code signs in', (tester) async {
    final session = await pumpSetup(tester);
    await paste(tester, '  $_link\n');
    expect(session.links, [_link]);
    expect(find.text('Signed in'), findsOneWidget);
  });

  testWidgets('a pasted link without a code, or anything else, is refused before anything is sent', (tester) async {
    final session = await pumpSetup(tester);
    await paste(tester, 'dzep://setup?url=$_server&key=sb_publishable_x');
    expect(find.textContaining('Paste the whole code from your Mac'), findsOneWidget);

    await tester.enterText(find.byType(TextField), _server);
    await tester.tap(find.text('Sign in'));
    await tester.pump();
    expect(find.textContaining('Paste the whole code from your Mac'), findsOneWidget);
    expect(session.links, isEmpty);
  });

  testWidgets('a code the server turns down says why and stays', (tester) async {
    const why = "That code doesn't work: it may have run out, been used already or been revoked.";
    final session = await pumpSetup(tester, failure: why);
    await paste(tester, '$_link');
    expect(session.links, [_link]);
    expect(find.text(why), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
  });
}
