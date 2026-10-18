// The Mac screenshots in the docs: the real widgets, made-up data, the Mac's own fonts.
// Run from apps/dzep-macos-app: fvm flutter test --tags screenshots --run-skipped
// They're written to docs/images/mac-*.png and wizard-*.png, and the popup for the README's
// hero (composed with the phone by apps/dzep-mobile's screenshots) to build/screenshots/;
// a plain `fvm flutter test` skips them (dart_test.yaml).
@Tags(['screenshots'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dzep_core/agent.dart';
import 'package:dzep_core/apple_terminal.dart';
import 'package:dzep_core/chat.dart';
import 'package:dzep_core/ghostty.dart';
import 'package:dzep_core/idea.dart';
import 'package:dzep_core/iterm.dart';
import 'package:dzep_core/kitty.dart';
import 'package:dzep_core/terminal.dart';
import 'package:dzep_core/terminals.dart';
import 'package:dzep_core/tmux.dart';
import 'package:dzep_core/ui.dart';
import 'package:dzep_core/wezterm.dart';
import 'package:dzep_macos/controller.dart';
import 'package:dzep_macos/integrations.dart';
import 'package:dzep_macos/live_hub.dart';
import 'package:dzep_macos/main_window.dart';
import 'package:dzep_macos/onboarding/flow.dart';
import 'package:dzep_macos/onboarding/provision.dart';
import 'package:dzep_macos/onboarding/wizard.dart';
import 'package:dzep_macos/popup.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_fakes.dart';
import 'fonts.dart';

final _mac = TargetPlatformVariant.only(TargetPlatform.macOS);
final _out = Directory('../../docs/images');
final GlobalKey _shot = GlobalKey();

/// [h]:[m] [daysAgo] days ago, in local time: the rows read "09:30" or
/// "Yesterday 18:12" whatever day this runs.
DateTime at(int h, int m, {int daysAgo = 0}) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day - daysAgo, h, m);
}

/// A screenshot test: [body] on a Mac, with the view at [size] logical
/// pixels (twice as many physical ones), real fonts and real (blurred)
/// shadows. Skipped without the Mac's fonts.
void shot(String description, Size size, Future<void> Function(WidgetTester tester) body) =>
    testWidgets(description, (tester) async {
      if (missingFont() case final missing?) return markTestSkipped('No $missing on this machine');
      await tester.runAsync(loadRealFonts);
      tester.view
        ..physicalSize = size * 2
        ..devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      debugDisableShadows = false;
      try {
        await body(tester);
      } finally {
        debugDisableShadows = true;
      }
    }, variant: _mac);

/// [child] as main.dart hosts a window ([window]), with the glyphs SF Pro
/// lacks (⇥, ↵, emoji) from the fonts macOS falls back to, and painted into
/// [_shot].
Widget subject(Widget child) => window(
  RepaintBoundary(
    key: _shot,
    child: Builder(
      builder: (context) {
        const fallback = ['Apple Symbols', 'Apple Color Emoji'];
        final theme = Theme.of(context);
        // The fields' text comes from the theme, the rest from the default style.
        return Theme(
          data: theme.copyWith(textTheme: theme.textTheme.apply(fontFamilyFallback: fallback)),
          child: DefaultTextStyle.merge(
            style: const TextStyle(fontFamilyFallback: fallback),
            child: child,
          ),
        );
      },
    ),
  ),
);

/// Writes [crop] (global logical pixels; all of [_shot] if null) of what
/// [_shot] paints to [dir] (docs/images if null)/[name], rounded by [radius]
/// and outlined in [border] if given.
Future<void> save(
  WidgetTester tester,
  String name, {
  Rect? crop,
  double radius = 0,
  Color? border,
  Directory? dir,
}) async {
  final box = tester.getRect(find.byKey(_shot));
  final r = (crop ?? box).intersect(box).shift(-box.topLeft);
  await tester.runAsync(() async {
    final boundary = _shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final full = await boundary.toImage(pixelRatio: 2);
    final src = Rect.fromLTRB(r.left * 2, r.top * 2, r.right * 2, r.bottom * 2);
    final (w, h) = (src.width.round(), src.height.round());
    final dst = Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final shape = RRect.fromRectAndRadius(dst, Radius.circular(radius * 2));
    if (radius > 0) canvas.clipRRect(shape);
    canvas.drawImageRect(full, src, dst, Paint()..filterQuality = FilterQuality.none);
    if (border != null) {
      canvas.drawRRect(
        shape.deflate(1),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = border,
      );
    }
    final image = await recorder.endRecording().toImage(w, h);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    final to = (dir ?? _out)..createSync(recursive: true);
    File('${to.path}/$name').writeAsBytesSync(png!.buffer.asUint8List());
  });
}

