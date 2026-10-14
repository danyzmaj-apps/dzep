import 'dart:convert';

import 'package:dzep_core/agent.dart';
import 'package:dzep_core/live.dart';
import 'package:flutter_test/flutter_test.dart';

LiveItem _text(String id, String text, {ItemKind kind = ItemKind.assistant}) =>
    LiveItem(id: id, kind: kind, text: text);

/// What a phone ends up with when every op reaches it through JSON.
LiveView _follow(LiveLog log, List<LiveOp> ops, {LiveView? view}) {
  final v = view ?? LiveView(epoch: log.epoch);
  final wire = [for (final op in ops) LiveOp.fromJson(jsonDecode(jsonEncode(op.toJson())) as Map<String, dynamic>)];
  expect(v.apply(log.epoch, wire), isTrue);
  return v;
}

void main() {
  group('LiveLog → LiveView', () {
    test('a phone that follows every op ends with what the Mac has', () {
      final log = LiveLog([_text('u1', 'hi', kind: ItemKind.user)], older: false);
      final view = LiveView(epoch: log.epoch)
        ..catchUp(epoch: log.epoch, seq: log.seq, reset: true, items: log.items, last: true);
      final ops = [
        log.upsert(_text('a1', '')),
        log.append('a1', 'Hel')!,
        log.append('a1', 'lo')!,
        log.upsert(LiveItem(id: 't1', kind: ItemKind.tool, tool: 'bash', args: 'ls')),
        log.upsert(LiveItem(id: 't1', kind: ItemKind.tool, tool: 'bash', args: 'ls', output: 'a\nb')),
      ];
      _follow(log, ops, view: view);
      expect(view.items.map((i) => i.id), ['u1', 'a1', 't1']);
      expect(view.items[1].text, 'Hello');
      expect(view.items[2].output, 'a\nb');
      expect(view.seq, log.seq);
    });

    test('a replaced item shows its new text even when the list was read in between', () {
      final log = LiveLog([], older: false);
      final view = _follow(log, [log.upsert(_text('a1', '')), log.append('a1', 'Hel')!]);
      expect(view.items.single.text, 'Hel');
      // The answer's final text, whole: the last streamed bit never went out on its own.
      _follow(log, [log.upsert(_text('a1', 'Hello.'))], view: view);
      expect(view.items.single.text, 'Hello.');
    });

    test('an op holds the item as it was: a later append is not applied twice', () {
      final log = LiveLog([], older: false);
      final upsert = log.upsert(_text('a1', 'He'));
      final append = log.append('a1', 'llo')!;
      // Both are serialized only now, as a batch would be.
      final view = _follow(log, [upsert, append]);
      expect(view.items.single.text, 'Hello');
    });

    test('a missing op is detected, and a catch-up from since fills the gap', () {
      final log = LiveLog([], older: false);
      final first = log.upsert(_text('a1', 'one'));
      final view = _follow(log, [first]);
      log.upsert(_text('a2', 'two')); // lost on the way
      final third = log.upsert(_text('a3', 'three'));
      expect(view.apply(log.epoch, [third]), isFalse);
      view.catchUp(epoch: log.epoch, seq: log.seq, reset: false, items: log.since(view.seq), last: true);
      expect(view.items.map((i) => i.text), ['one', 'two', 'three']);
      expect(view.seq, log.seq);
      // Ops the catch-up already covered are skipped, not doubled.
      expect(view.apply(log.epoch, [third]), isTrue);
      expect(view.items.length, 3);
    });

    test('a new epoch is refused by apply and replaces everything on a reset catch-up', () {
      final old = LiveLog([_text('x', 'old')], older: false);
      final view = LiveView(epoch: old.epoch)
        ..catchUp(epoch: old.epoch, seq: old.seq, reset: true, items: old.items, last: true);
      final log = LiveLog([_text('y', 'new')], older: true);
      expect(view.apply(log.epoch, [log.upsert(_text('z', '!'))]), isFalse);
      view.catchUp(epoch: log.epoch, seq: log.seq, reset: true, items: log.items, last: true, older: log.older);
      expect(view.items.map((i) => i.id), ['y', 'z']);
      expect(view.older, isTrue);
    });

    test('seq moves only with the last chunk of a catch-up', () {
      final log = LiveLog([for (var i = 0; i < 4; i++) _text('$i', '$i')], older: false);
      final view = LiveView(epoch: log.epoch);
      final items = log.items;
      view.catchUp(epoch: log.epoch, seq: log.seq, reset: true, items: items.sublist(0, 2), last: false);
      expect(view.seq, 0);
      view.catchUp(epoch: log.epoch, seq: log.seq, reset: true, items: items.sublist(2), last: true);
      expect(view.seq, log.seq);
      expect(view.items.length, 4);
    });

    test('older items go above the oldest, in their own order, and reach a follower', () {
      final log = LiveLog([_text('c', 'c'), _text('d', 'd')], older: true);
      final view = LiveView(epoch: log.epoch)
        ..catchUp(epoch: log.epoch, seq: log.seq, reset: true, items: log.items, last: true);
      final ops = log.addOlder([_text('a', 'a'), _text('b', 'b'), _text('c', 'dup')], more: false);
      _follow(log, ops, view: view);
      expect(view.items.map((i) => i.id), ['a', 'b', 'c', 'd']);
      expect(view.items[2].text, 'c', reason: 'an item already there is not replaced by an older copy');
      expect(log.older, isFalse);
    });

    test('past its cap the log drops the oldest items and says there are older ones', () {
      final log = LiveLog([for (var i = 0; i < 5; i++) _text('$i', '$i')], older: false, cap: 3);
      expect(log.items.map((i) => i.id), ['2', '3', '4']);
      expect(log.older, isTrue);
      log.upsert(_text('5', '5'));
      expect(log.items.map((i) => i.id), ['3', '4', '5']);
    });

    test('the disk cache keeps the newest items and remembers the rest are on the Mac', () {
      final log = LiveLog([for (var i = 0; i < 10; i++) _text('$i', '$i')], older: false);
      final view = LiveView(epoch: log.epoch)
        ..catchUp(epoch: log.epoch, seq: log.seq, reset: true, items: log.items, last: true);
      final back = LiveView.fromJson(jsonDecode(jsonEncode(view.toJson(keep: 4))) as Map<String, dynamic>);
      expect(back.items.map((i) => i.id), ['6', '7', '8', '9']);
      expect(back.older, isTrue);
      expect(back.seq, view.seq);
      // A cached view still follows the live ops.
      _follow(log, [log.upsert(_text('10', 'x'))], view: back);
      expect(back.items.last.id, '10');
    });
  });

  group('answerKeys', () {
    LiveAsk ask(List<LiveQuestion> qs) => LiveAsk.questions('call', qs);
    const db = LiveQuestion(id: 'db', question: 'Database?', options: ['SQLite', 'Postgres', 'MySQL']);
    List<Object> flat(List<KeyStep> steps) => [
      for (final s in steps)
        switch (s) {
          Keys(:final keys) => keys.join(' '),
          Typed(:final text) => 'type:$text',
          Settle() => 'wait',
        },
    ];
    String to(int row, int rows) => [...List.filled(rows, 'up'), ...List.filled(row, 'down')].join(' ');

    test('a single choice goes to the top, down to its row and presses Enter', () {
      expect(
        flat(
          answerKeys(
            ask([db]),
            answers: [
              const LiveAnswer(picks: [1]),
            ],
          ),
        ),
        ['${to(1, 4)} enter'],
      );
    });

    test('a typed answer picks Other, waits for the editor, types, and confirms', () {
      expect(flat(answerKeys(ask([db]), answers: [const LiveAnswer(custom: ' DuckDB ')])), [
        '${to(3, 4)} enter',
        'wait',
        'type:DuckDB',
        'enter',
        'wait',
      ]);
    });

    test('typed answers to several questions: each editor closes before the next keys, and Submit waits too', () {
      const q2 = LiveQuestion(id: 'wt', question: 'Worktree?', options: ['Yes', 'No']);
      expect(
        flat(
          answerKeys(
            ask([db, q2]),
            answers: [
              const LiveAnswer(custom: 'a'),
              const LiveAnswer(custom: 'b'),
            ],
          ),
        ),
        [
          '${to(3, 4)} enter',
          'wait',
          'type:a',
          'enter',
          'wait',
          '${to(2, 3)} enter',
          'wait',
          'type:b',
          'enter',
          'wait',
          'enter',
        ],
      );
    });

    test('multiple choice toggles each pick with Space, then Enter', () {
      const q = LiveQuestion(id: 'f', question: 'Features?', options: ['a', 'b', 'c'], multi: true);
      expect(
        flat(
          answerKeys(
            ask([q]),
            answers: [
              const LiveAnswer(picks: [0, 2]),
            ],
          ),
        ),
        ['${to(0, 4)} space ${to(2, 4)} space enter'],
      );
    });

    test('a lone multiple-choice question with typed text ends on the Submit tab', () {
      const q = LiveQuestion(id: 'f', question: 'Features?', options: ['a'], multi: true);
      expect(
        flat(
          answerKeys(
            ask([q]),
            answers: [
              const LiveAnswer(picks: [0], custom: 'z'),
            ],
          ),
        ),
        ['${to(0, 2)} space ${to(1, 2)} enter', 'wait', 'type:z', 'enter', 'wait', 'enter'],
      );
    });

    test('several questions answer one after another, then submit', () {
      const q2 = LiveQuestion(id: 'os', question: 'OS?', options: ['mac', 'linux']);
      expect(
        flat(
          answerKeys(
            ask([db, q2]),
            answers: [
              const LiveAnswer(picks: [2]),
              const LiveAnswer(picks: [0]),
            ],
          ),
        ),
        ['${to(2, 4)} enter ${to(0, 3)} enter', 'wait', 'enter'],
      );
    });

    test('approval: Enter approves, Down Enter denies', () {
      const a = LiveAsk.approval('call', tool: 'bash');
      expect(flat(answerKeys(a, approve: true)), ['enter']);
      expect(flat(answerKeys(a)), ['down enter']);
    });

    test('answers that the dialog cannot take are refused before any key goes out', () {
      expect(() => answerKeys(ask([db]), answers: []), throwsArgumentError);
      expect(
        () => answerKeys(
          ask([db]),
          answers: [
            const LiveAnswer(picks: [3]),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => answerKeys(
          ask([db]),
          answers: [
            const LiveAnswer(picks: [0, 1]),
          ],
        ),
        throwsArgumentError,
      );
      expect(() => answerKeys(ask([db]), answers: [const LiveAnswer(custom: '  ')]), throwsArgumentError);
    });
  });

  group('askOnScreen', () {
    test('finds a question wrapped and styled by the terminal', () {
      const q = LiveQuestion(id: 'x', question: 'Which **storage** backend should the sync layer use?', options: ['a']);
      const screen = '│ Which storage backend should\n│ the sync layer use?\n│ > a';
      expect(askOnScreen(const LiveAsk.questions('c', [q]), screen.replaceAll('│', '')), isTrue);
      expect(askOnScreen(const LiveAsk.questions('c', [q]), 'π > waiting for input'), isFalse);
    });

    test('an approval needs both of its buttons on screen', () {
      const a = LiveAsk.approval('c', tool: 'bash');
      expect(askOnScreen(a, 'Run bash?\n> Approve\n  Deny'), isTrue);
      expect(askOnScreen(a, 'Approve the plan'), isFalse);
    });

    test('a plan review is recognised by its header, whatever has focus', () {
      const plan = LiveAsk.plan('c', title: 'notes');
      expect(askOnScreen(plan, _planScreen()), isTrue);
      expect(askOnScreen(plan, _planScreen(help: '↑/↓ scroll · a annotate · ⇥ regions')), isTrue);
      expect(askOnScreen(plan, 'π > waiting for input\n  plan the next release'), isFalse);
    });
  });

  group('plan review', () {
    test('reads the options and the cursor row, past the slider and a wrapped row', () {
      final review = parsePlanReview(_planScreen());
      expect(review?.options, [
        'Approve and execute',
        'Approve and compact context',
        'Approve and keep context (~47k / 1m) — then save every draft note as it changes',
        'Refine plan',
        'Save and quit',
      ]);
      expect(review?.current, 2);
    });

    test('reads a review without the slider, with the cursor on the last option', () {
      final screen = _planScreen(slider: false, cursor: 4, long: false);
      expect(parsePlanReview(screen)?.options.length, 5);
      expect(parsePlanReview(screen)?.current, 4);
    });

    test('is not read while the plan text has focus, once a choice is made, or without a review', () {
      expect(parsePlanReview(_planScreen(help: '↑/↓ scroll · a annotate · ⇥ regions')), isNull);
      expect(parsePlanReview(_planScreen(help: 'Applying your selection — this can take a moment.')), isNull);
      expect(parsePlanReview('π > waiting for input\n↑/↓ select'), isNull);
    });

    test('keys go down or up from the cursor to the option, then Enter', () {
      expect(menuKeys(1, 3), ['down', 'down', 'enter']);
      expect(menuKeys(3, 0), ['up', 'up', 'up', 'enter']);
      expect(menuKeys(2, 2), ['enter']);
      expect(menuKeys(4, 1, enter: false), ['up', 'up', 'up']);
    });

    test('keys never go above the first option', () {
      expect(() => menuKeys(2, -1), throwsArgumentError);
      expect(() => menuKeys(-1, 0), throwsArgumentError);
      expect(menuKeys(0, 0), ['enter']);
    });

    test('a plan ask goes through JSON with its options and cursor', () {
      const ask = LiveAsk.plan(
        'call',
        title: 'notes-plan',
        options: ['Approve and execute', 'Refine plan'],
        selected: 1,
      );
      final back = LiveAsk.fromJson(jsonDecode(jsonEncode(ask.toJson())) as Map<String, dynamic>);
      expect(back.isPlan, isTrue);
      expect(back.id, 'call');
      expect(back.title, 'notes-plan');
      expect(back.options, ask.options);
      expect(back.selected, 1);
      expect(back.text, 'Plan ready: notes-plan');
      // The extension sends a plan without options; the Mac reads them off the screen.
      final bare = LiveAsk.fromJson(const {'kind': 'plan', 'id': 'x', 'title': 'notes-plan'});
      expect(bare.isPlan, isTrue);
      expect(bare.options, isEmpty);
    });
  });

  group('pickers', () {
    // /resume in a 60-column kitty, as its plain text reads.
    const resume = '''
 Resume Session (current folder)

 > █

 ❯ Build kitty socket client and live protoc…
   i want you to review our WHOLE terminal f…
   3 minutes ago  ·  5.2MB  ·  ✔ done

   Check if mobile app rebuild needed
   we did bunch of changes to this app, do i…
   1 day ago  ·  239.3KB  ·  ✔ done

   Fix popup notes
   2 days ago  ·  12.1KB
   …
 [⌦/⌫ delete · ⏎ select · ⇥ all projects · esc cancel]''';

    test('/resume: one item per block, its first line the label and the rest the detail', () {
      final menu = parseMenu(resume);
      expect(menu?.title, 'Resume Session (current folder)');
      expect(menu?.filter, isTrue);
      expect(menu?.current, 0);
      expect(menu?.items, [
        (
          label: 'Build kitty socket client and live protoc…',
          detail: 'i want you to review our WHOLE terminal f… · 3 minutes ago · 5.2MB · ✔ done',
        ),
        (
          label: 'Check if mobile app rebuild needed',
          detail: 'we did bunch of changes to this app, do i… · 1 day ago · 239.3KB · ✔ done',
        ),
        (label: 'Fix popup notes', detail: '2 days ago · 12.1KB'),
      ]);
    });

    test('/resume in its box, with a scrollbar and the cursor further down', () {
      String row(String s) => '│ ${s.padRight(54)}${s.startsWith('  ') ? '█' : '│'} │';
      final screen = [
        'π  earlier answer in the transcript',
        '╭─ Resume Session (current folder) ───────────────────────╮',
        row('> fix'),
        row(''),
        row('  Build kitty socket client'),
        row('  3 minutes ago  ·  5.2MB'),
        row(''),
        row('❯ Fix popup notes'),
        row('  2 days ago  ·  12.1KB'),
        row(''),
        row('[⌦/⌫ delete · ⏎ select · ⇥ all projects · esc cancel]'),
        '╰${'─' * 58}╯',
      ].join('\n');
      final menu = parseMenu(screen);
      expect(menu?.title, 'Resume Session (current folder)');
      expect(menu?.filter, isTrue);
      expect(menu?.current, 1);
      expect(menu?.items.map((i) => i.label), ['Build kitty socket client', 'Fix popup notes']);
      expect(menu?.items.last.detail, '2 days ago · 12.1KB');
    });

    test('a simple picker: one item per line, a described one split at its gap', () {
      const screen = '''
π  Theme changed.

 Select theme

   dark
   light       the default
 ❯ solarized
   nord
   (3/4)  Type to search

 ↑/↓ navigate  ⏎ select  esc cancel''';
      final menu = parseMenu(screen);
      expect(menu?.title, 'Select theme');
      expect(menu?.current, 2);
      expect(menu?.filter, isTrue);
      expect(menu?.items, [
        (label: 'dark', detail: ''),
        (label: 'light', detail: 'the default'),
        (label: 'solarized', detail: ''),
        (label: 'nord', detail: ''),
      ]);
    });

    test("omp's prompt and the plan review are not pickers", () {
      const prompt = '''
π  Done: the popup keeps its notes now.
   > ran 3 tests

╭──────────────────────────────────────────────────────────╮
│ > █                                                        │
╰──────────────────────────────────────────────────────────╯
  opus-4.5 · 12% · ~/Dev/dzep''';
      expect(parseMenu(prompt), isNull);
      expect(parseMenu(_planScreen()), isNull);
    });

    test("Claude Code's transcript prompts are not pickers; its /model is", () {
      // Its prompt line is ❯ and a no-break space, under the transcript's `❯ ` prompts.
      const idle =
          '⏺ pong\n'
          '\n'
          '› Prompt from the dzep plugin\n'
          '❯ Reply just: Q3OK\n'
          '\n'
          '⏺ Q3OK\n'
          '────────────────────────────────────────\n'
          '❯\u00a0\n'
          '────────────────────────────────────────\n'
          '  ⏸ manual mode on · ? for shortcuts';
      expect(parseMenu(idle), isNull);
      const model =
          '❯ Reply just: Q3OK\n'
          '▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔\n'
          '   Select model\n'
          '\n'
          '   ❯ 1.  Default (recommended) ✔  Opus 5.5\n'
          '     2.  Sonnet 5.5               Most efficient\n'
          '\n'
          '   Enter to set as default · Esc to cancel';
      final menu = parseMenu(model);
      expect(menu?.title, 'Select model');
      expect(menu?.current, 0);
      expect(menu?.items.map((i) => i.label), ['1. Default (recommended) ✔', '2. Sonnet 5.5']);
    });

    test('a picker is on screen while its title is', () {
      const ask = LiveAsk.menu('m1', title: 'Resume Session (current folder)', items: []);
      expect(askOnScreen(ask, resume), isTrue);
      expect(askOnScreen(const LiveAsk.menu('m1', title: 'Select theme', items: []), resume), isFalse);
    });

    test('a picker goes through JSON with its items, cursor and filter', () {
      const ask = LiveAsk.menu(
        'menu-3',
        title: 'Select model',
        items: [(label: 'opus', detail: 'Anthropic · 200k'), (label: 'gpt-5', detail: '')],
        selected: 1,
        filter: true,
      );
      final back = LiveAsk.fromJson(jsonDecode(jsonEncode(ask.toJson())) as Map<String, dynamic>);
      expect(back.isMenu, isTrue);
      expect(back.id, 'menu-3');
      expect(back.title, 'Select model');
      expect(back.items, ask.items);
      expect(back.selected, 1);
      expect(back.filter, isTrue);
      expect(back.text, 'Select model');
    });
  });

  group('ScreenDiff', () {
    List<String> lines(int from, int to) => [for (var i = from; i < to; i++) 'line $i'];

    test('scrolled output costs only the new lines', () {
      final a = lines(0, 100);
      final b = [...lines(5, 100), ...lines(100, 105)];
      final d = ScreenDiff.between(a, b)!;
      expect((d.drop, d.keep, d.tail.length), (5, 95, 5));
      expect(d.apply(a), b);
    });

    test('a redrawn bottom is sent from the first changed line', () {
      final a = lines(0, 50);
      final b = [...lines(0, 45), 'x', 'y'];
      final d = ScreenDiff.between(a, b)!;
      expect(d.tail, ['x', 'y']);
      expect(d.apply(a), b);
    });

    test('an unrelated screen goes whole', () {
      expect(ScreenDiff.between(lines(0, 10), lines(50, 60)), isNull);
    });

    test('a diff on the wrong base is refused rather than misapplied', () {
      final d = ScreenDiff.between(lines(0, 100), lines(10, 110))!;
      expect(d.apply(lines(0, 20)), isNull);
    });
  });

  group('slash commands', () {
    const commands = [
      (name: 'model', description: 'Switch model for this session'),
      (name: 'new', description: 'Start a new session'),
      (name: 'compact', description: 'Manually compact the session context'),
      (name: 'plan-review', description: ''),
      (name: 'plan', description: 'Toggle plan mode'),
      (name: 'skill:Pdf', description: 'Read PDFs'),
    ];
    List<String> names(String text, {int max = 6}) => [for (final c in matchCommands(commands, text, max: max)) c.name];

    test('a summary keeps its commands through JSON, a description-less one too', () {
      const s = LiveSummary(key: 'k', id: 's', title: '', cwd: '/x', epoch: 'e', seq: 1, commands: commands);
      final back = LiveSummary.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
      expect(back.commands, commands);
      expect(LiveSummary.fromJson(const {'key': 'k'}).commands, isEmpty);
    });

    test('names that start with what was typed come first, then ones that contain it, in omp order', () {
      expect(names('/p'), ['plan-review', 'plan', 'compact', 'skill:Pdf']);
      expect(names('/PL'), ['plan-review', 'plan']);
      expect(names('/n'), ['new', 'plan-review', 'plan']);
      expect(names('/', max: 3), ['model', 'new', 'compact']);
    });

    test('nothing once a space follows the name, or without the slash', () {
      expect(names('/new '), isEmpty);
      expect(names('/compact keep the API'), isEmpty);
      expect(names('new'), isEmpty);
      expect(names('/zzz'), isEmpty);
    });
  });

  test('chunkJson keeps every chunk under the limit and loses nothing', () {
    final items = [
      for (var i = 0; i < 50; i++) {'id': '$i', 't': 'x' * 900},
    ];
    final chunks = chunkJson(items, maxBytes: 5000);
    expect(chunks.length, greaterThan(1));
    for (final c in chunks) {
      expect(utf8.encode(jsonEncode(c)).length, lessThan(5000 + 100));
    }
    expect(chunks.expand((c) => c).length, 50);
  });

  // The screens and keys below were read off and tried on Claude Code 2.1.296 in kitty.
  group('Claude Code dialogs', () {
    const color = LiveQuestion(
      id: '',
      question: 'Which color should the button be?',
      options: ['Red', 'Blue', 'Green'],
    );
    const sizes = LiveQuestion(
      id: '',
      question: 'Which sizes do you want?',
      options: ['Small', 'Medium', 'Large'],
      multi: true,
    );
    List<Object> flat(List<KeyStep> steps) => [
      for (final s in steps)
        switch (s) {
          Keys(:final keys) => keys.join(' '),
          Typed(:final text) => 'type:$text',
          Settle() => 'settle',
        },
    ];

    test('a single question answers by its row number, or opens "Type something" for typed text', () {
      const ask = LiveAsk.questions('t1', [color]);
      expect(
        flat(
          answerKeys(
            ask,
            answers: const [
              LiveAnswer(picks: [1]),
            ],
            agent: Agent.claude,
          ),
        ),
        ['2'],
      );
      expect(
        flat(
          answerKeys(
            ask,
            answers: const [LiveAnswer(custom: 'Purple')],
            agent: Agent.claude,
          ),
        ),
        ['4', 'settle', 'type:Purple', 'settle', 'enter'],
      );
    });

    test('multiple choice toggles by number, walks to Submit, and the review tab submits', () {
      const ask = LiveAsk.questions('t2', [color, sizes]);
      expect(
        flat(
          answerKeys(
            ask,
            answers: const [
              LiveAnswer(picks: [2]),
              LiveAnswer(picks: [0, 2]),
            ],
            agent: Agent.claude,
          ),
        ),
        ['3', 'settle', '1 3 down down down down enter', 'settle', '1'],
      );
      expect(
        flat(
          answerKeys(
            const LiveAsk.questions('t3', [sizes]),
            answers: const [
              LiveAnswer(picks: [1], custom: 'Huge'),
            ],
            agent: Agent.claude,
          ),
        ),
        ['2 4 down down down', 'settle', 'type:Huge', 'settle', 'down enter', 'settle', '1'],
      );
    });

    test('an approval is Yes by number, Esc to refuse, and shows as "Do you want …?" over "❯ 1. Yes"', () {
      const ask = LiveAsk.approval('t4', tool: 'Bash', summary: 'touch made-by-fake.txt');
      expect(flat(answerKeys(ask, approve: true, agent: Agent.claude)), ['1']);
      expect(flat(answerKeys(ask, agent: Agent.claude)), ['esc']);
      const screen = '''
 Bash command
 Create a marker file
 touch made-by-fake.txt
 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and always allow access to /private/tmp/work from this project
   3. No
 Esc to cancel · Tab to amend''';
      expect(askOnScreen(ask, screen, agent: Agent.claude), isTrue);
      expect(askOnScreen(ask, '❯ say hello\n⏺ Hello.', agent: Agent.claude), isFalse);
    });

    test('the plan review is read under "Would you like to proceed?", past the plan\'s own numbered list', () {
      const screen = '''
 Ready to code?
 Here is Claude's plan:
 Paint the button
 1. Pick a color
 2. Paint it
 Claude has written up a plan and is ready to execute. Would you like to proceed?
 ❯ 1. Yes, auto-accept edits
   2. Yes, manually approve edits
   3. Tell Claude what to change
      shift+tab to approve with this feedback
 ctrl+g to edit in True · /tmp/plans/paint.md''';
      final review = parsePlanReview(screen, agent: Agent.claude)!;
      expect(review.options, ['Yes, auto-accept edits', 'Yes, manually approve edits', 'Tell Claude what to change']);
      expect(review.current, 0);
      expect(askOnScreen(const LiveAsk.plan('t5'), screen, agent: Agent.claude), isTrue);
      final exit = parsePlanReview(
        ' Exit plan mode?\n Claude wants to exit plan mode\n   1. Yes\n ❯ 2. No',
        agent: Agent.claude,
      )!;
      expect(exit.options, ['Yes', 'No']);
      expect(exit.current, 1);
      expect(parsePlanReview(screen), isNull);
    });
  });
}

/// omp's plan review as kitty's plain text shows it [width] columns wide:
/// the plan in a rounded box, then the "next step" prompt, the model slider,
/// the options (cursor on [cursor]) and the help line. Rows too wide for the
/// terminal wrap onto the next line, as they do in kitty.
String _planScreen({
  int width = 60,
  int cursor = 2,
  bool slider = true,
  bool long = true,
  String help = '↑/↓ select · ⏎ confirm · ←/→ model · c copy · ⇥ regions · esc cancel',
}) {
  final options = [
    'Approve and execute',
    'Approve and compact context',
    if (long)
      'Approve and keep context (~47k / 1m) — then save every draft note as it changes'
    else
      'Approve and keep context (~47k / 1m)',
    'Refine plan',
    'Save and quit',
  ];
  final inner = width - 4;
  final out = <String>['╭─ Plan Review ${'─' * (width - 17)}╮'];
  void row(String content) {
    final line = '│ ${content.padRight(inner)} │';
    for (var i = 0; i < line.length; i += width) {
      out.add(line.substring(i, i + width > line.length ? line.length : i + width));
    }
  }

  ['# Notes plan', '', '1. Read the notes store', '2. Save drafts on close', ''].forEach(row);
  out.add('├${'─' * (width - 2)}┤');
  row('Plan mode - next step');
  if (slider) {
    row('continue with  ◂  smol │ default │ slow  ▸');
    row('  ↳ Claude Sonnet 4.5');
  }
  for (final (i, o) in options.indexed) {
    row('${i == cursor ? '❯' : ' '} $o');
  }
  out.add('├${'─' * (width - 2)}┤');
  row(help);
  out.add('╰${'─' * (width - 2)}╯');
  return out.join('\n');
}
