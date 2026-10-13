import 'dart:convert';

import 'package:dzep_core/chat.dart';
import 'package:dzep_macos/onboarding/connect_ai.dart';
import 'package:dzep_macos/onboarding/supabase_admin.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'app_fakes.dart';

void main() {
  test('only a supabase.com project has a ref the Management API takes', () {
    expect(projectRef('https://abcdefgh.supabase.co'), 'abcdefgh');
    expect(projectRef('http://127.0.0.1:54321'), isNull);
    expect(projectRef('https://dzep.example.com'), isNull);
    expect(projectRef('https://a.b.supabase.co'), isNull);
  });

  group('the sheet', () {
    late FakeApp app;
    late List<http.Request> requests;
    late int status;
    late List<String> told;

    Future<void> pumpSheet(WidgetTester tester) async {
      tester.view
        ..physicalSize = const Size(1000, 900)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      app = await FakeApp.create();
      requests = [];
      status = 201;
      told = [];
      final admin = MockClient((req) async {
        requests.add(req);
        return http.Response(status == 201 ? '' : '{"message":"nope"}', status);
      });
      await tester.pumpWidget(
        window(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => ConnectAiSheet(
                  app: app,
                  onDone: told.add,
                  admin: (token) => SupabaseAdmin(token, client: admin),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    Future<void> fill(WidgetTester tester, {required String key, required String token}) async {
      await tester.enterText(find.widgetWithText(TextField, 'API key'), key);
      await tester.enterText(find.widgetWithText(TextField, 'Access token (sbp_…)'), token);
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
    }

    testWidgets('saves the chosen provider as the server’s secrets and refreshes Ask', (tester) async {
      await pumpSheet(tester);
      app.fakeChats
        ..ai = const AiStatus(connected: false)
        ..server = const AiStatus(connected: true, model: 'gpt-5-mini');
      await tester.tap(find.text('OpenAI'));
      await tester.pump();
      await fill(tester, key: ' sk-1 ', token: 'sbp_x');

      final req = requests.single;
      expect((req.method, req.url.path), ('POST', '/v1/projects/example/secrets'));
      expect(req.headers['authorization'], 'Bearer sbp_x');
      expect(jsonDecode(req.body), [
        {'name': 'AI_BASE_URL', 'value': 'https://api.openai.com/v1'},
        {'name': 'AI_MODEL', 'value': 'gpt-5-mini'},
        {'name': 'AI_API_KEY', 'value': 'sk-1'},
      ]);
      expect(app.fakeChats.aiMissing, isFalse);
      expect(told, hasLength(1));
      expect(find.byType(ConnectAiSheet), findsNothing);
    });

    testWidgets('Other takes a typed API and model', (tester) async {
      await pumpSheet(tester);
      await tester.tap(find.text('Other'));
      await tester.pump();
      await tester.enterText(
        find.widgetWithText(TextField, 'API base URL (OpenAI-compatible)'),
        'http://mini:11434/v1',
      );
      await tester.enterText(find.widgetWithText(TextField, 'Model'), 'llama3.2');
      await fill(tester, key: 'ollama', token: 'sbp_x');

      final secrets = {for (final s in jsonDecode(requests.single.body) as List) (s as Map)['name']: s['value']};
      expect(secrets, {'AI_BASE_URL': 'http://mini:11434/v1', 'AI_MODEL': 'llama3.2', 'AI_API_KEY': 'ollama'});
    });

    testWidgets('nothing goes to Supabase until the form is whole', (tester) async {
      await pumpSheet(tester);
      await fill(tester, key: '', token: 'sbp_x');
      await fill(tester, key: 'sk-1', token: 'not-a-token');
      await tester.tap(find.text('Other'));
      await tester.pump();
      await tester.enterText(find.widgetWithText(TextField, 'API base URL (OpenAI-compatible)'), 'api.example.com');
      await tester.enterText(find.widgetWithText(TextField, 'Model'), 'm');
      await fill(tester, key: 'sk-1', token: 'sbp_x');

      expect(requests, isEmpty);
      expect(told, isEmpty);
      expect(find.byType(ConnectAiSheet), findsOneWidget);
    });

    testWidgets('a refused token says so and leaves the sheet open to try again', (tester) async {
      await pumpSheet(tester);
      status = 401;
      await fill(tester, key: 'sk-1', token: 'sbp_old');

      expect(find.textContaining('refused that access token'), findsOneWidget);
      expect(told, isEmpty);

      status = 201;
      await fill(tester, key: 'sk-1', token: 'sbp_new');
      expect(requests.last.headers['authorization'], 'Bearer sbp_new');
      expect(told, hasLength(1));
    });
  });
}
