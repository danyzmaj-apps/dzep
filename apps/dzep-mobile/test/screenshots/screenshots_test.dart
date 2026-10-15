// The phone screenshots in the docs: the real screens on made-up data, 393×852 points at 2×.
// Run from apps/dzep-mobile: `fvm flutter test --tags screenshots --run-skipped` (dart_test.yaml skips them otherwise).
// They land in the repo's docs/images/phone-*.png. The home page renders here in its Android look only: on an
// iPhone its tab bar, search and kind picker are UIKit views, which a test can't draw, so phone-pocket.png and the
// hero's phone are taken on the iOS simulator (docs/BUILDING.md). hero.png is that capture in a phone's frame next
// to the Mac's popup, which apps/dzep-macos-app's screenshots render first (build/screenshots/hero-popup.png).
@Tags(['screenshots'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dzep_core/chat.dart';
import 'package:dzep_core/idea.dart';
import 'package:dzep_core/live.dart';
import 'package:dzep_core/terminal_remote.dart';
import 'package:dzep_mobile/chrome.dart';
import 'package:dzep_mobile/mobile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'fakes.dart';
import 'fonts.dart';

final _out = Directory('../../docs/images');
final _heroPopup = File('../dzep-macos-app/build/screenshots/hero-popup.png');
final _heroPhone = File('build/screenshots/hero-phone.png');
final _ios = TargetPlatformVariant.only(TargetPlatform.iOS);
final _android = TargetPlatformVariant.only(TargetPlatform.android);

/// Today at [hour]:[minute], [days] from now (local time, as the rows read it).
DateTime _day(int days, int hour, [int minute = 0]) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day + days, hour, minute);
}

FakeStore _store() {
  var n = 0;
  final store = FakeStore();
  void put(
    Kind kind,
    String title,
    DateTime at, {
    String notes = '',
    String project = '',
    DateTime? remind,
    DateTime? done,
  }) => store.put(
    Idea(
      id: 'i${n++}',
      kind: kind,
      title: title,
      notes: notes,
      project: project,
      remindAt: remind,
      doneAt: done,
      createdAt: at,
      updatedAt: at,
    ),
  );

  // Todos: newest first; reminders tomorrow, in four days, and one gone off.
  put(Kind.todo, 'Renew the domain for dzep-site', _day(0, 8, 41), remind: _day(1, 9));
  put(Kind.todo, 'Review Marko’s pull request on garden-api', _day(0, 8, 12));
  put(Kind.todo, 'Buy basil and tomato seedlings', _day(-1, 18, 5), remind: _day(4, 15));
  put(Kind.todo, 'Book the dentist for next month', _day(-1, 12, 30));
  put(Kind.todo, 'Call Ana about the garden plan', _day(-2, 9, 20), remind: _day(-1, 17));
  put(Kind.todo, 'Write release notes for 0.4', _day(-3, 16, 2));
  put(Kind.todo, 'Pay the electricity bill', _day(-4, 10), done: _day(-1, 11));
  put(Kind.todo, 'Back up the photos to the NAS', _day(-5, 21), done: _day(-2, 20));

  // Ideas, across three projects.
  put(
    Kind.idea,
    'Watering schedule from the soil sensors',
    _day(0, 9, 3),
    notes: 'Skip watering for a day after rain.',
    project: 'garden-api',
  );
  put(
    Kind.idea,
    'Dark-mode screenshots on the landing page',
    _day(0, 7, 48),
    notes: 'Match the README’s look.',
    project: 'dzep-site',
  );
  put(
    Kind.idea,
    'Rate-limit the public plant search',
    _day(-1, 21, 14),
    notes: '60 requests a minute per key.',
    project: 'garden-api',
  );
  put(
    Kind.idea,
    'Changelog page built from GitHub releases',
    _day(-1, 10, 2),
    notes: 'One page per minor version.',
    project: 'dzep-site',
  );
  put(
    Kind.idea,
    'Raspberry Pi as a tiny Grafana box',
    _day(-3, 19, 40),
    notes: 'Greenhouse humidity on the kitchen tablet.',
    project: 'home-lab',
  );
  put(
    Kind.idea,
    'Offline-first seed catalogue',
    _day(-6, 14, 25),
    notes: 'Sync orders when back online.',
    project: 'garden-api',
  );
  put(Kind.idea, 'Name a plant by photo', _day(-9, 11, 10), notes: 'Try an on-device model first.');

  // Notes: the first line is the title.
  put(
    Kind.note,
    'Trip to Ljubljana',
    _day(0, 7, 55),
    notes: 'Trip to Ljubljana\nTrain at 7:42 from platform 3. Bring the charger and the blue backpack.',
  );
  put(
    Kind.note,
    'garden-api sync',
    _day(-1, 15, 30),
    notes: 'garden-api sync\nShip the sensor endpoints first. Ana takes the docs, Marko the migrations.',
  );
  put(
    Kind.note,
    'Sourdough',
    _day(-2, 20, 10),
    notes: 'Sourdough\n500\u00A0g flour, 350\u00A0g water, 100\u00A0g starter, 10\u00A0g salt. Fold every 30\u00A0min, four times.',
  );
  put(
    Kind.note,
    'Books to read',
    _day(-4, 22, 5),
    notes: 'Books to read\nThe Overstory · Piranesi · A Psalm for the Wild-Built · The Dispossessed',
  );
  put(
    Kind.note,
    'Cabin checklist',
    _day(-8, 18, 45),
    notes: 'Cabin checklist\nTurn the water on at the main valve, then the boiler. Firewood is behind the shed.',
  );
  put(
    Kind.note,
    'Gift ideas',
    _day(-12, 12, 20),
    notes: 'Gift ideas\nMarko: the new Le Guin box set. Mum: a pocket knife sharpener.',
  );
  return store;
}

