import 'dart:convert';
import 'dart:math';

import 'package:supabase_flutter/supabase_flutter.dart';

// Terminal from the iPhone, version 2. Two kinds of things travel:
//
// - omp sessions, live and structured. omp's extension
//   (integrations/omp/live.ts) reports each session to the Mac app over a
//   WebSocket on its local API (lib/local_api.dart → lib/live_hub.dart), as
//   transcript items. The iPhone lays them out itself, so the Mac window's
//   width doesn't matter.
// - kitty windows, as screens (lib/kitty.dart): shells and anything else,
//   and omp's own menus when the phone needs them.
//
// Mac ↔ iPhone: the private Realtime broadcast topic `terminal:<user id>`
// (RLS: the user's own topic only). Nothing is stored on the server.
//
//   iPhone → Mac  hello  {from, session?, window?}   every 4 s while the app is in front;
//                        session: the live session it shows, window: the screen it shows
//   Mac → iPhone  state  {windows, sessions, projects, home, error?}   on every hello and on changes
//   iPhone → Mac  sync   {from, session, epoch?, since}   catch up after a gap or on opening
//   Mac → iPhone  items  {to, session, epoch, seq, reset, items, last}   answer to sync, in chunks
//   Mac → iPhone  live   {session, epoch, ops}   changes to watched sessions, batched
//   Mac → iPhone  screen {window, v, lines? | diff?, colors?}   a watched window's text (ANSI lines),
//                        whole (lines) or as a ScreenDiff on version v - 1
//   iPhone → Mac  run    {id, op, …}   see TerminalBridge._onRun
//   Mac → iPhone  ran    {id, error?, window?}
//
// Extension ↔ Mac (JSON text frames on ws://127.0.0.1:<port>/v1/live, the
// local API's bearer token):
//
//   ext → Mac  hello  {v, session: {id, title, cwd, model}, window?, pid, busy, ctx?, items, older}
//                     the session's newest items, oldest first; again after /new, /resume, /tree
//   ext → Mac  meta   {title?, model?, ctx?}
//   ext → Mac  item   {item}   a new or changed item (whole)
//   ext → Mac  append {id, text}   streamed text added to an assistant item
//   ext → Mac  busy   {busy, summary?}   summary: the last answer, when a run has really ended
//   ext → Mac  ask    {ask?}   omp waits for an answer (null: not anymore)
//   ext → Mac  reply  {req, error?, items?, older?}
//   Mac → ext  prompt {req, text, images: [{data, mimeType}], deliver?: steer | followUp}
//   Mac → ext  abort  {req}
//   Mac → ext  older  {req, limit}   items before the oldest one sent

/// The private Storage bucket images from the phone pass through.
const imageBucket = 'terminal';

/// The extension protocol's version (its hello's `v`).
const liveVersion = 1;

/// Broadcast callbacks get the payload's fields at the top level, next to
/// `event` and `type`.
RealtimeChannel terminalTopic(SupabaseClient client, String userId) =>
    client.channel('terminal:$userId', opts: const RealtimeChannelConfig(private: true));

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

/// One question of omp's `ask` tool.
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

/// omp is waiting on the person: the `ask` tool's [questions], or approval
/// of [tool] ([summary]: what it would do).
class LiveAsk {
  const LiveAsk.questions(this.id, List<LiveQuestion> this.questions) : tool = '', summary = '';
  const LiveAsk.approval(this.id, {required this.tool, this.summary = ''}) : questions = null;

  factory LiveAsk.fromJson(Map<String, dynamic> j) => j['kind'] == 'approval'
      ? LiveAsk.approval(j['id'] as String, tool: j['tool'] as String? ?? '', summary: j['summary'] as String? ?? '')
      : LiveAsk.questions(j['id'] as String, [
          for (final q in j['questions'] as List? ?? const []) LiveQuestion.fromJson((q as Map).cast()),
        ]);

  /// The tool call it belongs to.
  final String id;
  final List<LiveQuestion>? questions;
  final String tool;
  final String summary;

  bool get isApproval => questions == null;