/// Adds to [s] as if at [when].
Idea add(
  FakeStore s,
  DateTime when,
  String title, {
  Kind kind = Kind.idea,
  String notes = '',
  String project = '',
  DateTime? remindAt,
}) {
  s.clock = when.subtract(const Duration(minutes: 1));
  return s.add(title: title, kind: kind, notes: notes, project: project, remindAt: remindAt);
}

/// A demo account's ideas, todos and notes; the idea the main window shows.
Idea fill(FakeStore s) {
  add(s, at(11, 20, daysAgo: 1), 'Weekly digest email of open todos', project: 'garden-web');
  add(s, at(14, 5, daysAgo: 1), 'Batch sync endpoint for the mobile app', project: 'garden-api');
  add(s, at(16, 40, daysAgo: 1), 'Dark mode for the dashboard', project: 'garden-web');
  final retry = add(
    s,
    at(18, 12, daysAgo: 1),
    'Retry queue for offline sync',
    project: 'garden-api',
    notes:
        'Writes made offline go into a queue and replay in order once the connection is back.\n\n'
        '- back off: 1s, 5s, 30s, then every 5 min\n'
        '- keep the queue on disk, so a restart doesn’t lose it\n'
        '- show “3 changes waiting” in the status bar',
  );
  add(s, at(8, 47), 'Offline banner in the web app', project: 'garden-web');
  add(s, at(9, 30), 'Watering reminders based on rain data', project: 'garden-app');
  add(s, at(10, 15), 'Share a garden plan as a read-only link', project: 'garden-app');

  final tomorrow = at(9, 0, daysAgo: -1);
  add(s, at(7, 10, daysAgo: 1), 'Water the tomatoes', kind: Kind.todo);
  s.update(s.openTodos.first, done: true);
  add(
    s,
    at(8, 2, daysAgo: 1),
    'Call the plumber about the garden tap',
    kind: Kind.todo,
    remindAt: at(17, 0, daysAgo: 1),
  );
  add(s, at(19, 30, daysAgo: 1), 'Pay the electricity bill', kind: Kind.todo, remindAt: tomorrow);
  add(s, at(8, 20), 'Renew passport', kind: Kind.todo);
  add(s, at(9, 5), 'Send Ana the invoice for September', kind: Kind.todo);
  add(s, at(9, 50), 'Book the dentist', kind: Kind.todo);

  void note(DateTime when, String text) {
    s
      ..clock = when.subtract(const Duration(minutes: 1))
      ..addNote(text);
  }

  note(at(7, 15, daysAgo: 1), 'Packing list for the allotment\nGloves, twine, seed trays');
  note(at(9, 40, daysAgo: 1), 'Standup notes\nSync is green; web deploy Thursday');
  note(at(17, 25, daysAgo: 1), 'Garden API rate limits\n100 requests a minute per token');
  note(at(8, 30), 'Recipes to try\nTomato galette, pesto with rocket');
  return retry;
}

