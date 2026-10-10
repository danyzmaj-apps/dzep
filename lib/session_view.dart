import 'dart:async';

import 'package:dzep/chat_images.dart';
import 'package:dzep/live.dart';
import 'package:dzep/live_activity.dart';
import 'package:dzep/terminal_remote.dart';
import 'package:dzep/terminal_view.dart';
import 'package:dzep/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

const _mono = TextStyle(fontFamily: 'Menlo', fontFamilyFallback: ['Courier'], fontSize: 12, height: 1.35);
const _danger = Color(0xFFFCA5A5);

/// How long a just-launched omp may take to report before the page says so.
const _startWait = Duration(seconds: 20);

void _unfocus(PointerDownEvent _) => FocusManager.instance.primaryFocus?.unfocus();

/// One omp session, live: its transcript laid out for the phone, what omp
/// asks, and a composer that prompts it.
class SessionPage extends StatefulWidget {
  const SessionPage({required this.remote, required this.sessionKey, this.starting = false, super.key});
  final TerminalRemote remote;
  final String sessionKey;

  /// Just launched: omp may not have reported yet.
  final bool starting;

  @override
  State<SessionPage> createState() => _SessionPageState();
}

class _SessionPageState extends State<SessionPage> {
  final _scroll = ScrollController();
  final _field = TextEditingController();
  final _attachments = ChatAttachments();
  late final VoidCallback _unwatch;
  final _openedAt = DateTime.now();

  /// Items ordered before [_anchor] sit above the scroll view's center,
  /// newer ones below it, so arrivals never move what the reader looks at.
  /// Set from the transcript there is at first (again if it starts over).
  int? _anchor;
  String? _anchorEpoch;
  bool _atBottom = true;

  /// The session has been in the Mac's state since the page opened.
  bool _seen = false;
  bool _sending = false;
  bool _stopping = false;
  bool _followUp = false;
  bool _loadingOlder = false;

  /// Tool items showing their output.
  final _expanded = <String>{};

  /// Each item's widget and what it was built from, so a transcript update
  /// rebuilds only the items that changed.
  final _built = <String, (Object, Widget)>{};

  TerminalRemote get remote => widget.remote;
  String get key => widget.sessionKey;

  @override
  void initState() {
    super.initState();
    _field.addListener(() => setState(() {}));
    _attachments.addListener(() => setState(() {}));
    _scroll.addListener(() {
      final p = _scroll.position;
      _atBottom = p.pixels >= p.maxScrollExtent - 24;
    });
    _unwatch = remote.watchSession(key);
  }

  @override
  void dispose() {
    _unwatch();
    _scroll.dispose();
    _field.dispose();
    _attachments.dispose();
    super.dispose();
  }

  /// The kitty window omp runs in, if it runs in one (a launched one before
  /// omp reports: the session's key is its window's).
  String? _windowKey(LiveSummary? s) => s?.window ?? (remote.window(key) != null ? key : null);

  Future<void> _attach(String from) async {
    if (from == 'photos') return await _attachments.pick();
    if (!await _attachments.paste() && mounted) termToast(context, 'There is no image on the clipboard.');
  }

  Future<void> _send({required bool busy}) async {
    final typed = _field.text;
    final text = typed.trim();
    if ((text.isEmpty && _attachments.isEmpty) || _sending) return;
    final images = List.of(_attachments.images);
    setState(() => _sending = true);
    try {
      await remote.prompt(key, text, images: [for (final i in images) i.bytes], followUp: busy && _followUp);
      // On the Lock Screen from here on, as working.
      final s = remote.session(key);
      if (s != null) unawaited(remote.activities?.prompted(key, title: _title(s)));
      // Only what went: the field stays editable while it goes, and what was
      // typed or attached meanwhile is the next prompt.
      final now = _field.text;
      _field.text = now.startsWith(typed) ? now.substring(typed.length).trimLeft() : now;
      for (final i in images) {
        final at = _attachments.images.indexOf(i);
        if (at >= 0) _attachments.removeAt(at);
      }
      _atBottom = true;
    } on Object catch (e) {
      if (mounted) termToast(context, e);
    }
    if (mounted) setState(() => _sending = false);
  }

