import 'dart:convert';
import 'dart:math';

import 'package:dzep_core/agent.dart';

// Terminal from the phone, version 2. Two kinds of things travel:
//
// - Coding sessions (omp, Claude Code: lib/agent.dart), live and structured.
//   Each agent's extension (apps/dzep-macos-app/integrations/omp/live.ts, the
//   Claude Code plugin in apps/dzep-macos-app/integrations/claude/) reports its session to the Mac app's local API
//   (apps/dzep-macos-app/lib/local_api.dart → apps/dzep-macos-app/lib/live_hub.dart)
//   as transcript items. The phone
//   lays them out itself, so the Mac window's width doesn't matter.
// - terminal windows, as screens (lib/terminals.dart: kitty, tmux, WezTerm,
//   iTerm2, Terminal, Ghostty): shells and anything else,
//   and the agents' own menus when the phone needs them.
//
// Mac ↔ phone: the private Realtime broadcast topic `terminal:<user id>`
// (RLS: the user's own topic only). Nothing is stored on the server.
//
//   phone → Mac   hello  {from, session?, window?}   every 4 s while the app is in front;
//                        session: the live session it shows, window: the screen it shows
//   Mac → phone   state  {windows, sessions, projects, home, agent, error?}   on every hello and on changes;
//                        sessions: LiveSummary.toJson, its slash commands as `cmds` [[name, description?]];
//                        agent: what a new session starts (Agent.name, the Mac's setting)
//   phone → Mac   sync   {from, session, epoch?, since}   catch up after a gap or on opening
//   Mac → phone   items  {to, session, epoch, seq, reset, items, last}   answer to sync, in chunks
//   Mac → phone   live   {session, epoch, ops}   changes to watched sessions, batched
//   Mac → phone   screen {window, v, lines? | diff?, colors?}   a watched window's text (ANSI lines),
//                        whole (lines) or as a ScreenDiff on version v - 1
//   phone → Mac   run    {id, op, …}   see TerminalBridge._onRun
//   Mac → phone   ran    {id, error?, window?}
//
// Extension ↔ Mac, as JSON frames with the local API's bearer token, over
// either transport (one connection per session, frames in order):
//
// - a WebSocket on ws://127.0.0.1:<port>/v1/live (omp), text frames;
// - HTTP long polls on POST /v1/live/http (Claude Code mods have no
//   WebSocket): {conn?, frames, wait?} → {conn, frames}. A request without
//   conn opens a connection (its frames start with hello); its frames go in
//   in order, the answer carries the Mac's frames, waiting up to 25 s for
//   some when `wait`. An unknown conn answers 404: the extension says hello
//   again. A connection nobody asks on for 60 s is gone.
//
//   ext → Mac  hello  {v, agent?, session: {id, title, cwd, model}, window?, pid, busy, ctx?, items, older,
//                     commands}   agent: Agent.name (omp when left out); the session's newest items, oldest
//                     first; again after /new, /resume, /clear.
//                     commands: [{name, description?}] the agent's own slash commands, then the session's
//   ext → Mac  meta   {title?, model?, ctx?, commands?}
//   ext → Mac  item   {item}   a new or changed item (whole)
//   ext → Mac  append {id, text}   streamed text added to an assistant item
//   ext → Mac  busy   {busy, summary?}   summary: the last answer, when a run has really ended
//   ext → Mac  ask    {ask?}   the agent waits for an answer (null: not anymore): LiveAsk.toJson; a plan
//                     review comes without options, which the Mac reads off the agent's screen
//   ext → Mac  reply  {req, error?, items?, older?}
//   Mac → ext  prompt {req, text, images: [{data, mimeType}], files?: [path], deliver?: steer | followUp}
//                     files: the images saved on this Mac instead, for an agent that reads them from disk
//                     (Claude Code); an agent that can't steer queues every prompt for the run's end
//   Mac → ext  abort  {req}
//   Mac → ext  older  {req, limit}   items before the oldest one sent

/// The private Storage bucket images from the phone pass through.
const imageBucket = 'terminal';

enum ItemKind { user, assistant, tool, notice }

enum ToolStatus { running, ok, error }

/// One entry of a session's transcript, as the phone draws it.
class LiveItem {
  LiveItem({
    required this.id,
    required this.kind,
    this.text = '',
    this.images = 0,
    this.tool = '',
    this.title = '',
    this.args = '',
    this.output = '',
    this.status = ToolStatus.running,
    this.order = 0,
    this.seq = 0,
  });

  factory LiveItem.fromJson(Map<String, dynamic> j) => LiveItem(
    id: j['id'] as String,
    kind: ItemKind.values.asNameMap()[j['k']] ?? ItemKind.notice,
    text: j['t'] as String? ?? '',
    images: j['im'] as int? ?? 0,
    tool: j['tl'] as String? ?? '',
    title: j['ti'] as String? ?? '',
    args: j['a'] as String? ?? '',
    output: j['out'] as String? ?? '',
    status: ToolStatus.values.asNameMap()[j['st']] ?? ToolStatus.ok,
    order: j['o'] as int? ?? 0,
    seq: j['s'] as int? ?? 0,
  );

  final String id;
  final ItemKind kind;

  /// user, assistant (Markdown), notice: the text.
  String text;

  /// user: how many images came with it.
  int images;