FakeChats _chats() => FakeChats()
  ..chats.add(
    Conversation(
      id: 'c1',
      createdAt: _day(0, 9, 12),
      updatedAt: _day(0, 9, 14),
      messages: [
        ChatMessage(fromUser: true, text: 'Cold frame or greenhouse for spring seedlings?'),
        ChatMessage(
          fromUser: false,
          text:
              'For seedlings in spring, a **cold frame** is usually enough.\n\n'
              '- **Cold frame**: a low, unheated box with a clear lid. It keeps off frost and wind and '
              'warms up in the sun. Cheap, and you can build one in an afternoon.\n'
              '- **Greenhouse**: room to walk in and grow all year, but it costs more, and it needs '
              'ventilation and often heating.\n\n'
              'Start seeds indoors, then move them to the cold frame for a week or two to *harden off* '
              'before planting out.',
        ),
        ChatMessage(fromUser: true, text: 'How hot does a cold frame get on a sunny day?'),
        ChatMessage(
          fromUser: false,
          text:
              'Easily **10–15\u00A0°C warmer** than outside, and over 30\u00A0°C by midday. Open the lid:\n\n'
              '1. a hand’s width once it is above 15\u00A0°C outside,\n'
              '2. fully on warm, sunny days,\n'
              '3. and close it again in the late afternoon to keep the heat in overnight.',
        ),
      ],
    ),
  );

const _home = '/Users/demo';
const _garden = '$_home/Dev/garden-api';
const _site = '$_home/Dev/dzep-site';
const _seeds = '$_home/Dev/seed-catalog';

