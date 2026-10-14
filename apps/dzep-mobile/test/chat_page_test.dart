import 'package:dzep_core/chat.dart';
import 'package:dzep_core/chat_view.dart';
import 'package:dzep_mobile/mobile.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// [chat] as the only chat, the server's AI as [ai]; nothing is sent.
class FakeChats extends ChangeNotifier implements ChatStore {
  FakeChats(this.chat);
  final Conversation chat;
  final sent = <String>[];

  @override
  AiStatus? get ai => _ai;
  AiStatus? _ai;
  set ai(AiStatus? status) {
    _ai = status;
    notifyListeners();
  }

  @override
  bool get aiMissing => ai?.connected == false;

  @override
  Future<AiStatus?> checkAi() async => ai;

  @override
  String get userId => 'user';

  @override
  List<Conversation> get conversations => [chat];

  @override
  Conversation? byId(String id) => id == chat.id ? chat : null;

  @override
  Conversation? get current => chat;

  @override
  Conversation? get streaming => null;

  @override
  bool get busy => false;

  @override
  void newChat() {}

  @override
  void resume(Conversation c) {}

  @override
  void delete(Conversation c) {}

  @override
  Future<void> send(String text, {Conversation? into, List<ChatImage> images = const []}) async => sent.add(text);

  @override
  Future<Uint8List> image(String path) async => Uint8List(0);

  @override
  Future<void> syncNow() async {}

  @override
  Future<void> close() async {}
}

void main() {
  testWidgets('with no AI connected, a chat stays readable and says where to connect one', (tester) async {
    final now = DateTime.now();
    final chats = FakeChats(
      Conversation(
        id: 'c',
        createdAt: now,
        updatedAt: now,
        messages: [
          ChatMessage(fromUser: true, text: 'Capital of Peru?'),
          ChatMessage(fromUser: false, text: 'Lima.'),
        ],
      ),
    )..ai = const AiStatus(connected: false);
    await tester.pumpWidget(
      MaterialApp(
        home: ChatPage(chats: chats, conversation: chats.chat),
      ),
    );

    expect(find.text('Lima.'), findsOneWidget);
    expect(find.byType(NoAiNotice), findsOneWidget);
    expect(find.byType(TextField), findsNothing);

    // Connected from the Mac: the composer is back and sends.
    chats.ai = const AiStatus(connected: true);
    await tester.pump();
    expect(find.byType(NoAiNotice), findsNothing);
    await tester.enterText(find.byType(TextField), 'And Chile?');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    expect(chats.sent, ['And Chile?']);
  });
}