  /// tool: its name (`bash`, `edit`), what it says it's doing, its
  /// arguments in brief, the end of its output, how it went.
  String tool;
  String title;
  String args;
  String output;
  ToolStatus status;

  /// Its place in the transcript, and the hub's seq of its last change.
  int order;
  int seq;

  Map<String, dynamic> toJson() => {
    'id': id,
    'k': kind.name,
    if (text.isNotEmpty) 't': text,
    if (images > 0) 'im': images,
    if (kind == ItemKind.tool) ...{
      'tl': tool,
      if (title.isNotEmpty) 'ti': title,
      if (args.isNotEmpty) 'a': args,
      if (output.isNotEmpty) 'out': output,
      'st': status.name,
    },
    'o': order,
    's': seq,
  };

  LiveItem copy() => LiveItem.fromJson(toJson());
}

/// A change to a session's transcript: [item] whole, or [append] added to
/// item [id]'s text.
class LiveOp {
  const LiveOp.item(this.seq, LiveItem this.item) : id = null, append = null;
  const LiveOp.append(this.seq, String this.id, String this.append) : item = null;

  factory LiveOp.fromJson(Map<String, dynamic> j) {
    final item = j['item'] as Map?;
    return item != null
        ? LiveOp.item(j['s'] as int, LiveItem.fromJson(item.cast()))
        : LiveOp.append(j['s'] as int, j['id'] as String, j['a'] as String);
  }

  final int seq;
  final LiveItem? item;
  final String? id;
  final String? append;

  Map<String, dynamic> toJson() =>
      item != null ? {'s': seq, 'item': item!.toJson()} : {'s': seq, 'id': id, 'a': append};
}

String newEpoch() => List.generate(8, (_) => Random.secure().nextInt(36).toRadixString(36)).join();

/// The Mac's copy of one session's transcript. Every change gets the next
/// [seq]; a phone that has seen up to some seq catches up with [since].
/// [epoch] changes when the transcript starts over (another session in that
/// omp, the extension reconnected), and a phone then drops what it has.
class LiveLog {
  LiveLog(List<LiveItem> snapshot, {required this.older, this.cap = 3000, String? epoch})
    : epoch = epoch ?? newEpoch() {
    snapshot.forEach(_add);
    _trim();
  }

  final String epoch;

  /// The most items kept; the oldest go first (and [older] turns true).
  final int cap;
  int seq = 0;

  /// The extension has items older than the oldest here.
  bool older;

  final _items = <String, LiveItem>{};
  int _next = 0;
  int _min = 0;

  int get length => _items.length;
  LiveItem? operator [](String id) => _items[id];

  /// Oldest first.
  List<LiveItem> get items => _items.values.toList()..sort((a, b) => a.order.compareTo(b.order));

  LiveItem _add(LiveItem item) {
    final old = _items[item.id];
    final copy = item.copy()
      ..order = old?.order ?? _next++
      ..seq = ++seq;
    return _items[item.id] = copy;
  }

  /// [item], new or changed. The op carries a snapshot: later appends go in
  /// ops of their own.
  LiveOp upsert(LiveItem item) {
    final copy = _add(item);
    _trim();
    return LiveOp.item(copy.seq, copy.copy());
  }

  /// Streamed [text] added to [id]; null if there's no such item.
  LiveOp? append(String id, String text) {
    final item = _items[id];
    if (item == null || text.isEmpty) return null;
    item
      ..text += text
      ..seq = ++seq;
    return LiveOp.append(seq, id, text);
  }

  /// Items from before the oldest one here (oldest first), placed above it.
  /// The ops come in seq order, newest item first.
  List<LiveOp> addOlder(List<LiveItem> items, {required bool more}) {
    older = more;
    final ops = <LiveOp>[];
    for (final item in items.reversed) {
      if (_items.containsKey(item.id)) continue;
      final copy = item.copy()
        ..order = --_min
        ..seq = ++seq;
      _items[copy.id] = copy;
      ops.add(LiveOp.item(seq, copy.copy()));
    }
    return ops;
  }

  /// Items changed after [since], oldest first.
  List<LiveItem> since(int since) => [
    for (final i in items)
      if (i.seq > since) i,
  ];

  void _trim() {
    if (_items.length <= cap) return;
    final drop = items.take(_items.length - cap);
    for (final i in drop) {
      _items.remove(i.id);
    }
    _min = items.first.order;
    older = true;
  }
}

/// The phone's copy of one session's transcript, kept up with [LiveLog]'s
/// ops and catch-ups, and cached on disk between launches.
class LiveView {
  LiveView({required this.epoch, this.seq = 0, this.older = false, Iterable<LiveItem> items = const []}) {
    for (final i in items) {
      _byId[i.id] = i;
    }
  }

  factory LiveView.fromJson(Map<String, dynamic> j) => LiveView(
    epoch: j['epoch'] as String,
    seq: j['seq'] as int,
    older: j['older'] == true,
    items: [for (final i in j['items'] as List) LiveItem.fromJson((i as Map).cast())],
  );

  String epoch;
  int seq;
  bool older;
  final _byId = <String, LiveItem>{};
  List<LiveItem>? _sorted;

  /// Oldest first.
  List<LiveItem> get items => _sorted ??= _byId.values.toList()..sort((a, b) => a.order.compareTo(b.order));

