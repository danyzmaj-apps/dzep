import 'dart:async';

import 'package:dzep/chat.dart';
import 'package:dzep/chat_images.dart';
import 'package:dzep/chat_view.dart';
import 'package:dzep/controller.dart';
import 'package:dzep/idea.dart';
import 'package:dzep/remind.dart';
import 'package:dzep/store.dart';
import 'package:dzep/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// `@name` tokens in the title: the first one is the project.
final _projectToken = RegExp(r'(^|\s)@([\w.-]+)');

({String title, String project}) parseTitle(String raw) {
  final m = _projectToken.firstMatch(raw);
  final title = raw.replaceAll(_projectToken, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  return (title: title, project: m?.group(2) ?? '');
}

/// The ⇧⌘Space panel: title field focused, ↵ saves and gets out of
/// the way. Tab adds a description; the list shows recent or similar ideas.
class Popup extends StatefulWidget {
  const Popup({required this.app, super.key});
  final AppController app;

  @override
  State<Popup> createState() => _PopupState();
}

class _PopupState extends State<Popup> {
  final _title = TextEditingController();
  final _notes = TextEditingController();
  late final FocusNode _titleFocus = FocusNode(onKeyEvent: _onTitleKey);
  late final FocusNode _notesFocus = FocusNode(onKeyEvent: _onNotesKey);
  bool _withNotes = false;

  final _question = TextEditingController();
  late final FocusNode _questionFocus = FocusNode(onKeyEvent: _onQuestionKey);
  final _attachments = ChatAttachments();

  /// Every open starts by choosing: 1 idea, 2 todo, 3 ask, 4 open the app.
  bool _choosing = true;

  /// Picked 3: the quick-question chat instead of capture.
  bool _asking = false;

  /// What ↵ saves, picked in the chooser.
  Kind _kind = Kind.idea;
  int _sel = -1;
  List<Idea> _shown = const [];
  int _session = -1;

  AppController get app => widget.app;
  IdeaStore? get store => app.store;

  @override
  void initState() {
    super.initState();
    _title.addListener(() => setState(() => _sel = -1));
    _notesFocus.addListener(() => setState(() {}));
    app.addListener(_onApp);
    HardwareKeyboard.instance.addHandler(_onAnyKey);
    _onApp();
  }

  @override
  void dispose() {
    app.removeListener(_onApp);
    HardwareKeyboard.instance.removeHandler(_onAnyKey);
    _title.dispose();
    _notes.dispose();
    _titleFocus.dispose();
    _notesFocus.dispose();
    _question.dispose();
    _questionFocus.dispose();
    _attachments.dispose();
    super.dispose();
  }

  /// A new open resets to the chooser right away (not on the next frame), so
  /// a quick ⇧⌘Space-then-1 never lands on a stale screen.
  void _onApp() {
    if (_session == app.popupSession) return;
    _session = app.popupSession;
    _sel = -1;
    _choosing = !app.askNext;
    _asking = app.askNext;
    if (app.askNext) {
      app.askNext = false;
      _focusSoon(_question, _questionFocus);
    }
    _titleFocus.unfocus();
    _notesFocus.unfocus();
    _questionFocus.unfocus();
    if (mounted) setState(() {});
  }

  // ---------------------------------------------------------------- keys

  bool get _cmd => HardwareKeyboard.instance.isMetaPressed;
  bool get _shift => HardwareKeyboard.instance.isShiftPressed;

  /// The field a pick is about to focus: characters typed before it has
  /// focus go into it.
  TextEditingController? _awaiting;

  /// Sees every key, whatever has focus: the chooser has no field to focus,
  /// and the window can take keys a frame before Flutter has rebuilt it.
  bool _onAnyKey(KeyEvent e) {
    if (!app.popupOpen || e is KeyUpEvent) return false;
    final k = e.logicalKey;
    if (_choosing) {
      if (k == LogicalKeyboardKey.digit1 || k == LogicalKeyboardKey.numpad1) {
        _pick(Kind.idea);
      } else if (k == LogicalKeyboardKey.digit2 || k == LogicalKeyboardKey.numpad2) {
        _pick(Kind.todo);
      } else if (k == LogicalKeyboardKey.digit3 || k == LogicalKeyboardKey.numpad3) {
        _ask();
      } else if (k == LogicalKeyboardKey.digit4 || k == LogicalKeyboardKey.numpad4) {
        unawaited(app.openMain());
      } else if (k == LogicalKeyboardKey.escape) {
        unawaited(app.closePopup());
      } else {
        return false;
      }
      return true;
    }
    // The chat's keys work whether the field or the transcript has focus.
    final chat = app.chats;
    if (_asking && chat != null) {
      if (k == LogicalKeyboardKey.escape) {
        unawaited(app.closePopup());
      } else if (k == LogicalKeyboardKey.keyN && _cmd) {
        chat.newChat();
        _question.clear();
        _attachments.take();
        _questionFocus.requestFocus();
      } else if (k == LogicalKeyboardKey.keyO && _cmd) {
        unawaited(app.openMain(conversation: chat.current));
      } else if (k == LogicalKeyboardKey.keyC && _cmd && _shift) {
        copyAnswer(context, chat.current?.lastAnswer);
      } else if (isPasteKey(e)) {
        // An image on the clipboard is attached; text still pastes as usual.
        unawaited(_attachments.paste());
        return false;
      } else {
        return false;
      }
      return true;
    }
    final ch = e.character;
    final target = _awaiting;
    if (target != null && ch != null && ch.runes.every((r) => r >= 0x20)) {
      target.text += ch;
      return true;
    }
    return false;
  }

  void _pick(Kind kind) {
    setState(() {
      if (kind != _kind) {
        // A half-typed idea isn't a todo draft.
        _title.clear();
        _notes.clear();
        _withNotes = false;
      }
      _kind = kind;
      _choosing = false;
      _asking = false;
      _sel = -1;
    });
    _focusSoon(_title, _titleFocus);
  }

  /// Opens the chat where it was left; ⌘N starts a new one.
  void _ask() {
    setState(() {
      _choosing = false;
      _asking = true;
    });
    _focusSoon(_question, _questionFocus);
  }

  void _focusSoon(TextEditingController text, FocusNode focus) {
    _awaiting = text;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      focus.requestFocus();
      text.selection = TextSelection.collapsed(offset: text.text.length);
      _awaiting = null;
    });
  }

  KeyEventResult _onTitleKey(FocusNode _, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.tab && !_shift) {
      if (_completeProject()) return KeyEventResult.handled;
      setState(() => _withNotes = true);
      _notesFocus.requestFocus();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyD && _cmd) {
      final picked = _sel >= 0 ? _shown[_sel] : null;
      if (picked != null && picked.isTodo) _toggleTodo(picked);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyO && _cmd) {
      unawaited(app.openMain(select: _sel >= 0 ? _shown[_sel].id : null));
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
      if (_sel >= 0) {
        unawaited(app.openMain(select: _shown[_sel].id));
      } else {
        _save(stay: _cmd);
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown && _shown.isNotEmpty) {
      setState(() => _sel = (_sel + 1).clamp(0, _shown.length - 1));
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp && _sel >= 0) {
      setState(() => _sel--);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape) {
      if (_sel >= 0) {
        setState(() => _sel = -1);
      } else {
        unawaited(app.closePopup());
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _onNotesKey(FocusNode _, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.tab && _shift) {
      if (_notes.text.trim().isEmpty) setState(() => _withNotes = false);
      _titleFocus.requestFocus();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.tab) return KeyEventResult.handled;
    if ((k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) && _cmd) {
      _save(stay: false);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape) {
      unawaited(app.closePopup());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _onQuestionKey(FocusNode _, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if ((k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) && !_shift) {
      final text = _question.text;
      final chat = app.chats;
      if (chat != null && (text.trim().isNotEmpty || !_attachments.isEmpty) && !chat.busy) {
        _question.clear();
        unawaited(chat.send(text, images: _attachments.take()));
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Tab right after `@pro` completes it to a known project.
  bool _completeProject() {
    final m = RegExp(r'@([\w.-]*)$').firstMatch(_title.text);
    if (m == null) return false;
    final hit = (store?.projects ?? const []).where((p) => p.startsWith(m.group(1)!)).firstOrNull;
    if (hit == null) return false;
    final text = '${_title.text.substring(0, m.start)}@$hit ';
    _title.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    return true;
  }

  void _toggleTodo(Idea todo) {
    store?.update(todo, done: !todo.done);
    setState(() {});
    Toaster.of(context).show(todo.done ? 'Done ✓' : 'Reopened', undo: () => store?.update(todo, done: !todo.done));
  }

  void _save({required bool stay}) {
    final s = store;
    if (s == null) return;
    final todo = _kind == Kind.todo;
    // Todos take a `!` reminder (lib/remind.dart), ideas a `@project`.
    final remind = todo ? parseReminder(_title.text, DateTime.now()) : null;
    final parsed = remind != null ? (title: remind.title, project: '') : parseTitle(_title.text);
    var title = parsed.title;
    var notes = _notes.text.trim();
    if (title.isEmpty && notes.isEmpty) return;
    if (title.isEmpty) {
      final lines = notes.split('\n');
      title = lines.first.trim();
      notes = lines.skip(1).join('\n').trim();
    }
    s.add(title: title, kind: _kind, notes: notes, project: parsed.project, remindAt: remind?.at);
    _title.clear();
    _notes.clear();
    setState(() => _withNotes = false);
    final at = remind?.at;
    final saved = todo ? 'Todo added ✓' : 'Idea saved ✓';
    Toaster.of(context).show(at == null ? saved : '$saved  🔔 ${reminderLabel(at, DateTime.now())}');
    if (stay) {
      _titleFocus.requestFocus();
    } else {
      unawaited(app.closePopup());
    }
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final s = store;
    final stage = s == null ? 'locked' : (_choosing ? 'choose' : (_asking ? 'ask' : _kind.name));
    // The window is a fixed, transparent 720×660 (no resizes, see
    // MainFlutterWindow.swift); the panel sits at its top and animates its
    // height between stages. A click on the empty area closes the popup,
    // like a click anywhere else.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => unawaited(app.closePopup()),
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 40),
          child: GestureDetector(
            onTap: () {}, // clicks on the panel stay on the panel
            child: Container(
              constraints: const BoxConstraints(maxWidth: 680),
              decoration: BoxDecoration(
                color: const Color(0xF517181D),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: C.line2),
                boxShadow: const [BoxShadow(color: Color(0x8C000000), blurRadius: 36, offset: Offset(0, 14))],
              ),
              clipBehavior: Clip.antiAlias,
              child: AnimatedSize(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Flexible: the panel is a fixed size, so a long chat
                    // gives up room to the composer (images, a long question).
                    Flexible(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        // Stack the outgoing and incoming stages at the top, so
                        // the size animation is the only thing that moves.
                        layoutBuilder: (current, previous) =>
                            Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
                        transitionBuilder: (child, animation) => FadeTransition(
                          opacity: animation,
                          child: SlideTransition(
                            position: Tween(begin: const Offset(0, .04), end: Offset.zero).animate(animation),
                            child: child,
                          ),
                        ),
                        child: KeyedSubtree(
                          key: ValueKey(stage),
                          child: s == null
                              ? _locked()
                              : _choosing
                              ? _chooser(s)
                              : _asking
                              ? _askPane(app.chats!)
                              : Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: _capture(s),
                                ),
                        ),
                      ),
                    ),
                    _bar(s),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _locked() => Padding(
    padding: const EdgeInsets.fromLTRB(24, 26, 24, 26),
    child: Column(
      children: [
        const Text('Sign in to start dropping ideas', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        const Text(
          'Ideas are stored in your account, so every Mac you sign in on sees the same list.',
          style: TextStyle(color: C.dim),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 14),
        GithubButton(
          onPressed: () {
            unawaited(app.openMain());
            unawaited(app.signIn());
          },
          compact: true,
        ),
      ],
    ),
  );

  Widget _chooser(IdeaStore s) {
    Widget tile(String key, Widget icon, String label, VoidCallback onTap) => Expanded(
      child: Hoverable(
        onTap: onTap,
        builder: (hover) => Container(
          padding: const EdgeInsets.symmetric(vertical: 18),
          decoration: BoxDecoration(
            color: hover ? C.sel : C.field,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: hover ? C.accent : C.line2),
          ),
          child: Column(
            children: [
              SizedBox(height: 26, child: Center(child: icon)),
              const SizedBox(height: 8),
              Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Kbd(key),
            ],
          ),
        ),
      ),
    );

    final todos = s.openTodos.take(5).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              tile('1', const Text('💡', style: TextStyle(fontSize: 22)), 'Idea', () => _pick(Kind.idea)),
              const SizedBox(width: 10),
              tile('2', const TodoCheck(done: false, size: 22), 'Todo', () => _pick(Kind.todo)),
              const SizedBox(width: 10),
              tile('3', const Icon(Icons.auto_awesome, size: 22, color: C.accent), 'Ask', _ask),
              const SizedBox(width: 10),
              tile(
                '4',
                const Icon(Icons.open_in_new, size: 22, color: C.dim),
                'Open app',
                () => unawaited(app.openMain()),
              ),
            ],
          ),
        ),
        if (todos.isNotEmpty) ...[
          const Divider(height: 1, color: C.line),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
            child: Text(
              'OPEN TODOS · ${s.openTodos.length}',
              style: const TextStyle(fontSize: 11, letterSpacing: .6, color: C.dim),
            ),
          ),
          for (final t in todos)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
              child: Row(
                children: [
                  GestureDetector(onTap: () => _toggleTodo(t), child: const TodoCheck(done: false, size: 14)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      t.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 6),
        ],
      ],
    );
  }

  List<Widget> _capture(IdeaStore s) {
    final todoMode = _kind == Kind.todo;
    final remind = todoMode ? parseReminder(_title.text, DateTime.now()) : null;
    final parsed = remind != null ? (title: remind.title, project: '') : parseTitle(_title.text);
    final words = parsed.title.toLowerCase().split(RegExp(r'\s+')).where((w) => w.length > 2).toList();
    bool similar(Idea i) => words.any('${i.title} ${i.notes}'.toLowerCase().contains);
    // The list below the field: open todos (filtered as you type) in todo
    // mode, recent or similar ideas in idea mode.
    final todos = todoMode ? (words.isEmpty ? s.openTodos : s.openTodos.where(similar)).take(7).toList() : <Idea>[];
    final ideas = todoMode
        ? <Idea>[]
        : (words.isEmpty ? s.ideas : s.ideas.where(similar)).take(words.isEmpty ? 5 : 7).toList();
    _shown = [...todos, ...ideas];
    if (_sel >= _shown.length) _sel = _shown.length - 1;

    final completing = todoMode ? null : RegExp(r'@([\w.-]*)$').firstMatch(_title.text);
    final suggestions = completing == null
        ? const <String>[]
        : s.projects.where((p) => p.startsWith(completing.group(1)!)).take(4).toList();

    Widget section(String label) => Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
      child: Text(label, style: const TextStyle(fontSize: 11, letterSpacing: .6, color: C.dim)),
    );

    Widget row(int k, Idea i) => Hoverable(
      onTap: () => unawaited(app.openMain(select: i.id)),
      builder: (hover) => Container(
        color: k == _sel ? C.sel : (hover ? C.hover : null),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
        child: Row(
          children: [
            if (i.isTodo)
              GestureDetector(
                onTap: () => _toggleTodo(i),
                child: TodoCheck(done: i.done, size: 14),
              )
            else
              const Dot(C.dim),
            const SizedBox(width: 10),
            Expanded(
              child: Text.rich(
                highlight(i.title, words.join(' '), const TextStyle(fontSize: 13, color: C.text)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (i.project.isNotEmpty) ...[const SizedBox(width: 8), ProjectChip(i.project)],
            if (i.remindAt case final at? when !i.done) ...[const SizedBox(width: 8), ReminderChip(at)],
            const SizedBox(width: 10),
            Text(stamp(i.createdAt), style: const TextStyle(fontSize: 11, color: C.dim)),
          ],
        ),
      ),
    );

    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: todoMode
                  ? const Padding(padding: EdgeInsets.all(2), child: TodoCheck(done: false, size: 18))
                  : const Text('💡', style: TextStyle(fontSize: 18)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _title,
                    focusNode: _titleFocus,
                    style: const TextStyle(fontSize: 18, height: 1.4),
                    decoration: plainInput.copyWith(
                      hintText: todoMode ? 'Add a todo…  !15:00' : 'Drop an idea…  @project',
                      hintStyle: const TextStyle(color: C.dim2),
                    ),
                  ),
                  if (_withNotes)
                    Container(
                      margin: const EdgeInsets.only(top: 8),
                      padding: const EdgeInsets.only(left: 10),
                      decoration: BoxDecoration(
                        border: Border(left: BorderSide(color: _notesFocus.hasFocus ? C.accent : C.line2, width: 2)),
                      ),
                      child: TextField(
                        controller: _notes,
                        focusNode: _notesFocus,
                        minLines: 2,
                        maxLines: 8,
                        style: const TextStyle(fontSize: 14, height: 1.5, color: Color(0xFFC9CCD5)),
                        decoration: plainInput.copyWith(
                          hintText: 'Description (optional)',
                          hintStyle: const TextStyle(color: C.dim2),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(48, 0, 18, 12),
        child: Row(
          children: [
            if (parsed.project.isNotEmpty) ...[ProjectChip(parsed.project), const SizedBox(width: 8)],
            if (remind?.at case final at?) ...[ReminderChip(at), const SizedBox(width: 8)],
            if (suggestions.isNotEmpty)
              Text('tab → ${suggestions.join(' · ')}', style: const TextStyle(fontSize: 12, color: C.dim2))
            else if (!_withNotes && parsed.title.isNotEmpty) ...[
              const Kbd('⇥'),
              const SizedBox(width: 6),
              const Text('add description', style: TextStyle(fontSize: 12, color: C.dim2)),
            ],
          ],
        ),
      ),
      Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: C.line)),
        ),
        constraints: const BoxConstraints(maxHeight: 300),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: 6),
          children: [
            if (todos.isNotEmpty || todoMode)
              section(todoMode && words.isNotEmpty ? '${todos.length} SIMILAR TODOS' : 'OPEN TODOS'),
            if (todoMode && todos.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 10),
                child: Text(
                  words.isEmpty ? 'All done. Type one and press ↵.' : 'Nothing similar. Press ↵ to add it.',
                  style: const TextStyle(color: C.dim),
                ),
              ),
            for (final (k, i) in todos.indexed) row(k, i),
            if (!todoMode) ...[
              section(words.isEmpty ? 'RECENT IDEAS' : '${ideas.length} SIMILAR'),
              if (ideas.isEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(18, 8, 18, 10),
                  child: Text('Nothing similar. Press ↵ to save it.', style: TextStyle(color: C.dim)),
                ),
              for (final (k, i) in ideas.indexed) row(todos.length + k, i),
            ],
          ],
        ),
      ),
    ];
  }

  /// The quick-question chat: the conversation above, the question field
  /// below. It continues where it was left; ⌘N starts a new one and the old
  /// one stays in the main window's Quick questions (and on the iPhone).
  Widget _askPane(ChatStore chat) => ListenableBuilder(
    listenable: chat,
    builder: (context, _) {
      final c = chat.current;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (c != null && c.messages.isNotEmpty)
            Flexible(
              child: Container(
                constraints: const BoxConstraints(maxHeight: 440),
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: C.line)),
                ),
                child: ChatTranscript(chat: chat, conversation: c, shrinkWrap: true),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AttachmentStrip(attachments: _attachments),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 3),
                      child: Icon(Icons.auto_awesome, size: 20, color: C.accent),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _question,
                        focusNode: _questionFocus,
                        minLines: 1,
                        maxLines: 6,
                        style: const TextStyle(fontSize: 18, height: 1.4),
                        decoration: plainInput.copyWith(
                          hintText: c == null ? 'Ask a quick question…' : 'Follow up…',
                          hintStyle: const TextStyle(color: C.dim2),
                        ),
                      ),
                    ),
                    AttachButton(attachments: _attachments, size: 20, around: app.pickFromPopup),
                  ],
                ),
              ],
            ),
          ),
        ],
      );
    },
  );

  Widget _bar(IdeaStore? s) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
    decoration: const BoxDecoration(
      color: C.bar,
      border: Border(top: BorderSide(color: C.line)),
    ),
    child: Row(
      children: [
        if (s == null)
          const SyncDot(null)
        else
          ListenableBuilder(listenable: s, builder: (_, _) => SyncDot(s.syncState)),
        const Spacer(),
        if (s == null)
          const KeyHint('esc', 'hide')
        else if (_choosing) ...const [
          KeyHint('1', 'idea'),
          KeyHint('2', 'todo'),
          KeyHint('3', 'ask'),
          KeyHint('4', 'open app'),
          KeyHint('esc', 'hide'),
        ] else if (_asking) ...const [
          KeyHint('↵', 'ask'),
          KeyHint('⇧↵', 'newline'),
          KeyHint('⇧⌘C', 'copy answer'),
          KeyHint('⌘N', 'new chat'),
          KeyHint('⌘O', 'chats'),
          KeyHint('esc', 'hide'),
        ] else if (_notesFocus.hasFocus) ...const [
          KeyHint('↵', 'newline'),
          KeyHint('⌘↵', 'save'),
          KeyHint('⇧⇥', 'title'),
          KeyHint('esc', 'hide'),
        ] else ...[
          const KeyHint('↵', 'save'),
          if (_sel >= 0 && _sel < _shown.length && _shown[_sel].isTodo)
            const KeyHint('⌘D', 'done')
          else
            const KeyHint('⇥', 'description'),
          const KeyHint('↓', 'browse'),
          const KeyHint('esc', 'hide'),
        ],
      ],
    ),
  );
}

class GithubButton extends StatelessWidget {
  const GithubButton({required this.onPressed, this.compact = false, super.key});
  final VoidCallback onPressed;
  final bool compact;

  @override
  Widget build(BuildContext context) => FilledButton(
    onPressed: onPressed,
    style: FilledButton.styleFrom(
      backgroundColor: const Color(0xFFF0F1F4),
      foregroundColor: const Color(0xFF111111),
      minimumSize: compact ? null : const Size.fromHeight(44),
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: compact ? 10 : 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
      textStyle: TextStyle(fontWeight: FontWeight.w600, fontSize: compact ? 13 : 14),
    ),
    child: const Text('Continue with GitHub'),
  );
}