  String _title(LiveSummary s) => s.title.isNotEmpty ? s.title : baseName(s.cwd);

  /// Puts `/name ` in the field, the cursor after it.
  void _complete(LiveCommand c) {
    final text = '/${c.name} ';
    _field.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  /// Slash commands go to omp's kitty window: the [matches] while the name
  /// is typed, or a word that they can't run without one.
  Widget? _commands(List<LiveCommand> matches, {required bool noWindow}) {
    if (noWindow) {
      return const Padding(
        key: ValueKey('commands-need-window'),
        padding: EdgeInsets.fromLTRB(12, 2, 12, 6),
        child: Text(
          'Slash commands run in omp’s kitty window, and this session has none.',
          style: TextStyle(color: C.dim, fontSize: 12),
        ),
      );
    }
    if (matches.isEmpty) return null;
    // Part of the field for tap-outside: picking one keeps the keyboard up.
    return TextFieldTapRegion(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final c in matches)
              InkWell(
                key: ValueKey('command-${c.name}'),
                canRequestFocus: false,
                borderRadius: BorderRadius.circular(6),
                onTap: () => _complete(c),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '/${c.name}',
                          style: const TextStyle(color: C.text, fontWeight: FontWeight.w600),
                        ),
                        if (c.description.isNotEmpty)
                          TextSpan(
                            text: '  ${c.description}',
                            style: const TextStyle(color: C.dim),
                          ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _toggleFollow(LiveActivities activities, LiveSummary s) async {
    if (activities.following(key)) return await activities.stop(key);
    if (!await activities.follow(key, title: _title(s)) && mounted) {
      termToast(context, 'Live Activities are off for Džep: turn them on in Settings → Džep.');
    }
  }

  Future<void> _stop() async {
    setState(() => _stopping = true);
    try {
      await remote.abort(key);
    } on Object catch (e) {
      if (mounted) termToast(context, e);
    }
    if (mounted) setState(() => _stopping = false);
  }

  Future<void> _older() async {
    setState(() => _loadingOlder = true);
    try {
      await remote.older(key);
    } on Object catch (e) {
      if (mounted) termToast(context, e);
    }
    if (mounted) setState(() => _loadingOlder = false);
  }

  void _followBottom() {
    if (!_atBottom) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final p = _scroll.position;
      if (p.pixels != p.maxScrollExtent) _scroll.jumpTo(p.maxScrollExtent);
    });
  }

  // ---------------------------------------------------------------- items

  Widget _item(LiveItem i) {
    final open = _expanded.contains(i.id);
    final made = (i.kind, i.text, i.images, i.tool, i.title, i.args, i.output, i.status, open);
    final hit = _built[i.id];
    if (hit != null && hit.$1 == made) return hit.$2;
    final w = KeyedSubtree(
      key: ValueKey(i.id),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
        child: switch (i.kind) {
          ItemKind.user => _UserBubble(i),
          ItemKind.assistant => _AssistantText(i.text),
          ItemKind.tool => _ToolCard(
            i,
            open: open,
            onTap: () => setState(() => open ? _expanded.remove(i.id) : _expanded.add(i.id)),
          ),
          ItemKind.notice => _Notice(
            i.text,
            open: open,
            onTap: () => setState(() => open ? _expanded.remove(i.id) : _expanded.add(i.id)),
          ),
        },
      ),
    );
    _built[i.id] = (made, w);
    return w;
  }