  /// Applies live ops; false if one is missing or the epoch moved on (catch
  /// up with a sync then). Ops already seen are skipped.
  bool apply(String epoch, List<LiveOp> ops) {
    if (epoch != this.epoch) return false;
    for (final op in ops) {
      if (op.seq <= seq) continue;
      if (op.seq != seq + 1) return false;
      final item = op.item;
      if (item != null) {
        final old = _byId[item.id];
        _byId[item.id] = item;
        // The sorted list holds the old object: swap it in place, or sort again.
        final at = old == null || old.order != item.order ? -1 : _sorted?.indexOf(old) ?? -1;
        if (at >= 0) {
          _sorted![at] = item;
        } else {
          _sorted = null;
        }
      } else {
        final target = _byId[op.id];
        if (target == null) return false;
        target.text += op.append!;
      }
      seq = op.seq;
    }
    return true;
  }

  /// A catch-up from the Mac: [items] changed up to [seq] ([reset]: all of
  /// them, in a new [epoch]). [last] is the final chunk of the answer.
  void catchUp({
    required String epoch,
    required int seq,
    required bool reset,
    required List<LiveItem> items,
    required bool last,
    bool? older,
  }) {
    if (reset && this.epoch != epoch) {
      this.epoch = epoch;
      this.seq = 0;
      _byId.clear();
    } else if (epoch != this.epoch) {
      return;
    }
    for (final i in items) {
      _byId[i.id] = i;
    }
    _sorted = null;
    if (older != null) this.older = older;
    if (last && seq > this.seq) this.seq = seq;
  }

  /// The newest [keep] items, for the disk cache. Dropping older ones makes
  /// [older] true: the Mac has them.
  Map<String, dynamic> toJson({int keep = 600}) {
    final all = items;
    final kept = all.length > keep ? all.sublist(all.length - keep) : all;
    return {
      'epoch': epoch,
      'seq': seq,
      'older': older || kept.length < all.length,
      'items': [for (final i in kept) i.toJson()],
    };
  }
}

/// One question the agent asks (omp's `ask` tool, Claude Code's
/// AskUserQuestion).
class LiveQuestion {
  const LiveQuestion({
    required this.id,
    required this.question,
    required this.options,
    this.header = '',
    this.multi = false,
    this.recommended,
  });

  factory LiveQuestion.fromJson(Map<String, dynamic> j) => LiveQuestion(
    id: j['id'] as String? ?? '',
    question: j['question'] as String? ?? '',
    header: j['header'] as String? ?? '',
    options: [for (final o in j['options'] as List? ?? const []) '${o is Map ? o['label'] : o}'],
    multi: j['multi'] == true,
    recommended: j['recommended'] as int?,
  );

  final String id;
  final String question;
  final String header;
  final List<String> options;
  final bool multi;
  final int? recommended;

  Map<String, dynamic> toJson() => {
    'id': id,
    'question': question,
    if (header.isNotEmpty) 'header': header,
    'options': options,
    if (multi) 'multi': true,
    'recommended': ?recommended,
  };
}

enum AskKind { questions, approval, plan, menu }

/// One row of an agent's picker: its `label`, and what it shows under or
/// beside it (`detail`).
typedef MenuItem = ({String label, String detail});

/// The agent is waiting on the person: its questions, approval of [tool]
/// ([summary]: what it would do), its plan review (plan mode's last step) of
/// the plan [title], or a picker a slash command opened (/resume, /model …)
/// titled [title]. A plan's [options], a picker's [items] and the [selected]
/// row of either are read off the agent's screen by the Mac (none when it
/// couldn't read them); a picker with [filter] narrows as you type.
class LiveAsk {
  const LiveAsk.questions(this.id, List<LiveQuestion> this.questions)
    : kind = AskKind.questions,
      tool = '',
      summary = '',
      title = '',
      options = const [],
      items = const [],
      selected = 0,
      filter = false;
  const LiveAsk.approval(this.id, {required this.tool, this.summary = ''})
    : kind = AskKind.approval,
      questions = null,
      title = '',
      options = const [],
      items = const [],
      selected = 0,
      filter = false;
  const LiveAsk.plan(this.id, {this.title = 'Plan', this.options = const [], this.selected = 0})
    : kind = AskKind.plan,
      questions = null,
      tool = '',
      summary = '',
      items = const [],
      filter = false;
  const LiveAsk.menu(this.id, {required this.title, required this.items, this.selected = 0, this.filter = false})
    : kind = AskKind.menu,
      questions = null,
      tool = '',
      summary = '',
      options = const [];

  factory LiveAsk.fromJson(Map<String, dynamic> j) => switch (j['kind']) {
    'approval' => LiveAsk.approval(
      j['id'] as String,
      tool: j['tool'] as String? ?? '',
      summary: j['summary'] as String? ?? '',
    ),
    'plan' => LiveAsk.plan(
      j['id'] as String,
      title: j['title'] as String? ?? 'Plan',
      options: [for (final o in j['options'] as List? ?? const []) '$o'],
      selected: j['selected'] as int? ?? 0,
    ),
    'menu' => LiveAsk.menu(
      j['id'] as String,
      title: j['title'] as String? ?? '',
      items: [
        for (final i in j['items'] as List? ?? const [])
          (label: '${(i as Map)['label'] ?? ''}', detail: i['detail'] as String? ?? ''),
      ],
      selected: j['selected'] as int? ?? 0,
      filter: j['filter'] == true,
    ),
    _ => LiveAsk.questions(j['id'] as String, [
      for (final q in j['questions'] as List? ?? const []) LiveQuestion.fromJson((q as Map).cast()),
    ]),
  };