  /// What a notification says.
  String get text => isApproval
      ? 'Approve $tool${summary.isEmpty ? '' : ': $summary'}?'
      : questions!.map((q) => q.question).join('\n');

  Map<String, dynamic> toJson() => isApproval
      ? {'kind': 'approval', 'id': id, 'tool': tool, if (summary.isNotEmpty) 'summary': summary}
      : {
          'kind': 'ask',
          'id': id,
          'questions': [for (final q in questions!) q.toJson()],
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

/// One step of answering omp's dialog with the keyboard: keys (kitty's
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

/// The keystrokes that answer [ask] in omp's terminal UI. The ask dialog
/// lists each question's options and then "Other"; its cursor stops at the
/// ends, so going up past the top and then down picks a row wherever the
/// cursor started. Enter on a single-choice row answers and moves on, Space
/// toggles a multiple-choice row and Enter moves on; after several questions
/// a Submit tab takes a last Enter. An approval is omp's Approve/Deny menu,
/// which opens on Approve.
List<KeyStep> answerKeys(LiveAsk ask, {List<LiveAnswer> answers = const [], bool approve = false}) {
  if (ask.isApproval) {
    return [
      Keys(approve ? const ['enter'] : const ['down', 'enter']),
    ];
  }
  final questions = ask.questions!;
  if (answers.length != questions.length) throw ArgumentError('One answer per question.');
  final steps = <KeyStep>[];
  void press(List<String> keys) {
    if (steps.lastOrNull case Keys(keys: final last)) {
      last.addAll(keys);
    } else {
      steps.add(Keys([...keys]));
    }
  }

  var onSubmitTab = false;
  for (final (i, q) in questions.indexed) {
    final a = answers[i];
    final rows = q.options.length + 1;
    List<String> rowKeys(int row) => [for (var k = 0; k < rows; k++) 'up', for (var k = 0; k < row; k++) 'down'];
    for (final p in a.picks) {
      if (p < 0 || p >= q.options.length) throw ArgumentError('No option $p in "${q.question}".');
    }
    final custom = a.custom?.trim();
    final hasCustom = custom != null && custom.isNotEmpty;
    if (!q.multi && (a.picks.length + (hasCustom ? 1 : 0)) != 1) {
      throw ArgumentError('Pick one answer for "${q.question}".');
    }
    if (q.multi) {
      for (final p in a.picks) {
        press([...rowKeys(p), 'space']);
      }
    }
    if (hasCustom) {
      press([...rowKeys(q.options.length), 'enter']);
      steps.add(Typed(custom));
      press(['enter']);
      // A lone multiple-choice question goes to its Submit tab after a typed answer.
      if (q.multi && questions.length == 1) onSubmitTab = true;
    } else if (q.multi) {
      press(['enter']);
    } else {
      press([...rowKeys(a.picks.single), 'enter']);
    }
  }
  if (questions.length > 1 || onSubmitTab) press(['enter']);
  return steps;
}

/// How to tell [ask] is the dialog on the screen: some of its words in the
/// screen's text, compared without spacing or Markdown marks (the terminal
/// wraps and styles them).
bool askOnScreen(LiveAsk ask, String screen) {
  String flat(String s) => s.replaceAll(RegExp(r'[\s*_`#>]+'), '').toLowerCase();
  final text = flat(screen);
  if (ask.isApproval) return text.contains('approve') && text.contains('deny');
  final q = flat(ask.questions!.first.question);
  return text.contains(q.length > 24 ? q.substring(0, 24) : q);
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
    this.window,
    this.model = '',
    this.busy = false,
    this.ask,
    this.ctx,
    this.preview = '',
    this.at,
    this.older = false,
  });

  factory LiveSummary.fromJson(Map<String, dynamic> j) => LiveSummary(
    key: j['key'] as String,
    id: j['id'] as String? ?? '',
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
  );

  /// Stable for the omp process: its kitty window's key, or `pid:<pid>`
  /// outside kitty. What the phone opens and notifications point at.
  final String key;

  /// omp's session id (changes on /new, /resume).
  final String id;
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

  Map<String, dynamic> toJson() => {
    'key': key,
    'id': id,
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