  Widget _transcript(LiveView? v, LiveSummary? s, {required bool ended}) {
    final items = v?.items ?? const <LiveItem>[];
    if (v != null && items.isNotEmpty && (_anchor == null || _anchorEpoch != v.epoch)) {
      _anchor = items.last.order + 1;
      _anchorEpoch = v.epoch;
      _atBottom = true;
      _built.clear();
    }
    if (items.isEmpty) {
      final starting = widget.starting && !_seen;
      final late = DateTime.now().difference(_openedAt) > _startWait;
      final text = starting
          ? (late ? "omp hasn't reported yet. Its screen shows what it's doing." : 'Starting omp…')
          : ended
          ? 'This session has ended.'
          : v != null
          ? 'Nothing yet. Prompt omp below.'
          : remote.online
          ? 'Loading…'
          : 'Not on this iPhone yet.';
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: C.dim, height: 1.5),
          ),
        ),
      );
    }
    // First item at or after the anchor.
    var lo = 0;
    var hi = items.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (items[mid].order < _anchor!) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final above = lo;
    final earlier = v!.older;
    const center = ValueKey('center');
    _followBottom();
    return SelectionArea(
      child: CustomScrollView(
        controller: _scroll,
        center: center,
        // The center at the bottom: the newest item shows first, and a short
        // transcript sits down by the composer.
        anchor: 1,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [
          // Before the center: laid out upwards from it, newest first.
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (_, i) => i < above ? _item(items[above - 1 - i]) : _earlierButton(),
              childCount: above + (earlier ? 1 : 0),
            ),
          ),
          SliverList(
            key: center,
            delegate: SliverChildBuilderDelegate((_, i) => _item(items[above + i]), childCount: items.length - above),
          ),
          if (s != null && s.busy && s.ask == null)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Row(
                  children: [
                    SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
                    SizedBox(width: 10),
                    Text('Working…', style: TextStyle(fontSize: 13, color: C.dim)),
                  ],
                ),
              ),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
        ],
      ),
    );
  }

  Widget _earlierButton() => SelectionContainer.disabled(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Center(
        child: _loadingOlder
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : TextButton(
                key: const ValueKey('earlier'),
                onPressed: remote.online ? () => unawaited(_older()) : null,
                child: const Text('Earlier messages'),
              ),
      ),
    ),
  );

  // --------------------------------------------------------------- chrome

  Widget _status(LiveSummary? s) {
    final parts = <InlineSpan>[];
    if (s == null) {
      parts.add(const TextSpan(text: 'omp'));
    } else {
      parts.add(
        TextSpan(
          text: s.ask != null
              ? 'Needs you'
              : s.busy
              ? 'Working…'
              : 'Idle${s.at == null ? '' : ' · ${ago(s.at!)}'}',
          style: TextStyle(color: s.ask != null || s.busy ? sessionColor(s) : null),
        ),
      );
      if (s.model.isNotEmpty) parts.add(TextSpan(text: ' · ${s.model}'));
      if (s.ctx != null) parts.add(TextSpan(text: ' · ${s.ctx}%'));
    }
    return Text.rich(
      TextSpan(children: parts),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 12, color: C.dim),
    );
  }

  Widget _banner(String text, {List<Widget> actions = const []}) => Container(
    color: C.bar,
    padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
    child: SafeArea(
      top: false,
      child: Row(
        children: [
          Expanded(
            child: Text(text, style: const TextStyle(fontSize: 14, color: C.dim)),
          ),
          ...actions,
        ],
      ),
    ),
  );

  Widget _composer(LiveSummary? s, {required bool online}) {
    final busy = s?.busy ?? false;
    final canSend = online && !_sending && (_field.text.trim().isNotEmpty || !_attachments.isEmpty);
    final slash = _field.text.startsWith('/');
    final commanding = online && s != null && slash;
    final noWindow = commanding && _windowKey(s) == null;
    final matches = commanding && !noWindow ? matchCommands(s.commands, _field.text) : const <LiveCommand>[];
    final commands = _commands(matches, noWindow: noWindow);
    return Container(
      decoration: const BoxDecoration(
        color: C.bar,
        border: Border(top: BorderSide(color: C.line)),
      ),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            ?commands,
            if (busy && online)
              TextFieldTapRegion(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 0, 2),
                  child: Row(
                    children: [
                      FilterChip(
                        key: const ValueKey('follow-up'),
                        label: const Text('After this turn', style: TextStyle(fontSize: 12)),
                        tooltip: 'Off: the prompt steers omp now',
                        selected: _followUp,
                        showCheckmark: true,
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        onSelected: (v) => setState(() => _followUp = v),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        key: const ValueKey('stop'),
                        onPressed: _stopping ? null : () => unawaited(_stop()),
                        icon: const Icon(Icons.stop_circle_outlined, size: 18, color: _danger),
                        label: const Text('Stop', style: TextStyle(color: _danger)),
                      ),
                    ],
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(left: 8, right: 8),
              child: AttachmentStrip(attachments: _attachments),
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                TextFieldTapRegion(
                  child: PopupMenuButton<String>(
                    tooltip: 'Attach images',
                    enabled: online && _attachments.room > 0,
                    icon: Icon(
                      Icons.add_photo_alternate_outlined,
                      color: online && _attachments.room > 0 ? C.dim : C.dim2,
                    ),
                    color: C.bar,
                    onSelected: (from) => unawaited(_attach(from)),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'paste', child: Text('Paste image')),
                      PopupMenuItem(value: 'photos', child: Text('Choose from Photos')),
                    ],
                  ),
                ),
                Expanded(
                  // A hardware keyboard's Tab takes the first suggestion.
                  child: CallbackShortcuts(
                    bindings: {
                      if (matches.isNotEmpty)
                        const SingleActivator(LogicalKeyboardKey.tab): () => _complete(matches.first),
                    },
                    child: TextField(
                      key: const ValueKey('session-input'),
                      onTapOutside: _unfocus,
                      controller: _field,
                      minLines: 1,
                      maxLines: 6,
                      enabled: online,
                      // A command's name isn't a word to correct or capitalize.
                      autocorrect: !slash,
                      enableSuggestions: !slash,
                      textCapitalization: slash ? TextCapitalization.none : TextCapitalization.sentences,
                      style: const TextStyle(fontSize: 16, height: 1.4),
                      decoration: plainInput.copyWith(
                        hintText: busy ? (_followUp ? 'Queue a prompt…' : 'Steer omp…') : 'Prompt omp…',
                        hintStyle: const TextStyle(color: C.dim2),
                        contentPadding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
                  ),
                ),
                // Part of the field for tap-outside: sending keeps the
                // keyboard up.
                TextFieldTapRegion(
                  child: IconButton(
                    key: const ValueKey('session-send'),
                    tooltip: 'Send',
                    onPressed: canSend ? () => unawaited(_send(busy: busy)) : null,
                    icon: _sending
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : Icon(Icons.arrow_upward, color: canSend ? C.accent : C.dim2),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([remote, remote.activities]),
    builder: (context, _) {
      final s = remote.session(key);
      if (s != null) _seen = true;
      final v = remote.view(key);
      final online = remote.online;
      final ended = online && !remote.fromCache && s == null && (_seen || !widget.starting);
      final windowKey = _windowKey(s);
      final window = windowKey == null ? null : remote.window(windowKey);
      final title = s == null ? (window?.title.isNotEmpty ?? false ? window!.title : 'omp') : _title(s);
      final note = linkNote(remote);
      final ask = s?.ask;
      void screen() => openWindow(context, remote, windowKey!);
      return Scaffold(
        appBar: AppBar(
          backgroundColor: C.win,
          titleSpacing: 0,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16)),
              _status(s),
            ],
          ),
          actions: [
            if (remote.activities case final activities? when s != null)
              IconButton(
                key: const ValueKey('follow-lock-screen'),
                tooltip: activities.following(key) ? 'Stop following on Lock Screen' : 'Follow on Lock Screen',
                onPressed: () => unawaited(_toggleFollow(activities, s)),
                icon: activities.following(key)
                    ? const Icon(Icons.lock_clock, color: C.accent)
                    : const Icon(Icons.lock_clock_outlined, color: C.dim),
              ),
            if (windowKey != null)
              IconButton(
                key: const ValueKey('open-screen'),
                tooltip: 'Screen',
                onPressed: screen,
                icon: const Icon(Icons.terminal, color: C.dim),
              ),
            if (window != null && online)
              IconButton(
                key: const ValueKey('close-window'),
                tooltip: 'Close window',
                onPressed: () => unawaited(
                  closeWindow(context, remote, window).then((closed) {
                    if (closed && context.mounted) Navigator.of(context).maybePop();
                  }),
                ),
                icon: const Icon(Icons.close, color: C.dim),
              ),
          ],
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ?note,
            Expanded(child: _transcript(v, s, ended: ended)),
            if (ended)
              _banner(
                'This session has ended.',
                actions: [if (windowKey != null) TextButton(onPressed: screen, child: const Text('Screen'))],
              )
            else ...[
              if (ask != null)
                _AskCard(
                  key: ValueKey('ask-${ask.id}'),
                  remote: remote,
                  session: key,
                  ask: ask,
                  onScreen: windowKey == null ? null : screen,
                ),
              _composer(s, online: online && (s != null || !widget.starting)),
            ],
          ],
        ),
      );
    },
  );
}