  /// The tool call it belongs to.
  final String id;
  final AskKind kind;
  final List<LiveQuestion>? questions;
  final String tool;
  final String summary;
  final String title;
  final List<String> options;
  final List<MenuItem> items;
  final int selected;
  final bool filter;

  bool get isApproval => kind == AskKind.approval;
  bool get isPlan => kind == AskKind.plan;
  bool get isMenu => kind == AskKind.menu;

  /// What a notification says.
  String get text => switch (kind) {
    AskKind.approval => 'Approve $tool${summary.isEmpty ? '' : ': $summary'}?',
    AskKind.plan => 'Plan ready: $title',
    AskKind.menu => title,
    AskKind.questions => questions!.map((q) => q.question).join('\n'),
  };

  Map<String, dynamic> toJson() => switch (kind) {
    AskKind.approval => {'kind': 'approval', 'id': id, 'tool': tool, if (summary.isNotEmpty) 'summary': summary},
    AskKind.plan => {
      'kind': 'plan',
      'id': id,
      'title': title,
      if (options.isNotEmpty) 'options': options,
      if (options.isNotEmpty) 'selected': selected,
    },
    AskKind.menu => {
      'kind': 'menu',
      'id': id,
      'title': title,
      'items': [
        for (final i in items) {'label': i.label, if (i.detail.isNotEmpty) 'detail': i.detail},
      ],
      'selected': selected,
      if (filter) 'filter': true,
    },
    AskKind.questions => {
      'kind': 'ask',
      'id': id,
      'questions': [for (final q in questions!) q.toJson()],
    },
  };
}

/// The person's answer to one [LiveQuestion]: the options picked (indexes)
/// and/or their own text.
class LiveAnswer {
  const LiveAnswer({this.picks = const [], this.custom});

  factory LiveAnswer.fromJson(Map<String, dynamic> j) =>
      LiveAnswer(picks: (j['picks'] as List? ?? const []).cast<int>(), custom: j['custom'] as String?);

  final List<int> picks;
  final String? custom;

  Map<String, dynamic> toJson() => {'picks': picks, 'custom': ?custom};
}

/// One step of answering an agent's dialog with the keyboard: keys (kitty's
/// names) pressed, or text typed.
sealed class KeyStep {
  const KeyStep();
}

class Keys extends KeyStep {
  const Keys(this.keys);
  final List<String> keys;
}

class Typed extends KeyStep {
  const Typed(this.text);
  final String text;
}

/// Wait for the agent to redraw before the next keys: opening or closing a
/// typed answer and moving to the Submit tab take a moment, and keys sent
/// before that are dropped.
class Settle extends KeyStep {
  const Settle();
}

/// The keystrokes that answer [ask] in [agent]'s terminal UI (a question or
/// an approval). A plan review or a picker is answered from where its cursor
/// is now: [menuKeys], or [claudeRowKey] for Claude Code's plan review.
List<KeyStep> answerKeys(
  LiveAsk ask, {
  List<LiveAnswer> answers = const [],
  bool approve = false,
  Agent agent = Agent.omp,
}) {
  if (ask.isPlan || ask.isMenu) throw ArgumentError('A plan review or a picker is answered with menuKeys.');
  final questions = ask.questions;
  if (questions != null) {
    if (answers.length != questions.length) throw ArgumentError('One answer per question.');
    for (final (i, q) in questions.indexed) {
      final a = answers[i];
      for (final p in a.picks) {
        if (p < 0 || p >= q.options.length) throw ArgumentError('No option $p in "${q.question}".');
      }
      if (!q.multi && (a.picks.length + (_custom(a) == null ? 0 : 1)) != 1) {
        throw ArgumentError('Pick one answer for "${q.question}".');
      }
    }
  }
  return switch (agent) {
    Agent.omp => _ompKeys(ask, answers, approve: approve),
    Agent.claude => _claudeKeys(ask, answers, approve: approve),
  };
}

String? _custom(LiveAnswer a) {
  final custom = a.custom?.trim();
  return custom == null || custom.isEmpty ? null : custom;
}

/// Steps that run consecutive key presses together, as one keys request.
class _Steps {
  final steps = <KeyStep>[];

  void press(List<String> keys) {
    if (steps.lastOrNull case Keys(keys: final last)) {
      last.addAll(keys);
    } else {
      steps.add(Keys([...keys]));
    }
  }

  void add(KeyStep step) => steps.add(step);

  void settle() {
    if (steps.lastOrNull is! Settle) steps.add(const Settle());
  }
}