/// The Mac's state: three coding sessions (finished, needing you, working)
/// and three plain terminal windows.
Map<String, dynamic> _state() {
  final now = DateTime.now();
  int ago(int minutes) => now.subtract(Duration(minutes: minutes)).millisecondsSinceEpoch;
  return {
    'windows': [
      {'key': 'kitty-1/3', 'title': 'omp', 'cwd': _garden, 'program': 'omp', 'app': 'kitty'},
      {'key': 'iterm-2', 'title': 'claude', 'cwd': _site, 'program': 'claude', 'app': 'iterm'},
      {'key': 'tmux-%4', 'title': 'omp', 'cwd': _seeds, 'program': 'omp', 'app': 'tmux', 'via': 'Ghostty'},
      {'key': 'kitty-1/1', 'title': 'zsh', 'cwd': _garden, 'program': 'zsh', 'app': 'kitty', 'focused': true},
      {'key': 'tmux-%2', 'title': 'nvim README.md', 'cwd': _site, 'program': 'nvim', 'app': 'tmux', 'via': 'Ghostty'},
      {'key': 'iterm-1', 'title': 'htop', 'cwd': _home, 'program': 'htop', 'app': 'iterm'},
    ],
    'sessions': [
      {
        'key': 'kitty-1/3',
        'id': 's1',
        'agent': 'omp',
        'window': 'kitty-1/3',
        'title': 'Add a soil moisture endpoint',
        'cwd': _garden,
        'model': 'claude-sonnet-4.5',
        'ctx': 23,
        'preview': 'Done: GET /plants/:id/moisture, with tests.',
        'at': ago(4),
        'epoch': 'e1',
        'seq': 7,
      },
      {
        'key': 'iterm-2',
        'id': 's2',
        'agent': 'claude',
        'window': 'iterm-2',
        'title': 'Fix the pricing table on small screens',
        'cwd': _site,
        'model': 'opus',
        'ask': {'kind': 'approval', 'id': 'a1', 'tool': 'Bash', 'summary': 'npm run build'},
        'preview': 'Wants to run npm run build',
        'at': ago(1),
        'epoch': 'e1',
        'seq': 12,
      },
      {
        'key': 'tmux-%4',
        'id': 's3',
        'agent': 'omp',
        'window': 'tmux-%4',
        'title': 'Rate-limit the plant search',
        'cwd': _seeds,
        'busy': true,
        'preview': 'Running the integration tests…',
        'at': ago(0),
        'epoch': 'e1',
        'seq': 30,
      },
    ],
    'projects': [_garden, _site, _seeds],
    'home': _home,
    'agent': 'omp',
    'opensIn': 'kitty',
  };
}

/// The finished session's transcript, as the Mac sends it to this phone.
Map<String, dynamic> _items() {
  var order = 0;
  Map<String, dynamic> item(
    ItemKind kind, {
    String text = '',
    String tool = '',
    String title = '',
    String args = '',
    String output = '',
  }) {
    order++;
    return LiveItem(
      id: 'it$order',
      kind: kind,
      text: text,
      tool: tool,
      title: title,
      args: args,
      output: output,
      status: ToolStatus.ok,
      order: order,
      seq: order,
    ).toJson();
  }

  return {
    'to': 'phone',
    'session': 'kitty-1/3',
    'epoch': 'e1',
    'seq': 7,
    'reset': true,
    'last': true,
    'older': false,
    'items': [
      item(
        ItemKind.user,
        text:
            'Add GET /plants/:id/moisture: the last 24 hours of soil readings, newest first. '
            'Reuse the sensor repo, and add tests.',
      ),
      item(ItemKind.assistant, text: 'Let me look at how the readings are stored first.'),
      item(ItemKind.tool, tool: 'read', title: 'src/sensors/repo.ts'),
      item(ItemKind.tool, tool: 'read', title: 'src/routes/plants.ts'),
      item(ItemKind.tool, tool: 'edit', title: 'src/routes/plants.ts'),
      item(
        ItemKind.tool,
        tool: 'bash',
        title: 'npm test -- moisture',
        output:
            ' PASS  test/moisture.test.ts\n'
            '  ✓ last 24 h, newest first (18 ms)\n'
            '  ✓ 404 for an unknown plant (4 ms)\n'
            '\n'
            'Tests:  2 passed, 2 total',
      ),
      item(
        ItemKind.assistant,
        text:
            'Done. `GET /plants/:id/moisture` now returns the last 24 h of readings:\n\n'
            '- `SensorRepo.readingsSince()` runs the query, on the `(plant_id, taken_at)` index\n'
            '- an unknown plant gets a **404**\n'
            '- `test/moisture.test.ts` covers both\n\n'
            'Want a `?hours=` parameter as well?',
      ),
    ],
  };
}