class _UserBubble extends StatelessWidget {
  const _UserBubble(this.item);
  final LiveItem item;

  @override
  Widget build(BuildContext context) {
    final n = item.images;
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * .82),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          decoration: BoxDecoration(color: C.sel, borderRadius: BorderRadius.circular(14)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (item.text.isNotEmpty) Text(item.text, style: const TextStyle(fontSize: 15, height: 1.4)),
              if (n > 0)
                Padding(
                  padding: EdgeInsets.only(top: item.text.isEmpty ? 0 : 4),
                  child: Text('⊕ $n image${n == 1 ? '' : 's'}', style: const TextStyle(fontSize: 12, color: C.dim)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AssistantText extends StatelessWidget {
  const _AssistantText(this.text);
  final String text;

  static const _code = TextStyle(fontFamily: 'Menlo', fontSize: 12.5, color: Color(0xFFD7DAE3));

  @override
  Widget build(BuildContext context) => MarkdownBody(
    data: text,
    // A line break in the answer is one on screen, as omp's terminal shows it.
    softLineBreak: true,
    onTapLink: (_, href, _) {
      final uri = href == null ? null : Uri.tryParse(href);
      if (uri != null) unawaited(launchUrl(uri));
    },
    styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      p: const TextStyle(fontSize: 15, height: 1.5, color: C.text),
      listBullet: const TextStyle(fontSize: 15, height: 1.5, color: C.dim),
      a: const TextStyle(color: C.accent),
      code: _code.copyWith(backgroundColor: C.field),
      codeblockPadding: const EdgeInsets.all(10),
      codeblockDecoration: BoxDecoration(
        color: C.field,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: C.line),
      ),
      blockquoteDecoration: const BoxDecoration(
        border: Border(left: BorderSide(color: C.line2, width: 2)),
      ),
      blockSpacing: 10,
    ),
  );
}

/// omp's own lines in the transcript ("Interrupted", a finished background
/// job). A short one sits centered; a long one is left-aligned and folded to
/// three lines until tapped.
class _Notice extends StatelessWidget {
  const _Notice(this.text, {required this.open, required this.onTap});
  final String text;
  final bool open;
  final VoidCallback onTap;

  static const _style = TextStyle(fontSize: 12, color: C.dim2, height: 1.4);

  @override
  Widget build(BuildContext context) {
    if (text.length <= 80 && !text.contains('\n')) return Text(text, textAlign: TextAlign.center, style: _style);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.only(left: 10),
        decoration: const BoxDecoration(
          border: Border(left: BorderSide(color: C.line2, width: 2)),
        ),
        child: Text(text, maxLines: open ? null : 3, overflow: open ? null : TextOverflow.ellipsis, style: _style),
      ),
    );
  }
}