/// omp: the ask dialog lists each question's options and then "Other"; its
/// cursor stops at the ends, so going up past the top and then down picks a
/// row wherever the cursor started. Enter on a single-choice row answers and
/// moves on, Space toggles a multiple-choice row and Enter moves on; after
/// several questions a Submit tab takes a last Enter. A typed answer goes
/// through an editor; its Enter closes it, and the next keys wait for that
/// ([Settle]). An approval is omp's Approve/Deny menu, which opens on Approve.
List<KeyStep> _ompKeys(LiveAsk ask, List<LiveAnswer> answers, {required bool approve}) {
  if (ask.isApproval) {
    return [
      Keys(approve ? const ['enter'] : const ['down', 'enter']),
    ];
  }
  final questions = ask.questions!;
  final s = _Steps();
  var onSubmitTab = false;
  for (final (i, q) in questions.indexed) {
    final a = answers[i];
    final rows = q.options.length + 1;
    List<String> rowKeys(int row) => [for (var k = 0; k < rows; k++) 'up', for (var k = 0; k < row; k++) 'down'];
    final custom = _custom(a);
    if (q.multi) {
      for (final p in a.picks) {
        s.press([...rowKeys(p), 'space']);
      }
    }
    if (custom != null) {
      s
        ..press([...rowKeys(q.options.length), 'enter'])
        ..add(const Settle())
        ..add(Typed(custom))
        ..press(['enter'])
        ..add(const Settle());
      // A lone multiple-choice question goes to its Submit tab after a typed answer.
      if (q.multi && questions.length == 1) onSubmitTab = true;
    } else if (q.multi) {
      s.press(['enter']);
    } else {
      s.press([...rowKeys(a.picks.single), 'enter']);
    }
  }
  if (questions.length > 1 || onSubmitTab) {
    s
      ..settle()
      ..press(['enter']);
  }
  return s.steps;
}

/// Claude Code numbers the rows of its dialogs from 1: a row's digit picks
/// it (or toggles it, in a multiple-choice question) wherever the cursor is.
String claudeRowKey(int row) => '${row + 1}';

/// Claude Code: a question lists its options, then "Type something", then
/// (multiple choice) a Submit row. A single-choice row's digit answers and
/// moves on; the typed row's digit opens it for typing, and Enter answers.
/// Multiple choice: digits toggle rows without moving the cursor from the
/// first, ↓ takes it to the typed row (whose text ticks it) and on to
/// Submit, where Enter moves on. Several questions, or a multiple-choice
/// one, end on a review tab whose first row submits. An approval opens on
/// Yes; Esc refuses.
List<KeyStep> _claudeKeys(LiveAsk ask, List<LiveAnswer> answers, {required bool approve}) {
  if (ask.isApproval) {
    return [
      Keys([if (approve) claudeRowKey(0) else 'esc']),
    ];
  }
  final questions = ask.questions!;
  final s = _Steps();
  for (final (i, q) in questions.indexed) {
    final a = answers[i];
    final n = q.options.length;
    final custom = _custom(a);
    if (i > 0) s.settle();
    if (!q.multi) {
      if (custom == null) {
        s.press([claudeRowKey(a.picks.single)]);
        continue;
      }
      s
        ..press([claudeRowKey(n)])
        ..add(const Settle())
        ..add(Typed(custom))
        ..add(const Settle())
        ..press(['enter']);
      continue;
    }
    for (final p in a.picks) {
      s.press([claudeRowKey(p)]);
    }
    if (custom == null) {
      s.press([for (var k = 0; k <= n; k++) 'down', 'enter']);
      continue;
    }
    s
      ..press([claudeRowKey(n), for (var k = 0; k < n; k++) 'down'])
      ..add(const Settle())
      ..add(Typed(custom))
      ..add(const Settle())
      ..press(['down', 'enter']);
  }
  if (questions.length > 1 || questions.single.multi) {
    s
      ..settle()
      ..press([claudeRowKey(0)]);
  }
  return s.steps;
}

/// How to tell [ask] is [agent]'s dialog on the screen: some of its words in
/// the screen's text, compared without spacing or Markdown marks (the
/// terminal wraps and styles them).
bool askOnScreen(LiveAsk ask, String screen, {Agent agent = Agent.omp}) {
  String flat(String s) => s.replaceAll(RegExp(r'[\s*_`#>]+'), '').toLowerCase();
  final text = flat(screen);
  if (ask.isPlan) {
    return (agent == Agent.omp && text.contains('planmode-nextstep')) || parsePlanReview(screen, agent: agent) != null;
  }
  if (ask.isMenu) return parseMenu(screen)?.title == ask.title;
  if (ask.isApproval) {
    return switch (agent) {
      Agent.omp => text.contains('approve') && text.contains('deny'),
      // "Do you want to proceed?" (or "… to create notes.txt?") over "❯ 1. Yes".
      Agent.claude => text.contains('doyouwant') && text.contains('❯1.yes'),
    };
  }
  final q = flat(ask.questions!.first.question);
  return text.contains(q.length > 24 ? q.substring(0, 24) : q);
}

/// [agent]'s plan review (the last step of plan mode), read off the plain
/// text of its screen: its options and the one its cursor (❯) is on. Null
/// unless a review is up with its options focused.
({List<String> options, int current})? parsePlanReview(String screen, {Agent agent = Agent.omp}) => switch (agent) {
  Agent.omp => _ompPlanReview(screen),
  Agent.claude => _claudePlanReview(screen),
};

final _claudePlanHeader = RegExp(r'Would you like to proceed\?|Exit plan mode\?');
final _claudeRow = RegExp(r'^\s*(❯\s*)?(\d+)\.\s+(\S.*?)\s*$');