/// The phone screenshots' todos (apps/dzep-mobile/test/screenshots/), for
/// the README's hero: the popup next to the phone, the same list on both.
void phoneTodos(FakeStore s) {
  void todo(DateTime when, String title, {DateTime? remindAt, bool done = false}) {
    final t = add(s, when, title, kind: Kind.todo, remindAt: remindAt);
    if (done) s.update(t, done: true);
  }

  todo(at(21, 0, daysAgo: 5), 'Back up the photos to the NAS', done: true);
  todo(at(10, 0, daysAgo: 4), 'Pay the electricity bill', done: true);
  todo(at(16, 2, daysAgo: 3), 'Write release notes for 0.4');
  todo(at(9, 20, daysAgo: 2), 'Call Ana about the garden plan', remindAt: at(17, 0, daysAgo: 1));
  todo(at(12, 30, daysAgo: 1), 'Book the dentist for next month');
  todo(at(18, 5, daysAgo: 1), 'Buy basil and tomato seedlings', remindAt: at(15, 0, daysAgo: -4));
  todo(at(8, 12), 'Review Marko’s pull request on garden-api');
  todo(at(8, 41), 'Renew the domain for dzep-site', remindAt: at(9, 0, daysAgo: -1));
}

Conversation chat(String id, DateTime when, String question, String answer) => Conversation(
  id: id,
  createdAt: when,
  updatedAt: when,
  messages: [
    ChatMessage(fromUser: true, text: question),
    ChatMessage(fromUser: false, text: answer),
  ],
);

/// The popup as main.dart hosts it (its fixed transparent 720×660 panel),
/// with room around for the card's shadow; open in [mode] on [data].
Future<FakeApp> pumpPopup(
  WidgetTester tester,
  PopupMode mode, {
  void Function(FakeStore s) data = fill,
  void Function(FakeApp app)? setUp,
}) async {
  final app = await FakeApp.create(popupMode: mode.name);
  data(app.fakeStore);
  setUp?.call(app);
  await tester.pumpWidget(
    subject(
      Padding(
        padding: const EdgeInsets.fromLTRB(28, 30, 28, 30),
        child: Align(
          alignment: Alignment.topCenter,
          child: SizedBox(width: 720, height: 660, child: Popup(app: app)),
        ),
      ),
    ),
  );
  await app.openPopup();
  await tester.pumpAndSettle();
  return app;
}

/// The popup's card and its shadow.
Rect popupCard(WidgetTester tester) {
  final card = tester.getRect(find.byType(AnimatedSize).first).inflate(1);
  return Rect.fromLTRB(card.left - 44, card.top - 30, card.right + 44, card.bottom + 64);
}

Future<void> type(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(EditableText).first, text);
  await tester.pumpAndSettle();
}