void main() {
  late String? missingFont;
  late Directory cache;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    missingFont = await loadRealFonts();
    _out.createSync(recursive: true);
  });

  setUp(() {
    cache = Directory.systemTemp.createTempSync('dzep_shots');
    // Reminders, pushes, keep-awake: nothing on the native side to answer.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(const MethodChannel('dzep/native'), (_) async => null)
      ..setMockMethodCallHandler(const MethodChannel('com.llfbandit.app_links/messages'), (_) async => null)
      ..setMockStreamHandler(
        const EventChannel('com.llfbandit.app_links/events'),
        MockStreamHandler.inline(onListen: (_, _) {}),
      )
      // The home page's own Terminal tab waits here for good: it would join
      // the Mac over Supabase (the Terminal shot feeds its own remote instead).
      ..setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) => Completer<Object?>().future,
      );
  });

  tearDown(() => cache.deleteSync(recursive: true));

  /// The phone's screen: 393×852 points at 2×, with the notch's and home
  /// indicator's safe areas.
  void phone(WidgetTester tester) {
    tester.view
      ..physicalSize = const Size(786, 1704)
      ..devicePixelRatio = 2
      ..padding = const FakeViewPadding(top: 118, bottom: 68)
      ..viewPadding = const FakeViewPadding(top: 118, bottom: 68);
    addTearDown(tester.view.reset);
    // Soft shadows, as on the phone (tests draw them as black outlines).
    debugDisableShadows = false;
  }

  final shot = GlobalKey();

  Future<void> save(WidgetTester tester, String name) async {
    final boundary = shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File('${_out.path}/$name').writeAsBytesSync(png!.buffer.asUint8List());
      image.dispose();
    });
    debugDisableShadows = true;
  }

  /// Taps [target] and lets what it animates (a pill, the tab bar) finish: the first frame starts it.
  Future<void> tap(WidgetTester tester, Finder target) async {
    await tester.tap(target);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  /// The app, signed in, on [tab] (the Terminal tab it opens on, fed by [terminal]).
  Future<void> app(WidgetTester tester, {String? tab, TerminalRemote? terminal}) async {
    phone(tester);
    final session = await FakeSession.create(_store(), _chats());
    await tester.pumpWidget(
      RepaintBoundary(
        key: shot,
        child: MobileApp(session: session, terminal: terminal),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    if (tab != null) await tap(tester, find.descendant(of: find.byType(AppTabBar), matching: find.text(tab)));
  }

  /// The Pocket tab, on [show] (a pill's label).
  Future<void> pocket(WidgetTester tester, String show) async {
    await app(tester, tab: 'Pocket');
    await tap(tester, find.text(show).first);
  }

  /// The Mac, answering: its state and the finished session's transcript.
  TerminalRemote remote() =>
      TerminalRemote(
          // Never used: the remote talks through `send`.
          SupabaseClient('http://localhost:1', 'anon', authOptions: const AuthClientOptions(autoRefreshToken: false)),
          'user',
          cache,
          from: 'phone',
          send: (_, _) {},
        )
        ..handle('state', _state())
        ..handle('items', _items());

  bool skipped() {
    if (missingFont case final missing?) markTestSkipped('No $missing to draw with.');
    return missingFont != null;
  }

  testWidgets('hero', (tester) async {
    if (skipped()) return;
    if (!_heroPopup.existsSync()) {
      return markTestSkipped('No ${_heroPopup.path}: run the Mac screenshots first.');
    }
    if (!_heroPhone.existsSync()) {
      return markTestSkipped('No ${_heroPhone.path}: take it on the iOS simulator first (docs/BUILDING.md).');
    }
    final (popup, screen) = (await tester.runAsync(() async {
      Future<ui.Image> decode(File f) async =>
          (await (await ui.instantiateImageCodec(f.readAsBytesSync())).getNextFrame()).image;
      return (await decode(_heroPopup), await decode(_heroPhone));
    }))!;
    addTearDown(popup.dispose);
    addTearDown(screen.dispose);
    final canvas = _Hero.canvas(popup);
    tester.view
      ..physicalSize = canvas * 2
      ..devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    debugDisableShadows = false;
    await tester.pumpWidget(
      RepaintBoundary(
        key: shot,
        child: _Hero(popup: popup, screen: screen),
      ),
    );
    await save(tester, 'hero.png');
  });

  testWidgets('pocket on Android', variant: _android, (tester) async {
    if (skipped()) return;
    await pocket(tester, 'All');
    await save(tester, 'phone-pocket-android.png');
  });

  testWidgets('ask', variant: _ios, (tester) async {
    if (skipped()) return;
    await app(tester, tab: 'Ask');
    await tester.tap(find.textContaining('Cold frame or greenhouse'));
    await tester.pumpAndSettle();
    await save(tester, 'phone-ask.png');
  });

  testWidgets('terminal on Android', variant: _android, (tester) async {
    if (skipped()) return;
    final r = remote();
    await app(tester, terminal: r);
    await save(tester, 'phone-terminal-android.png');
    r.flush();
  });

  testWidgets('session', variant: _ios, (tester) async {
    if (skipped()) return;
    final r = remote();
    await app(tester, terminal: r);
    await tester.tap(find.text('Add a soil moisture endpoint'));
    await tester.pumpAndSettle();
    // The test run's card open, its output showing.
    await tester.tap(find.text('npm test -- moisture'));
    await tester.pumpAndSettle();
    await save(tester, 'phone-session.png');
    r.flush();
  });
}

/// The README's hero on a transparent canvas: the Mac's [popup] (a 2× PNG
/// with its shadow) next to the iPhone's [screen] (a 3× capture from the
/// simulator, status bar and Dynamic Island included) in an iPhone's frame,
/// both at their real size in points.
class _Hero extends StatelessWidget {
  const _Hero({required this.popup, required this.screen});
  final ui.Image popup;
  final ui.Image screen;

  /// An iPhone 17 Pro's screen, in points.
  static const _screen = Size(402, 874);
  static const _bezel = 12.0;
  static const _radius = 55.0;

  /// Around the phone, for its shadow; the popup brings its own.
  static const _margin = EdgeInsets.fromLTRB(4, 44, 40, 52);

  static Size _frame() => Size(_screen.width + 2 * _bezel, _screen.height + 2 * _bezel);

  static Size canvas(ui.Image popup) =>
      Size(popup.width / 2 + _margin.horizontal + _frame().width, _margin.vertical + _frame().height);

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: Row(
      children: [
        RawImage(image: popup, scale: 2),
        Padding(
          padding: _margin,
          child: Container(
            width: _frame().width,
            height: _frame().height,
            padding: const EdgeInsets.all(_bezel),
            decoration: BoxDecoration(
              color: const Color(0xFF0A0A0C),
              borderRadius: BorderRadius.circular(_radius + _bezel),
              border: Border.all(color: const Color(0xFF45474D), width: 1.5),
              boxShadow: const [BoxShadow(color: Color(0x4D000000), blurRadius: 36, offset: Offset(0, 14))],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(_radius),
              child: RawImage(image: screen, width: _screen.width, height: _screen.height, fit: BoxFit.cover),
            ),
          ),
        ),
      ],
    ),
  );
}