/// Claude Code's plan review: the numbered rows under its last "Would you
/// like to proceed?" ("Exit plan mode?" when no plan was written). Lines
/// between them (a row's hint) are skipped; a number out of turn ends them.
({List<String> options, int current})? _claudePlanReview(String screen) {
  final lines = screen.split('\n');
  final header = lines.lastIndexWhere(_claudePlanHeader.hasMatch);
  if (header < 0) return null;
  final options = <String>[];
  var current = -1;
  for (final l in lines.skip(header + 1)) {
    final m = _claudeRow.firstMatch(l);
    if (m == null) continue;
    if (int.parse(m[2]!) != options.length + 1) break;
    if (m[1] != null) current = options.length;
    options.add(m[3]!);
  }
  if (current < 0) return null;
  return (options: options, current: current);
}

final _planHeader = RegExp(r'plan mode\s*[-–—]\s*next step', caseSensitive: false);
final _planHelp = RegExp(r'\bselect\b', caseSensitive: false);
final _leftEdge = RegExp(r'^\s*[│┃║|]');
final _rightEdge = RegExp(r'\s*[│┃║|]\s*$');
final _cursor = RegExp(r'^(\s*)[❯›>]\s+(?=\S)');
final _rule = RegExp(r'^[─━═┄┈╌\-+├┤┼┬┴╭╮╰╯]+$');

/// omp's plan review, read off the plain text of its screen: the options
/// listed between its "Plan mode - next step" header and the help line
/// under them ("↑/↓ select · ⏎ confirm · …"), and the one its cursor (❯) is
/// on. The model slider above them ("continue with ◂ smol default slow ▸"
/// and its "↳ model" line) is skipped, and a row the terminal wrapped is
/// joined again. Null unless a review is up with its options focused, the
/// only time ↑/↓ move between them.
({List<String> options, int current})? _ompPlanReview(String screen) {
  final lines = screen.split('\n');
  final header = lines.lastIndexWhere(_planHeader.hasMatch);
  if (header < 0) return null;
  final help = lines.indexWhere(_planHelp.hasMatch, header + 1);
  if (help < 0) return null;
  // Inside the review's box every row starts with its edge; a row too wide
  // for the terminal goes on, without one, on the next line.
  final boxed = _leftEdge.hasMatch(lines[header]);
  final rows = [
    for (final l in lines.sublist(header + 1, help))
      (edge: _leftEdge.hasMatch(l), text: l.replaceFirst(_leftEdge, '').replaceFirst(_rightEdge, '')),
  ];
  final at = rows.indexWhere((r) => _cursor.hasMatch(r.text));
  if (at < 0) return null;
  // Where the labels start: past the cursor on its row, past the indent on the others.
  final column = _cursor.firstMatch(rows[at].text)!.end;
  int indent(String s) => s.length - s.trimLeft().length;

  final options = <String>[];
  var current = -1;
  var afterOption = false;
  for (final (i, r) in rows.indexed) {
    final t = r.text.trim();
    if (t.isEmpty || _rule.hasMatch(t)) {
      afterOption = false;
      continue;
    }
    if (boxed ? !r.edge : i != at && indent(r.text) != column) {
      if (afterOption) options.last += boxed ? r.text : ' ${r.text}';
      continue;
    }
    afterOption = false;
    if (t.startsWith('↳') || t.contains('continue with') || t.contains('◂') || t.contains('▸')) continue;
    if (i == at) {
      current = options.length;
      options.add(r.text.substring(column));
    } else if (indent(r.text) == column) {
      options.add(r.text.substring(column));
    } else {
      continue;
    }
    afterOption = true;
  }
  if (current < 0) return null;
  return (options: [for (final o in options) o.replaceAll(RegExp(r'\s+'), ' ').trim()], current: current);
}

/// The keys that move a menu's cursor (a picker's, the plan review's) from
/// row [current] to [target], then (with [enter]) pick it. Never above row
/// 0: the plan review's ↑ there leaves its options for the plan's text.
List<String> menuKeys(int current, int target, {bool enter = true}) {
  if (current < 0 || target < 0) throw ArgumentError('No row $target.');
  return [
    for (var k = current; k < target; k++) 'down',
    for (var k = target; k < current; k++) 'up',
    if (enter) 'enter',
  ];
}

final _menuCursor = RegExp(r'^\s*❯ ');

/// Claude Code's prompt line: ❯ and a no-break space. It shows only while no
/// picker is up; the `❯ ` rows above it are prompts in its transcript.
final _claudePrompt = RegExp('^\\s*❯\u00a0');
final _menuLeft = RegExp(r'^\s*[│┃║]');
final _menuRight = RegExp(r'(\s*[│┃║█])+\s*$');
final _menuChrome = RegExp(r'^[\s─━═╭╮┌┐╔╗├┤╰╯└┘]+|[\s─━═╭╮┌┐╔╗├┤╰╯└┘]+$');
final _menuStatus = RegExp(
  r'^(\(\d+/\d+[^)]*\)\s*)?(type to search|search:|no match|no items|no sessions)',
  caseSensitive: false,
);
final _menuGap = RegExp(r'\s{2,}');

/// A numbered row's number (Claude Code's pickers: `1.  Default`), whose gap
/// is part of the label, not the one before its detail.
final _menuNumber = RegExp(r'^(\d+\.)\s+');