/// The setup wizard at [flow]'s step, as the main window shows it before
/// there is a server.
Future<void> pumpWizard(WidgetTester tester, SetupFlow flow) async {
  addTearDown(flow.dispose);
  await tester.pumpWidget(
    subject(
      ColoredBox(
        color: C.win,
        child: SetupWizard(flow: flow, onConnect: (_) async {}, onExisting: () {}),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Types [text] into the [index]th text field, then leaves it.
Future<void> fillField(WidgetTester tester, int index, String text) async {
  await tester.enterText(find.byType(TextField).at(index), text);
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
}

/// The terminals a well-equipped Mac has, as Settings finds them.
class DemoTerminals extends Terminals {
  DemoTerminals()
    : super(
        kitty: Kitty(socketDir: '/nonexistent-dzep-demo', home: '/nonexistent-dzep-demo'),
        tmux: Tmux(executable: '/nonexistent-dzep-demo/tmux', socketDirs: const []),
        wezterm: WezTerm(executable: '/nonexistent-dzep-demo/wezterm', socketDir: '/nonexistent-dzep-demo'),
        iterm: ITerm(appPath: '/nonexistent-dzep-demo/iTerm.app'),
        terminal: AppleTerminal(appPath: '/nonexistent-dzep-demo/Terminal.app'),
        ghostty: Ghostty(appPath: '/nonexistent-dzep-demo/Ghostty.app'),
        recency: () async => const [],
        snapshot: () async => Procs(const []),
      );

  @override
  Future<List<TermStatus>> statuses() async => [
    TermStatus(kitty.id, kitty.label, TermState.ready, note: '3 windows'),
    TermStatus(tmux.id, tmux.label, TermState.ready, note: '2 panes'),
    TermStatus(wezterm.id, wezterm.label, TermState.ready, note: '1 window'),
    TermStatus(iterm.id, iterm.label, TermState.limited, note: '2 windows · ${iterm.limits}'),
    TermStatus(terminal.id, terminal.label, TermState.limited, note: '1 window · ${terminal.limits}'),
    TermStatus(ghostty.id, ghostty.label, TermState.limited, note: '1 window · ${ghostty.limits}'),
  ];

  @override
  Future<List<TermWindow>> windows() async => [
    for (var i = 0; i < 10; i++) TermWindow(key: 'demo:$i', title: '', tab: '', cwd: '', program: ''),
  ];
}

/// A coding agent's extension connection that goes nowhere.
class _Link implements LiveLink {
  @override
  void send(String frame) {}

  @override
  Future<void> close() async {}
}

void main() {
  const popupView = Size(776, 720);

  shot('popup: idea', popupView, (tester) async {
    await pumpPopup(tester, PopupMode.idea);
    await type(tester, 'Offline mode for the sync @garden-api ');
    await save(tester, 'mac-popup-idea.png', crop: popupCard(tester));
  });

  shot('popup: todo', popupView, (tester) async {
    await pumpPopup(tester, PopupMode.todo);
    await type(tester, 'call the bank !tomorrow 15:00');
    await save(tester, 'mac-popup-todo.png', crop: popupCard(tester));
  });

  // The README's hero: the popup's open todos, the phone's list.
  shot('popup: hero', popupView, (tester) async {
    await pumpPopup(tester, PopupMode.todo, data: phoneTodos);
    await save(tester, 'hero-popup.png', crop: popupCard(tester), dir: Directory('build/screenshots'));
  });

  shot('popup: note', popupView, (tester) async {
    await pumpPopup(tester, PopupMode.note);
    await type(
      tester,
      'Release checklist for garden-api 1.4\n'
      '- bump the version and tag it\n'
      '- run the migration on staging first\n'
      '- ask Ana to review the changelog',
    );
    await save(tester, 'mac-popup-note.png', crop: popupCard(tester));
  });

  shot('popup: ask', popupView, (tester) async {
    await pumpPopup(
      tester,
      PopupMode.ask,
      setUp: (app) {
        final current = chat(
          'c4',
          at(10, 2),
          'How do I undo the last git commit but keep the changes?',
          'Use a **soft reset**: it moves `HEAD` back one commit and leaves your changes staged.\n\n'
              '```sh\n'
              'git reset --soft HEAD~1\n'
              '```\n\n'
              'Want them unstaged instead? Drop `--soft` (the default is `--mixed`).',
        );
        app.fakeChats
          ..ai = const AiStatus(connected: true)
          ..chats.addAll([
            chat('c1', at(12, 30, daysAgo: 1), 'Translate “watering can” to German', 'Die Gießkanne.'),
            chat('c2', at(16, 45, daysAgo: 1), 'Difference between PATCH and PUT?', 'PUT replaces, PATCH changes.'),
            chat('c3', at(9, 20), 'Cron expression for every weekday at 7:00', '`0 7 * * 1-5`'),
            current,
          ])
          ..resume(current);
      },
    );
    // ↓ from the empty question lists the recent chats under the answer.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await save(tester, 'mac-popup-ask.png', crop: popupCard(tester));
  });

  shot('main window', const Size(1080, 720), (tester) async {
    final app = await FakeApp.create()
      ..name = 'Ana';
    final selected = fill(app.fakeStore);
    const radius = BorderRadius.all(Radius.circular(10));
    Widget light(Color color) => Container(
      width: 12,
      height: 12,
      margin: const EdgeInsets.only(right: 8),
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
    await tester.pumpWidget(
      subject(
        Padding(
          padding: const EdgeInsets.fromLTRB(40, 30, 40, 50),
          child: Container(
            foregroundDecoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(color: C.line2),
            ),
            decoration: const BoxDecoration(
              borderRadius: radius,
              boxShadow: [BoxShadow(color: Color(0x73000000), blurRadius: 30, offset: Offset(0, 12))],
            ),
            child: ClipRRect(
              borderRadius: radius,
              child: Stack(
                children: [
                  ListenableBuilder(
                    listenable: app,
                    builder: (_, _) => MainWindow(app: app),
                  ),
                  // The window's traffic lights, which macOS draws over it.
                  Positioned(
                    left: 20,
                    top: 16,
                    child: Row(
                      children: [
                        light(const Color(0xFFFF5F57)),
                        light(const Color(0xFFFEBC2E)),
                        light(const Color(0xFF28C840)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await app.openMain(select: selected.id);
    await tester.pumpAndSettle();
    await save(tester, 'mac-main.png');
  });

  // Tall enough that Settings doesn't scroll.
  shot('settings: terminals', const Size(560, 2000), (tester) async {
    final home = Directory.systemTemp.createTempSync('dzep-shots').path;
    addTearDown(() => Directory(home).deleteSync(recursive: true));
    final integrations = Integrations(home: home, run: (_, _) async => ProcessResult(0, 1, '', ''));
    await tester.runAsync(() => integrations.install(Agent.omp));
    final app = await FakeApp.create(terminals: DemoTerminals())
      ..name = 'Ana'
      ..hotKeyRegistered = true;
    fill(app.fakeStore);
    await (await SharedPreferences.getInstance()).setBool('terminal_bridge', true);
    // DemoTerminals' home, so it reads ~/Dev.
    await app.setProjectRoots(['/nonexistent-dzep-demo/Dev']);
    // Two coding agents report to Džep.
    for (final (pid, title) in [(101, 'Retry queue'), (102, 'Dark mode')]) {
      final frames = StreamController<String>();
      addTearDown(frames.close);
      unawaited(app.live.accept(frames.stream, _Link()));
      frames.add(
        '{"t":"hello","v":1,"pid":$pid,"agent":"omp","busy":false,"items":[],'
        '"session":{"id":"s$pid","title":"$title","cwd":"/Users/demo/Dev/garden-api","model":"m"}}',
      );
    }
    await tester.pumpWidget(
      subject(
        Stack(
          children: [
            const Positioned.fill(child: ColoredBox(color: C.win)),
            ListenableBuilder(
              listenable: app,
              builder: (_, _) => SettingsSheet(app: app, integrations: integrations),
            ),
          ],
        ),
      ),
    );
    for (var i = 0; i < 100 && find.text('Installed and up to date').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    final card = tester.getRect(find.byWidgetPredicate((w) => w is Container && w.constraints?.maxWidth == 500));
    final top = tester.getRect(find.text('GENERAL')).top - 16;
    await save(
      tester,
      'mac-settings-terminals.png',
      crop: Rect.fromLTRB(card.left, top, card.right, card.bottom),
      radius: 12,
      border: C.line2,
    );
  });

  // The setup wizard, made-up values only: no account, token or project is real.
  const wizardView = Size(540, 620);
  const wizardCard = (radius: 12.0, border: C.line2);

  shot('wizard: token', wizardView, (tester) async {
    await pumpWizard(tester, SetupFlow()..step = WizardStep.token);
    await fillField(tester, 0, 'sbp_demo0000000000000000000000000000000000');
    await save(tester, 'wizard-token.png', radius: wizardCard.radius, border: wizardCard.border);
  });

  shot('wizard: github', wizardView, (tester) async {
    await pumpWizard(
      tester,
      SetupFlow()
        ..step = WizardStep.github
        ..ref = 'demoprojectrefabcdef',
    );
    await fillField(tester, 0, 'Ov23liDemo0000000000');
    await fillField(tester, 1, 'demo0000000000000000000000000000000000000');
    await save(tester, 'wizard-github.png', radius: wizardCard.radius, border: wizardCard.border);
  });

  shot('wizard: ready', wizardView, (tester) async {
    final flow = SetupFlow()
      ..step = WizardStep.setup
      ..aiKey = 'demo'
      ..ready = true;
    flow.done.addAll(ProvisionStep.values);
    await pumpWizard(tester, flow);
    await save(tester, 'wizard-ready.png', radius: wizardCard.radius, border: wizardCard.border);
  });
}