class _ToolCard extends StatelessWidget {
  const _ToolCard(this.item, {required this.open, required this.onTap});
  final LiveItem item;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final i = item;
    final what = i.title.isNotEmpty ? i.title : i.args;
    final status = switch (i.status) {
      ToolStatus.running => const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
      ToolStatus.ok => const Icon(Icons.check, size: 14, color: C.ok),
      ToolStatus.error => const Icon(Icons.close, size: 14, color: _danger),
    };
    return Container(
      decoration: BoxDecoration(
        color: C.field,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: i.status == ToolStatus.error ? const Color(0xFF5B2A2A) : C.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SelectionContainer.disabled(
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                child: Row(
                  children: [
                    SizedBox(width: 16, child: Center(child: status)),
                    const SizedBox(width: 8),
                    Text(
                      i.tool,
                      style: _mono.copyWith(fontWeight: FontWeight.w600, color: C.text),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        what,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _mono.copyWith(color: C.dim),
                      ),
                    ),
                    Icon(open ? Icons.expand_less : Icons.expand_more, size: 16, color: C.dim2),
                  ],
                ),
              ),
            ),
          ),
          if (open) ...[
            const Divider(height: 1, color: C.line),
            if (i.title.isNotEmpty && i.args.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
                child: Text(i.args, style: _mono.copyWith(color: C.dim)),
              ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Text(
                i.output.isEmpty ? (i.status == ToolStatus.running ? '…' : 'No output.') : i.output,
                softWrap: false,
                style: _mono.copyWith(color: const Color(0xFFD7DAE3)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// What omp asks, answered from the phone: the `ask` tool's questions, an
/// approval, or the plan review at the end of plan mode (its options as the
/// Mac read them off omp's screen; the plan itself is read on the screen).
class _AskCard extends StatefulWidget {
  const _AskCard({required this.remote, required this.session, required this.ask, this.onScreen, super.key});
  final TerminalRemote remote;
  final String session;
  final LiveAsk ask;

  /// Opens the session's screen; null when it has none.
  final VoidCallback? onScreen;

  @override
  State<_AskCard> createState() => _AskCardState();
}

class _AskCardState extends State<_AskCard> {
  late final List<Set<int>> _picks = [for (final _ in widget.ask.questions ?? const []) <int>{}];
  late final List<TextEditingController> _other = [
    for (final _ in widget.ask.questions ?? const []) TextEditingController(),
  ];
  bool _sending = false;

  /// The plan review option being sent.
  int? _planPick;

  /// Sent; the card stays until omp moves on.
  bool _sent = false;

  @override
  void dispose() {
    for (final c in _other) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _complete {
    final qs = widget.ask.questions!;
    for (final (i, q) in qs.indexed) {
      final custom = _other[i].text.trim().isNotEmpty ? 1 : 0;
      if (q.multi ? _picks[i].length + custom == 0 : _picks[i].length + custom != 1) return false;
    }
    return true;
  }

  Future<void> _answer({bool approve = false, int? plan}) async {
    setState(() {
      _sending = true;
      _planPick = plan;
    });
    try {
      final ask = widget.ask;
      await widget.remote.answer(
        widget.session,
        ask,
        approve: approve,
        answers: [
          if (plan != null)
            LiveAnswer(picks: [plan])
          else if (!ask.isApproval)
            for (final (i, p) in _picks.indexed)
              LiveAnswer(
                picks: p.toList()..sort(),
                custom: _other[i].text.trim().isEmpty ? null : _other[i].text.trim(),
              ),
        ],
      );
      _sent = true;
    } on Object catch (e) {
      if (mounted) termToast(context, e);
    }
    if (mounted) setState(() => _sending = false);
  }

  Widget _question(int i, LiveQuestion q) {
    final busy = _sending || _sent;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (q.header.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(color: C.sel, borderRadius: BorderRadius.circular(6)),
            child: Text(q.header, style: const TextStyle(fontSize: 11, color: C.accent)),
          ),
        Text(q.question, style: const TextStyle(fontSize: 15, height: 1.4)),
        if (q.multi)
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Text('Pick any', style: TextStyle(fontSize: 12, color: C.dim2)),
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final (o, label) in q.options.indexed)
              ChoiceChip(
                key: ValueKey('ask-$i-$o'),
                label: Text(q.recommended == o ? '$label ★' : label),
                selected: _picks[i].contains(o),
                showCheckmark: q.multi,
                onSelected: busy
                    ? null
                    : (on) => setState(() {
                        if (!q.multi) {
                          _picks[i].clear();
                          _other[i].clear();
                        }
                        on ? _picks[i].add(o) : _picks[i].remove(o);
                      }),
              ),
          ],
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _other[i],
          enabled: !busy,
          onTapOutside: _unfocus,
          onChanged: (t) => setState(() {
            if (!q.multi && t.trim().isNotEmpty) _picks[i].clear();
          }),
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            hintText: 'Other…',
            hintStyle: const TextStyle(color: C.dim2),
            isDense: true,
            filled: true,
            fillColor: C.field,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final ask = widget.ask;
    final busy = _sending || _sent;
    final online = widget.remote.online;
    final spinner = _sending
        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
        : null;
    final Widget body;
    final List<Widget> buttons;
    if (ask.isPlan) {
      final screen = widget.onScreen;
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Plan ready', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          if (ask.title.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(ask.title, style: _mono.copyWith(color: C.dim)),
            ),
          if (ask.options.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('omp is waiting on its screen', style: TextStyle(fontSize: 13, color: C.dim)),
            ),
          for (final (i, label) in ask.options.indexed)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: OutlinedButton(
                key: ValueKey('plan-$i'),
                style: OutlinedButton.styleFrom(
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                ),
                onPressed: busy || !online ? null : () => unawaited(_answer(plan: i)),
                child: Row(
                  children: [
                    Expanded(child: Text(label, style: const TextStyle(fontSize: 14, height: 1.3))),
                    if (_sending && _planPick == i) ...[const SizedBox(width: 8), spinner!],
                  ],
                ),
              ),
            ),
        ],
      );
      buttons = [
        if (screen != null)
          TextButton.icon(
            key: ValueKey(ask.options.isEmpty ? 'plan-screen' : 'view-plan'),
            onPressed: screen,
            icon: const Icon(Icons.terminal, size: 18),
            label: Text(ask.options.isEmpty ? 'Screen' : 'View plan'),
          ),
      ];
    } else if (ask.isApproval) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Approve ${ask.tool}?', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          if (ask.summary.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(ask.summary, style: _mono.copyWith(color: C.dim)),
            ),
        ],
      );
      buttons = [
        OutlinedButton(
          key: const ValueKey('deny'),
          onPressed: busy || !online ? null : () => unawaited(_answer()),
          child: const Text('Deny'),
        ),
        const SizedBox(width: 8),
        FilledButton(
          key: const ValueKey('approve'),
          onPressed: busy || !online ? null : () => unawaited(_answer(approve: true)),
          child: spinner ?? const Text('Approve'),
        ),
      ];
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, q) in ask.questions!.indexed) ...[if (i > 0) const SizedBox(height: 16), _question(i, q)],
        ],
      );
      buttons = [
        FilledButton(
          key: const ValueKey('answer'),
          onPressed: busy || !online || !_complete ? null : () => unawaited(_answer()),
          child: spinner ?? Text(_sent ? 'Answered' : 'Answer'),
        ),
      ];
    }
    return Container(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .45),
      decoration: const BoxDecoration(
        color: Color(0xFF221F17),
        border: Border(top: BorderSide(color: Color(0xFF4A3F1F))),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('omp needs you', style: TextStyle(fontSize: 12, color: C.warn)),
            ),
            body,
            const SizedBox(height: 10),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: buttons),
          ],
        ),
      ),
    );
  }
}