/// A picker the agent's terminal UI shows (/resume, /model, /tree, a hook's
/// selector …), read off the plain text of its screen: the rows around the
/// last cursor (❯) at the cursor's label column, a `title` above them (its
/// box's top border, or a line of its own) and whether typing filters them
/// (a `>` search line above, or "Type to search" under them). Rows apart by
/// blank lines are one item each (first line its label, the rest its
/// detail); otherwise every line is one, with what's indented deeper or
/// set apart by a wide gap as its detail. Box edges, scrollbars, padding
/// and lone "…" lines are left out; a footer of keys ends the rows. Null
/// for anything else: the plan review, or Claude Code's prompt under a
/// transcript whose prompts read `❯ …` too.
({String title, List<MenuItem> items, int current, bool filter})? parseMenu(String screen) {
  if (_planHeader.hasMatch(screen)) return null;
  final lines = [for (final l in screen.split('\n')) l.replaceFirst(_menuLeft, '').replaceFirst(_menuRight, '')];
  final at = lines.lastIndexWhere(_menuCursor.hasMatch);
  if (at < 0 || lines.skip(at + 1).any(_claudePrompt.hasMatch)) return null;
  final column = _menuCursor.firstMatch(lines[at])!.end;
  int indent(String s) => s.length - s.trimLeft().length;
  var filter = false;
  bool inList(int i) {
    final t = lines[i].trim();
    if (t.isEmpty || i == at) return true;
    if (_menuStatus.hasMatch(t)) {
      filter |= t.toLowerCase().contains('search');
      return false;
    }
    return indent(lines[i]) >= column;
  }

  var top = at;
  while (top > 0 && inList(top - 1)) {
    top--;
  }
  var bottom = at;
  while (bottom + 1 < lines.length && inList(bottom + 1)) {
    bottom++;
  }
  final rows = [
    for (var i = top; i <= bottom; i++)
      if (lines[i].trim() != '…') (i: i, text: lines[i]),
  ];
  bool isItem(({int i, String text}) r) => r.i == at || (r.text.trim().isNotEmpty && indent(r.text) == column);
  final first = rows.indexWhere(isItem);
  final last = rows.lastIndexWhere(isItem);
  final blocks = rows.sublist(first, last + 1).any((r) => r.text.trim().isEmpty);

  final items = <List<String>>[];
  var current = -1;
  var gap = true;
  for (final r in rows) {
    final t = r.text.trim();
    if (t.isEmpty) {
      gap = true;
      continue;
    }
    if (isItem(r) && (!blocks || gap || items.isEmpty)) {
      final row = r.text.substring(column).trim().replaceFirstMapped(_menuNumber, (m) => '${m[1]} ');
      final split = _menuGap.firstMatch(row);
      items.add(split == null ? [row] : [row.substring(0, split.start), row.substring(split.end)]);
    } else if (items.isNotEmpty) {
      items.last.add(t);
    } else {
      continue;
    }
    if (r.i == at) current = items.length - 1;
    gap = false;
  }
  if (current < 0) return null;
  // Panes side by side (/model's providers | models): a list of the left pane
  // alone would mislead, so leave it to the screen.
  if (rows.any((r) => r.text.substring(min(column, r.text.length)).contains(_paneSplit))) return null;

  // The title: the first line above the rows that isn't blank or the search line.
  var title = '';
  for (var i = top - 1; i >= 0; i--) {
    final t = lines[i].trim();
    if (t.isEmpty) continue;
    if (t.startsWith('>')) {
      filter = true;
      continue;
    }
    title = t.replaceAll(_menuChrome, '');
    break;
  }
  String flat(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return (
    title: flat(title),
    items: [for (final it in items) (label: flat(it.first), detail: it.skip(1).map(flat).join(' · '))],
    current: current,
    filter: filter,
  );
}

/// A vertical rule inside a row: another pane beside the list.
final _paneSplit = RegExp('[│┃║]');

/// One of omp's slash commands, without its `/`.
typedef LiveCommand = ({String name, String description});

/// The extension's `commands` ([{name, description?}]).
List<LiveCommand> liveCommands(Object? json) => [
  if (json is List)
    for (final c in json)
      if (c is Map && c['name'] is String)
        (name: c['name'] as String, description: c['description'] is String ? c['description'] as String : ''),
];

/// The [commands] the composer offers for [text] (`/` and the start of a
/// name), at most [max]: names that start with what was typed, then names
/// that contain it, each in omp's order. None once there's a space.
List<LiveCommand> matchCommands(List<LiveCommand> commands, String text, {int max = 6}) {
  if (!text.startsWith('/') || text.contains(RegExp(r'\s'))) return const [];
  final q = text.substring(1).toLowerCase();
  final names = [for (final c in commands) c.name.toLowerCase()];
  return [
    for (final (i, c) in commands.indexed)
      if (names[i].startsWith(q)) c,
    for (final (i, c) in commands.indexed)
      if (!names[i].startsWith(q) && names[i].contains(q)) c,
  ].take(max).toList();
}

/// A live session in the phone's list.
class LiveSummary {
  const LiveSummary({
    required this.key,
    required this.id,
    required this.title,
    required this.cwd,
    required this.epoch,
    required this.seq,
    this.agent = Agent.omp,
    this.window,
    this.model = '',
    this.busy = false,
    this.ask,
    this.ctx,
    this.preview = '',
    this.at,
    this.older = false,
    this.commands = const [],
  });

  factory LiveSummary.fromJson(Map<String, dynamic> j) => LiveSummary(
    key: j['key'] as String,
    id: j['id'] as String? ?? '',
    agent: Agent.parse(j['agent']),
    window: j['window'] as String?,
    title: j['title'] as String? ?? '',
    cwd: j['cwd'] as String? ?? '',
    model: j['model'] as String? ?? '',
    busy: j['busy'] == true,
    ask: j['ask'] is Map ? LiveAsk.fromJson((j['ask'] as Map).cast()) : null,
    ctx: (j['ctx'] as num?)?.toInt(),
    preview: j['preview'] as String? ?? '',
    at: j['at'] is int ? DateTime.fromMillisecondsSinceEpoch(j['at'] as int) : null,
    epoch: j['epoch'] as String? ?? '',
    seq: j['seq'] as int? ?? 0,
    older: j['older'] == true,
    commands: [
      for (final c in j['cmds'] as List? ?? const [])
        if (c is List && c.isNotEmpty && c[0] is String)
          (name: c[0] as String, description: c.length > 1 && c[1] is String ? c[1] as String : ''),
    ],
  );

  /// Stable for the agent's process: its terminal window's key (`kitty-<pid>/<id>`,
  /// `tmux:default/3` …), or `pid:<pid>` when its window can't be told. What the
  /// phone opens and notifications point at.
  final String key;

  /// The agent's session id (changes on /new, /resume, /clear).
  final String id;

  /// Which coding agent this is.
  final Agent agent;
  final String? window;
  final String title;
  final String cwd;
  final String model;
  final bool busy;
  final LiveAsk? ask;

  /// How full the context window is, in percent.
  final int? ctx;

  /// The last answer's first line.
  final String preview;

  /// The last change.
  final DateTime? at;
  final String epoch;
  final int seq;
  final bool older;

  /// The agent's slash commands, for the composer.
  final List<LiveCommand> commands;

  Map<String, dynamic> toJson() => {
    'key': key,
    'id': id,
    'agent': agent.name,
    'window': ?window,
    'title': title,
    'cwd': cwd,
    if (model.isNotEmpty) 'model': model,
    if (busy) 'busy': true,
    'ask': ?ask?.toJson(),
    'ctx': ?ctx,
    if (preview.isNotEmpty) 'preview': preview,
    'at': ?at?.millisecondsSinceEpoch,
    'epoch': epoch,
    'seq': seq,
    if (older) 'older': true,
    if (commands.isNotEmpty)
      'cmds': [
        for (final c in commands) [c.name, if (c.description.isNotEmpty) c.description],
      ],
  };
}

/// How a screen's lines changed: [drop] from the top, the next [keep]
/// unchanged, then [tail] new. Scrolling and a redrawn bottom cost a few
/// lines instead of the whole screen.
class ScreenDiff {
  const ScreenDiff({required this.drop, required this.keep, required this.tail});

  factory ScreenDiff.fromJson(Map<String, dynamic> j) =>
      ScreenDiff(drop: j['drop'] as int, keep: j['keep'] as int, tail: (j['tail'] as List).cast<String>());

  final int drop;
  final int keep;
  final List<String> tail;

  /// From [a] to [b]; null when sending [b] whole is about as cheap.
  static ScreenDiff? between(List<String> a, List<String> b) {
    if (a.isEmpty || b.isEmpty) return null;
    var bestDrop = 0;
    var bestKeep = 0;
    // Where b's first line sits in a: 0 unless lines scrolled off the top.
    var tries = 0;
    for (var d = 0; d < a.length && tries < 8; d++) {
      if (a[d] != b[0]) continue;
      tries++;
      var k = 0;
      while (k < b.length && d + k < a.length && a[d + k] == b[k]) {
        k++;
      }
      if (k > bestKeep) {
        bestKeep = k;
        bestDrop = d;
      }
    }
    if (bestKeep < b.length ~/ 4) return null;
    return ScreenDiff(drop: bestDrop, keep: bestKeep, tail: b.sublist(bestKeep));
  }

  /// [a] changed into what [between] was given; null if [a] isn't what this
  /// diff was made from (the phone missed a version).
  List<String>? apply(List<String> a) {
    if (drop + keep > a.length) return null;
    return [...a.sublist(drop, drop + keep), ...tail];
  }

  Map<String, dynamic> toJson() => {'drop': drop, 'keep': keep, 'tail': tail};
}

/// [items] split into lists whose JSON stays under [maxBytes] each (Realtime
/// refuses big messages).
List<List<Map<String, dynamic>>> chunkJson(Iterable<Map<String, dynamic>> items, {int maxBytes = 60000}) {
  final out = <List<Map<String, dynamic>>>[];
  var current = <Map<String, dynamic>>[];
  var size = 0;
  for (final i in items) {
    final n = utf8.encode(jsonEncode(i)).length + 1;
    if (current.isNotEmpty && size + n > maxBytes) {
      out.add(current);
      current = [];
      size = 0;
    }
    current.add(i);
    size += n;
  }
  if (current.isNotEmpty || out.isEmpty) out.add(current);
  return out;
}
