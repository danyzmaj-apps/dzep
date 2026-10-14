import 'dart:async';

import 'package:dzep_core/account.dart';
import 'package:dzep_core/agent.dart';
import 'package:dzep_core/chat.dart';
import 'package:dzep_core/chat_view.dart';
import 'package:dzep_core/idea.dart';
import 'package:dzep_core/kitty.dart';
import 'package:dzep_core/logo.dart';
import 'package:dzep_core/native.dart';
import 'package:dzep_core/remind.dart';
import 'package:dzep_core/store.dart';
import 'package:dzep_core/ui.dart';
import 'package:dzep_macos/controller.dart';
import 'package:dzep_macos/integrations.dart';
import 'package:dzep_macos/onboarding/connect_ai.dart';
import 'package:dzep_macos/onboarding/pair.dart';
import 'package:dzep_macos/setup_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Sidebar selection: Todos, Ideas, Notes, Ask, or a project's ideas.
typedef Shelf = ({bool project, String id});

const Shelf _todos = (project: false, id: 'todos');
const Shelf _all = (project: false, id: 'all');
const Shelf _notes = (project: false, id: 'notes');
const Shelf _chats = (project: false, id: 'chats');

/// Drag strip for a transparent title bar (the main and the note window).
class TitleDrag extends StatelessWidget {
  const TitleDrag({super.key});

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onPanStart: (_) => unawaited(Native.startDrag()),
    child: const SizedBox(height: 28),
  );
}

class MainWindow extends StatelessWidget {
  const MainWindow({required this.app, super.key});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final store = app.store;
    return ColoredBox(
      color: C.win,
      child: Stack(
        children: [
          if (app.backend == null)
            SetupPage(session: app)
          else if (store == null)
            SignInPage(session: app)
          else
            Library(app: app, store: store),
          const Positioned(top: 0, left: 80, right: 0, child: TitleDrag()),
          if (store != null && app.settingsOpen) SettingsSheet(app: app),
        ],
      ),
    );
  }
}

// ==================================================================== library

class Library extends StatefulWidget {
  const Library({required this.app, required this.store, super.key});
  final AppController app;
  final IdeaStore store;

  @override
  State<Library> createState() => _LibraryState();
}

class _LibraryState extends State<Library> {
  Shelf _view = _all;
  String? _selId;
  String _query = '';

  /// Todos ticked off show under the open ones, folded by default.
  bool _showDone = false;
  String? _focusNotesOf;
  final _search = TextEditingController();

  /// The conversation shown in Chats; null for a new one.
  Conversation? _chat;

  /// Bumped by ⌘N in Chats, so even an empty new chat starts over, focused.
  int _newChats = 0;
  final _searchFocus = FocusNode();
  final _newIdea = TextEditingController();
  final _newFocus = FocusNode();
  late final _listFocus = FocusNode(onKeyEvent: _onKey);
  final _rowsScroll = ScrollController();

  /// On the selected row, to scroll it into view as ↑/↓ move.
  final GlobalKey _selRow = GlobalKey();

  IdeaStore get store => widget.store;

  /// Open whenever the idea store is (see Session).
  ChatStore get _chatStore => widget.app.chats!;

  @override
  void initState() {
    super.initState();
    _popupWasOpen = widget.app.popupOpen;
    widget.app
      ..addListener(_onPopup)
      ..addListener(_takePendingSelect);
    FocusManager.instance.addListener(_reclaim);
    _takePendingSelect();
    _listFocus.requestFocus();
  }

  @override
  void dispose() {
    widget.app
      ..removeListener(_onPopup)
      ..removeListener(_takePendingSelect);
    FocusManager.instance.removeListener(_reclaim);
    _search.dispose();
    _searchFocus.dispose();
    _newIdea.dispose();
    _newFocus.dispose();
    _listFocus.dispose();
    _rowsScroll.dispose();
    super.dispose();
  }

  bool _popupWasOpen = false;

  /// What had the focus in this window when the popup opened.
  FocusNode? _beforePopup;

  /// [focus] is a control in this window (not just a scope of it).
  bool _here(FocusNode? focus) {
    final at = focus?.context;
    return focus is! FocusScopeNode && at != null && at.mounted && View.maybeOf(at) == View.of(context);
  }

  /// The keyboard has nowhere to go in this window: no focus, the focus in
  /// the other window, or only on a scope around the list (a click outside
  /// a text field leaves it there), where the list's keys never see a key.
  /// A dialog's scope isn't around the list, so it keeps the focus.
  bool get _lost {
    final focus = FocusManager.instance.primaryFocus;
    final at = focus?.context;
    if (focus == null || at == null || !at.mounted || View.maybeOf(at) != View.of(context)) return true;
    return focus is FocusScopeNode && _listFocus.ancestors.contains(focus);
  }

  /// The popup and this window share one FocusManager, and macOS doesn't
  /// tell Flutter when a window becomes key: the popup takes the focus when
  /// it opens (and its route did at launch). What had it here then is kept
  /// for [_reclaim].
  void _onPopup() {
    final app = widget.app;
    if (app.popupOpen && !_popupWasOpen) {
      final focus = FocusManager.instance.primaryFocus;
      _beforePopup = _here(focus) ? focus : null;
    }
    _popupWasOpen = app.popupOpen;
    _reclaim();
  }

  /// While this window is open (and the popup and Settings aren't, and the
  /// note window doesn't have the keyboard), the keyboard always has
  /// somewhere to go here: what had the focus before the popup, or the list,
  /// so the window's keys work whatever was clicked.
  void _reclaim() {
    final app = widget.app;
    bool wanted() => mounted && app.mainOpen && !app.popupOpen && !app.noteKey && !app.settingsOpen && _lost;
    if (!wanted()) return;
    // A microtask: after the popup has let go of its focus, whichever of the
    // two heard of the close first, and outside the focus manager's update.
    scheduleMicrotask(() {
      if (!wanted()) return;
      final before = _beforePopup;
      _beforePopup = null;
      (before != null && _here(before) ? before : _listFocus).requestFocus();
    });
  }

  /// The popup asked to open a specific item, a list or a chat.
  void _takePendingSelect() {
    final app = widget.app;
    final chat = app.pendingChat;
    if (chat != null) {
      app.pendingChat = null;
      setState(() {
        _view = _chats;
        _chat = chat;
      });
    }
    if (app.pendingChats) {
      app.pendingChats = false;
      _beforePopup = null;
      _setView(_chats);
    }
    if (app.pendingConnectAi) {
      app.pendingConnectAi = false;
      _beforePopup = null;
      // After the frame that shows the window again.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(showConnectAi(context, app));
      });
    }
    final section = app.pendingSection;
    if (section != null) {
      app.pendingSection = null;
      _beforePopup = null;
      _setView(switch (section) {
        Kind.todo => _todos,
        Kind.note => _notes,
        Kind.idea => _all,
      });
    }
    final id = app.pendingSelect;
    if (id == null) return;
    app.pendingSelect = null;
    // Opened on another item: the list has the focus, not what had it.
    _beforePopup = null;
    final item = store.byId(id);
    if (item == null) return;
    setState(() {
      _view = switch (item.kind) {
        Kind.todo => _todos,
        Kind.note => _notes,
        Kind.idea => _all,
      };
      if (item.isTodo && item.done) _showDone = true;
      _query = '';
      _search.clear();
      _selId = id;
    });
  }

  bool get _todoView => _view == _todos;

  bool _inView(Idea i, Shelf v) => !v.project || i.project == v.id;

  bool _matches(Idea i) {
    final words = _query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    final hay = '${i.title} ${i.notes} @${i.project}'.toLowerCase();
    return words.every(hay.contains);
  }

  List<Idea> get _visible {
    if (_view == _chats) return const [];
    if (_view == _todos) {
      return [...store.openTodos.where(_matches), if (_showDone) ...store.doneTodos.where(_matches)];
    }
    if (_view == _notes) return store.notes.where(_matches).toList();
    return store.ideas.where((i) => _inView(i, _view) && _matches(i)).toList();
  }

  String _viewName(Shelf v) {
    if (v.project) return '@${v.id}';
    if (v == _todos) return 'Todos';
    if (v == _notes) return 'Notes';
    if (v == _chats) return 'Ask';
    return 'Ideas';
  }

  void _select(String? id) => setState(() => _selId = id);

  void _setView(Shelf v) {
    setState(() {
      _view = v;
      _selId = _visible.firstOrNull?.id;
      if (v == _chats) _chat = _chatStore.current ?? _chatStore.conversations.firstOrNull;
    });
  }

  void _toggleDone(Idea todo) {
    store.update(todo, done: !todo.done);
    Toaster.of(context).show(todo.done ? 'Done ✓' : 'Reopened', undo: () => store.update(todo, done: !todo.done));
  }

  void _delete(Idea i) {
    final v = _visible;
    final pos = v.indexOf(i);
    store.delete(i);
    final next = pos + 1 < v.length ? v[pos + 1] : (pos > 0 ? v[pos - 1] : null);
    setState(() => _selId = next?.id);
    Toaster.of(context).show(
      switch (i.kind) {
        Kind.todo => 'Todo deleted',
        Kind.note => 'Note deleted',
        Kind.idea => 'Idea deleted',
      },
      undo: () {
        store.restore(i);
        setState(() => _selId = i.id);
      },
    );
  }

  void _addFromField() {
    if (_view == _notes) {
      final text = _newIdea.text.trim();
      if (text.isEmpty) return;
      final note = store.addNote(text);
      _newIdea.clear();
      setState(() {
        _selId = note.id;
        _focusNotesOf = note.id;
      });
      return;
    }
    if (_todoView) {
      final parsed = parseReminder(_newIdea.text, DateTime.now());
      if (parsed.title.isEmpty) return;
      final todo = store.add(title: parsed.title, kind: Kind.todo, remindAt: parsed.at);
      _newIdea.clear();
      // Stay in the field: todos tend to come in batches.
      setState(() {
        _view = _todos;
        _selId = todo.id;
      });
      _newFocus.requestFocus();
      return;
    }
    final parsed = parseTitle(_newIdea.text);
    if (parsed.title.isEmpty) return;
    final idea = store.add(
      title: parsed.title,
      project: parsed.project.isNotEmpty ? parsed.project : (_view.project ? _view.id : ''),
    );
    _newIdea.clear();
    setState(() {
      if (!_view.project && _view.id != 'all') _view = _all;
      _selId = idea.id;
      _focusNotesOf = idea.id;
    });
  }

  // ---------------------------------------------------------------- keys

  /// The keyboard is in a text field: plain keys are the field's then.
  static bool get _typing {
    final context = FocusManager.instance.primaryFocus?.context;
    return context != null && context.findAncestorStateOfType<EditableTextState>() != null;
  }

  /// The window's keys, seen after whatever has focus passed on them: ⌘N
  /// the section's new field, ⌘F or / the search, ⌫ deletes the selected
  /// item, ↑/↓ move the selection, Esc clears the search and leaves a field
  /// for the list. Plain keys only while no text field has focus.
  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is KeyUpEvent || widget.app.settingsOpen) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    final k = e.logicalKey;
    final mods = keys.isShiftPressed || keys.isAltPressed || keys.isControlPressed;
    final cmd = keys.isMetaPressed && !mods;
    final plain = !keys.isMetaPressed && !mods;
    final chats = _view == _chats;
    final typing = _typing;
    if (cmd && k == LogicalKeyboardKey.keyN) {
      if (chats) {
        setState(() {
          _chat = null;
          _newChats++;
        });
      } else {
        _newFocus.requestFocus();
      }
      return KeyEventResult.handled;
    }
    if (chats) return KeyEventResult.ignored;
    if (cmd && k == LogicalKeyboardKey.keyF || plain && !typing && e.character == '/') {
      _searchFocus.requestFocus();
      _search.selection = TextSelection(baseOffset: 0, extentOffset: _search.text.length);
      return KeyEventResult.handled;
    }
    if (plain && k == LogicalKeyboardKey.escape) {
      // In the search, the first Esc clears it and the next one leaves.
      if (_query.isNotEmpty && (!typing || _searchFocus.hasFocus)) {
        _clearSearch();
      } else if (typing) {
        _listFocus.requestFocus();
      } else {
        return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    }
    if (typing) return KeyEventResult.ignored;
    if ((plain || cmd) && (k == LogicalKeyboardKey.backspace || k == LogicalKeyboardKey.delete)) {
      final selected = _selId == null ? null : store.byId(_selId!);
      if (selected == null) return KeyEventResult.ignored;
      _delete(selected);
      return KeyEventResult.handled;
    }
    if (plain && (k == LogicalKeyboardKey.arrowDown || k == LogicalKeyboardKey.arrowUp)) {
      _move(k == LogicalKeyboardKey.arrowDown ? 1 : -1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _clearSearch() {
    _search.clear();
    setState(() {
      _query = '';
      if (!_visible.any((i) => i.id == _selId)) _selId = _visible.firstOrNull?.id;
    });
  }

  /// Selects the row [by] rows away (the first or last one if none is), and
  /// scrolls it into view.
  void _move(int by) {
    final rows = _visible;
    if (rows.isEmpty) return;
    final at = rows.indexWhere((i) => i.id == _selId);
    _select(rows[at < 0 ? (by > 0 ? 0 : rows.length - 1) : (at + by).clamp(0, rows.length - 1)].id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final row = _selRow.currentContext;
      if (row == null || !row.mounted) return;
      Scrollable.ensureVisible(
        row,
        alignmentPolicy: by > 0
            ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
            : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      );
    });
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([store, _chatStore]),
    builder: (context, _) {
      final visible = _visible;
      if (_selId != null && store.byId(_selId!) == null) _selId = null;
      final selected = _selId == null ? null : store.byId(_selId!);
      final chat = _chatStore;
      if (_chat != null && !chat.conversations.contains(_chat)) _chat = chat.conversations.firstOrNull;
      final chats = _view == _chats;
      return LayoutBuilder(
        builder: (context, size) {
          // Narrow, the sidebar folds into a strip of icons and the list
          // gives up width before the detail does.
          final rail = size.maxWidth < 760;
          final side = rail ? 52.0 : 210.0;
          final list = ((size.maxWidth - side) * .42).clamp(220.0, 370.0);
          return Focus(
            focusNode: _listFocus,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: side,
                  child: _sidebar(rail: rail),
                ),
                const VerticalDivider(width: 1, color: C.line),
                SizedBox(
                  width: list,
                  child: chats
                      ? ChatList(
                          chat: chat,
                          selected: _chat,
                          onSelect: (c) => setState(() => _chat = c),
                          hotKey: widget.app.hotKey.label,
                        )
                      : _listPane(visible),
                ),
                const VerticalDivider(width: 1, color: C.line),
                Expanded(
                  child: chats
                      ? ChatThread(
                          key: ValueKey((_chat?.id, _newChats)),
                          chat: chat,
                          conversation: _chat,
                          onSent: (c) => setState(() => _chat = c),
                          onContinue: (c) => unawaited(widget.app.openAsk(c)),
                          onConnectAi: () => unawaited(showConnectAi(context, widget.app)),
                        )
                      : selected == null
                      ? const _EmptyDetail()
                      : selected.isNote
                      ? NoteEditor(
                          key: ValueKey(selected.id),
                          note: selected,
                          store: store,
                          focus: _focusNotesOf == selected.id,
                          onFocused: () => _focusNotesOf = null,
                          onDelete: () => _delete(selected),
                          onWindow: () => unawaited(widget.app.openNoteWindow(id: selected.id, fromMain: true)),
                        )
                      : _Detail(
                          key: ValueKey(selected.id),
                          idea: selected,
                          store: store,
                          viewName: _viewName(_view),
                          focus: _focusNotesOf == selected.id
                              ? _DetailFocus.notes
                              : _focusNotesOf == '${selected.id}#title'
                              ? _DetailFocus.title
                              : null,
                          onFocused: () => _focusNotesOf = null,
                          onToggleDone: () => _toggleDone(selected),
                          onDelete: () => _delete(selected),
                          onDone: _listFocus.requestFocus,
                        ),
                ),
              ],
            ),
          );
        },
      );
    },
  );

  /// [rail]: icons only (a narrow window), each named in its tooltip.
  Widget _sidebar({required bool rail}) {
    Widget nav(Shelf v, Widget icon, String name) {
      final n = v == _todos
          ? store.openTodos.length
          : v == _notes
          ? store.notes.length
          : v == _chats
          ? _chatStore.conversations.length
          : store.ideas.where((i) => _inView(i, v)).length;
      final on = _view == v;
      final item = Hoverable(
        onTap: () => _setView(v),
        builder: (hover) => Container(
          margin: EdgeInsets.symmetric(horizontal: rail ? 6 : 8),
          padding: EdgeInsets.symmetric(horizontal: 10, vertical: rail ? 7 : 5),
          decoration: BoxDecoration(
            color: on ? C.sel : (hover ? C.hover : null),
            borderRadius: BorderRadius.circular(6),
          ),
          child: rail
              ? Center(child: icon)
              : Row(
                  children: [
                    SizedBox(width: 16, child: Center(child: icon)),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        name,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, color: on ? Colors.white : const Color(0xFFC9CCD5)),
                      ),
                    ),
                    if (n > 0) Text('$n', style: const TextStyle(fontSize: 11, color: C.dim2)),
                  ],
                ),
        ),
      );
      return rail ? Tooltip(message: n > 0 ? '$name  $n' : name, child: item) : item;
    }

    Widget header(String t) => rail
        ? const Padding(
            padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Divider(height: 1, color: C.line),
          )
        : Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 10, 4),
            child: Text(
              t,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: C.dim2),
            ),
          );

    // On the rail a project is its first two letters (the tooltip names it).
    Widget projectIcon(String p) => rail
        ? Text(
            '${p.characters.take(1).toUpperCase()}${p.characters.skip(1).take(1)}',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: C.dim),
          )
        : const Icon(Icons.tag, size: 13, color: C.dim);

    final user = widget.app;
    final settings = IconButton(
      tooltip: 'Settings  ⌘,',
      iconSize: 16,
      color: C.dim,
      onPressed: () => user.setSettingsOpen(open: true),
      icon: const Icon(Icons.settings_outlined),
    );
    return ColoredBox(
      color: C.side,
      child: Column(
        children: [
          const SizedBox(height: 44),
          Expanded(
            child: ListView(
              children: [
                nav(_todos, const Icon(Icons.check_circle_outline, size: 14, color: C.dim), 'Todos'),
                nav(_all, const Icon(Icons.lightbulb_outline, size: 14, color: C.dim), 'Ideas'),
                nav(_notes, const Icon(Icons.sticky_note_2_outlined, size: 14, color: C.dim), 'Notes'),
                nav(_chats, const Icon(Icons.auto_awesome, size: 14, color: C.dim), 'Ask'),
                if (store.projects.isNotEmpty) header('PROJECTS'),
                for (final p in store.projects) nav((project: true, id: p), projectIcon(p), p),
              ],
            ),
          ),
          Container(
            padding: rail ? const EdgeInsets.symmetric(vertical: 8) : const EdgeInsets.fromLTRB(12, 10, 8, 10),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: C.line)),
            ),
            child: rail
                ? Column(
                    children: [
                      Tooltip(
                        message: user.userName,
                        child: Avatar(url: user.avatarUrl, name: user.userName),
                      ),
                      settings,
                    ],
                  )
                : Row(
                    children: [
                      Avatar(url: user.avatarUrl, name: user.userName),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(user.userName, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                            SyncDot(store.syncState),
                          ],
                        ),
                      ),
                      settings,
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _listPane(List<Idea> visible) {
    final rows = <Widget>[];
    String? group;
    for (final i in visible) {
      if (i.isTodo && i.done) continue;
      final g = _group(i.isNote ? i.updatedAt : i.createdAt);
      if (g != group) {
        group = g;
        rows.add(_groupHeader(g));
      }
      rows.add(_row(i));
    }
    if (_todoView) {
      final done = store.doneTodos.where(_matches).length;
      if (done > 0) {
        rows.add(
          Hoverable(
            onTap: () => setState(() => _showDone = !_showDone),
            builder: (hover) => Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Row(
                children: [
                  Icon(_showDone ? Icons.expand_more : Icons.chevron_right, size: 15, color: C.dim2),
                  const SizedBox(width: 4),
                  Text(
                    'Done · $done',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: hover ? C.text : C.dim2),
                  ),
                ],
              ),
            ),
          ),
        );
        if (_showDone) {
          rows.addAll([
            for (final i in visible)
              if (i.isTodo && i.done) _row(i),
          ]);
        }
      }
    }
    final count = visible.where((i) => !(i.isTodo && i.done)).length;
    final noun = switch (_view) {
      _todos => 'open',
      _notes => count == 1 ? 'note' : 'notes',
      _ => count == 1 ? 'idea' : 'ideas',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 40, 16, 10),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: C.line)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text.rich(
                TextSpan(
                  text: _viewName(_view),
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  children: [
                    TextSpan(
                      text: '   $count $noun',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w400, color: C.dim),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color: C.field,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: C.line2),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.search, size: 15, color: C.dim),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _search,
                        focusNode: _searchFocus,
                        style: const TextStyle(fontSize: 13),
                        decoration: plainInput.copyWith(
                          hintText: 'Search',
                          hintStyle: const TextStyle(color: C.dim2),
                        ),
                        onChanged: (q) => setState(() {
                          _query = q;
                          if (!_visible.any((i) => i.id == _selId)) _selId = _visible.firstOrNull?.id;
                        }),
                        onSubmitted: (_) => _listFocus.requestFocus(),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: C.line)),
          ),
          child: Row(
            children: [
              const Text('＋', style: TextStyle(color: C.dim)),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _newIdea,
                  focusNode: _newFocus,
                  style: const TextStyle(fontSize: 13),
                  decoration: plainInput.copyWith(
                    hintText: switch (_view) {
                      _todos => 'New todo…  !15:00  ↵',
                      _notes => 'New note…  ↵ then keep writing',
                      _ => 'New idea…  ↵',
                    },
                    hintStyle: const TextStyle(color: C.dim2),
                  ),
                  onSubmitted: (_) => _addFromField(),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: visible.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(30),
                  child: Text(
                    _query.isNotEmpty
                        ? 'No matches.'
                        : switch (_view) {
                            _todos => 'All done 🎉\n${widget.app.hotKey.label} then ⌘2 adds a todo from anywhere.',
                            _notes => 'No notes yet.\n${widget.app.hotKey.label} then ⌘3 writes one from anywhere.',
                            _all => 'No ideas yet.\n${widget.app.hotKey.label} then ⌘1 adds one from anywhere.',
                            _ => 'Nothing here yet.',
                          },
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: C.dim),
                  ),
                )
              : ListView(controller: _rowsScroll, children: rows),
        ),
      ],
    );
  }

  Widget _row(Idea i) {
    final on = i.id == _selId;
    final faded = i.isTodo && i.done;
    final struck = faded;
    final titleStyle = TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w500,
      color: faded ? C.dim : C.text,
      decoration: struck ? TextDecoration.lineThrough : null,
      decorationColor: C.dim,
    );
    // A note's title is its first line; the next one is the preview.
    final preview = i.isNote
        ? i.notes.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).skip(1).firstOrNull ?? ''
        : i.notes.split('\n').first;
    return Hoverable(
      key: on ? _selRow : null,
      onTap: () {
        _select(i.id);
        _listFocus.requestFocus();
      },
      builder: (hover) => Container(
        padding: const EdgeInsets.fromLTRB(14, 9, 16, 9),
        decoration: BoxDecoration(
          color: on ? C.sel : (hover ? C.hover : null),
          border: Border(left: BorderSide(color: on ? C.accent : Colors.transparent, width: 2)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (i.isTodo)
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: GestureDetector(
                  onTap: () => _toggleDone(i),
                  child: TodoCheck(done: i.done),
                ),
              )
            else if (i.isNote)
              const Padding(
                padding: EdgeInsets.only(top: 1),
                child: Icon(Icons.notes, size: 14, color: C.dim),
              )
            else
              const Padding(padding: EdgeInsets.only(top: 5), child: Dot(C.dim)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    highlight(i.title.isEmpty ? (i.isNote ? 'Empty note' : 'Untitled') : i.title, _query, titleStyle),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (preview.isNotEmpty)
                    Text.rich(
                      highlight(preview, _query, const TextStyle(fontSize: 12, color: C.dim)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  if (i.project.isNotEmpty)
                    Padding(padding: const EdgeInsets.only(top: 4), child: ProjectChip(i.project)),
                  if (i.remindAt case final at? when !i.done)
                    Padding(padding: const EdgeInsets.only(top: 4), child: ReminderChip(at)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(stamp(i.isNote ? i.updatedAt : i.createdAt), style: const TextStyle(fontSize: 11, color: C.dim2)),
          ],
        ),
      ),
    );
  }

  Widget _groupHeader(String g) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Text(
      g,
      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: C.dim2),
    ),
  );

  static String _group(DateTime t) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final local = t.toLocal();
    final day = DateTime(local.year, local.month, local.day);
    final d = today.difference(day).inDays;
    if (d < 1) return 'Today';
    if (d < 2) return 'Yesterday';
    if (d < 7) return 'This week';
    return 'Earlier';
  }
}

// ==================================================================== detail

class _EmptyDetail extends StatelessWidget {
  const _EmptyDetail();

  @override
  Widget build(BuildContext context) => const Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Opacity(opacity: .35, child: DzepLogo(size: 52)),
        SizedBox(height: 8),
        Text('Nothing selected', style: TextStyle(color: C.dim)),
      ],
    ),
  );
}

/// A note, the whole of it in one editor: the first line is its title. Saved
/// as it's typed, like any other edit.
class NoteEditor extends StatefulWidget {
  const NoteEditor({
    required this.note,
    required this.store,
    required this.focus,
    required this.onFocused,
    required this.onDelete,
    required this.onWindow,
    super.key,
  });

  final Idea note;
  final IdeaStore store;

  /// Just created: the cursor goes on a new line under the first.
  final bool focus;
  final VoidCallback onFocused;
  final VoidCallback onDelete;

  /// Opens the note in the note window (lib/note_window.dart).
  final VoidCallback onWindow;

  @override
  State<NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends State<NoteEditor> {
  late final _text = TextEditingController(text: widget.note.notes);
  final _focus = FocusNode();

  Idea get note => widget.note;

  @override
  void initState() {
    super.initState();
    if (widget.focus) {
      if (!_text.text.endsWith('\n')) _text.text += '\n';
      _text.selection = TextSelection.collapsed(offset: _text.text.length);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _focus.requestFocus();
        widget.onFocused();
      });
    }
  }

  @override
  void didUpdateWidget(NoteEditor old) {
    super.didUpdateWidget(old);
    // Edited on another device: show it unless it's being typed in here.
    if (!_focus.hasFocus && _text.text != note.notes) _text.text = note.notes;
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Container(
        padding: const EdgeInsets.fromLTRB(14, 34, 10, 8),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: C.line)),
        ),
        child: Row(
          children: [
            Expanded(child: _Crumb('Notes', note.title.isEmpty ? 'Empty note' : note.title)),
            IconButton(
              tooltip: 'Open in its own window',
              iconSize: 15,
              color: C.dim,
              icon: const Icon(Icons.picture_in_picture_alt_outlined),
              onPressed: widget.onWindow,
            ),
            IconButton(
              tooltip: 'Copy',
              iconSize: 15,
              color: C.dim,
              icon: const Icon(Icons.copy_outlined),
              onPressed: () {
                unawaited(Clipboard.setData(ClipboardData(text: note.notes.trim())));
                Toaster.of(context).show('Copied');
              },
            ),
            IconButton(
              tooltip: 'Delete  ⌫',
              iconSize: 15,
              color: C.dim,
              icon: const Icon(Icons.delete_outline),
              onPressed: widget.onDelete,
            ),
          ],
        ),
      ),
      Expanded(
        child: GestureDetector(
          // A click below the text still lands in the editor.
          behavior: HitTestBehavior.translucent,
          onTap: _focus.requestFocus,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(34, 26, 34, 26),
            child: TextField(
              controller: _text,
              focusNode: _focus,
              selectAllOnFocus: false,
              selectionWidthStyle: selectionWidth,
              maxLines: null,
              keyboardType: TextInputType.multiline,
              style: const TextStyle(fontSize: 15, height: 1.65, color: Color(0xFFD7DAE2)),
              decoration: plainInput.copyWith(
                hintText: 'Write anything. The first line is the title.',
                hintStyle: const TextStyle(color: C.dim2),
              ),
              onChanged: (t) => widget.store.editNote(note, t),
            ),
          ),
        ),
      ),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 34, vertical: 8),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: C.line)),
        ),
        child: Text(
          'Edited ${stamp(note.updatedAt)} · added ${stamp(note.createdAt)}'
          '${note.device.isEmpty ? '' : ' on ${note.device}'}',
          style: const TextStyle(fontSize: 11, color: C.dim2),
        ),
      ),
    ],
  );
}

/// A detail header's "Notes › title"; just the title once the pane is too
/// narrow for both.
class _Crumb extends StatelessWidget {
  const _Crumb(this.section, this.title);
  final String section;
  final String title;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, size) => Text.rich(
      TextSpan(
        children: [
          if (size.maxWidth >= 160)
            TextSpan(
              text: '$section  ›  ',
              style: const TextStyle(color: C.dim),
            ),
          TextSpan(text: title),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 13),
    ),
  );
}

enum _DetailFocus { title, notes }

class _Detail extends StatefulWidget {
  const _Detail({
    required this.idea,
    required this.store,
    required this.viewName,
    required this.focus,
    required this.onFocused,
    required this.onToggleDone,
    required this.onDelete,
    required this.onDone,
    super.key,
  });

  final Idea idea;
  final IdeaStore store;
  final String viewName;
  final _DetailFocus? focus;
  final VoidCallback onFocused;
  final VoidCallback onToggleDone;
  final VoidCallback onDelete;
  final VoidCallback onDone;

  @override
  State<_Detail> createState() => _DetailState();
}

class _DetailState extends State<_Detail> {
  late final _title = TextEditingController(text: widget.idea.title);
  late final _notes = TextEditingController(text: widget.idea.notes);
  late final _project = TextEditingController(text: widget.idea.project);
  final _remind = TextEditingController();
  final _titleFocus = FocusNode();
  final _notesFocus = FocusNode();
  final _projectFocus = FocusNode();

  Idea get idea => widget.idea;

  @override
  void initState() {
    super.initState();
    _projectFocus.addListener(() {
      if (!_projectFocus.hasFocus) _commitProject();
    });
    _applyFocus();
  }

  @override
  void didUpdateWidget(_Detail old) {
    super.didUpdateWidget(old);
    _applyFocus();
    // Synced from another Mac while open: show it unless it's being typed in.
    if (!_titleFocus.hasFocus && _title.text != idea.title) _title.text = idea.title;
    if (!_notesFocus.hasFocus && _notes.text != idea.notes) _notes.text = idea.notes;
    if (!_projectFocus.hasFocus && _project.text != idea.project) _project.text = idea.project;
  }

  void _applyFocus() {
    final f = widget.focus;
    if (f == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      (f == _DetailFocus.notes ? _notesFocus : _titleFocus).requestFocus();
      widget.onFocused();
    });
  }

  void _commitProject() {
    final p = _project.text.trim().replaceFirst(RegExp('^@'), '');
    if (p != idea.project) widget.store.update(idea, project: p);
  }

  @override
  void dispose() {
    if (_projectFocus.hasFocus) _commitProject();
    _title.dispose();
    _notes.dispose();
    _project.dispose();
    _remind.dispose();
    _titleFocus.dispose();
    _notesFocus.dispose();
    _projectFocus.dispose();
    super.dispose();
  }

  String _date(DateTime t) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final l = t.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.day} ${months[l.month - 1]} ${two(l.hour)}:${two(l.minute)}';
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Container(
        padding: const EdgeInsets.fromLTRB(14, 34, 10, 8),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: C.line)),
        ),
        child: Row(
          children: [
            Expanded(child: _Crumb(widget.viewName, idea.title.isEmpty ? 'Untitled' : idea.title)),
            IconButton(
              tooltip: 'Copy as Markdown',
              iconSize: 15,
              color: C.dim,
              icon: const Icon(Icons.copy_outlined),
              onPressed: () {
                unawaited(Clipboard.setData(ClipboardData(text: '# ${idea.title}\n\n${idea.notes}'.trim())));
                Toaster.of(context).show('Copied as Markdown');
              },
            ),
            IconButton(
              tooltip: 'Delete  ⌫',
              iconSize: 15,
              color: C.dim,
              icon: const Icon(Icons.delete_outline),
              onPressed: widget.onDelete,
            ),
          ],
        ),
      ),
      Expanded(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(34, 26, 34, 26),
          children: [
            CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.enter): _notesFocus.requestFocus,
                const SingleActivator(LogicalKeyboardKey.arrowDown): _notesFocus.requestFocus,
              },
              child: TextField(
                controller: _title,
                focusNode: _titleFocus,
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600, letterSpacing: -.2),
                decoration: plainInput.copyWith(
                  hintText: 'Untitled idea',
                  hintStyle: const TextStyle(color: C.dim2),
                ),
                onChanged: (t) => widget.store.update(idea, title: t),
              ),
            ),
            const SizedBox(height: 16),
            if (idea.isTodo)
              _prop(
                'Todo',
                _SegButton(
                  on: idea.done,
                  onTap: widget.onToggleDone,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TodoCheck(done: idea.done, size: 14),
                      const SizedBox(width: 8),
                      Text(idea.done ? 'Done' : 'Mark done', style: const TextStyle(fontSize: 12)),
                    ],
                  ),
                ),
              )
            else
              _prop('Project', _projectField()),
            if (idea.isTodo && !idea.done) ...[const SizedBox(height: 10), _prop('Remind', _remindField())],
            const SizedBox(height: 22),
            TextField(
              controller: _notes,
              focusNode: _notesFocus,
              selectionWidthStyle: selectionWidth,
              maxLines: null,
              minLines: 12,
              style: const TextStyle(fontSize: 14, height: 1.65, color: Color(0xFFD7DAE2)),
              decoration: plainInput.copyWith(
                hintText: 'Description: context, links, how it could work…',
                hintStyle: const TextStyle(color: C.dim2),
              ),
              onChanged: (t) => widget.store.update(idea, notes: t),
            ),
          ],
        ),
      ),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 34, vertical: 8),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: C.line)),
        ),
        child: Text(
          'Added ${_date(idea.createdAt)}${idea.device.isEmpty ? '' : ' on ${idea.device}'}',
          style: const TextStyle(fontSize: 11, color: C.dim2),
        ),
      ),
    ],
  );

  Widget _prop(String label, Widget value) => Row(
    children: [
      SizedBox(
        width: 80,
        child: Text(label, style: const TextStyle(fontSize: 12, color: C.dim)),
      ),
      Flexible(
        child: Align(alignment: Alignment.centerLeft, child: value),
      ),
    ],
  );

  /// The `!` syntax without the `!` (`15:00`, `3pm`, `tomorrow 9`,
  /// `mon 14:30`, `2h`): ↵ sets the reminder, × clears it.
  Widget _remindField() => Wrap(
    spacing: 4,
    runSpacing: 6,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      if (idea.remindAt case final at?) ...[
        ReminderChip(at),
        IconButton(
          tooltip: 'Clear reminder',
          iconSize: 13,
          color: C.dim,
          icon: const Icon(Icons.close),
          onPressed: () => widget.store.update(idea, remind: (at: null)),
        ),
      ],
      Container(
        width: 200,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: C.field,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: C.line2),
        ),
        child: TextField(
          controller: _remind,
          style: const TextStyle(fontSize: 12),
          decoration: plainInput.copyWith(
            hintText: '${idea.remindAt == null ? 'none' : 'change'}: 15:00, tomorrow 9, 2h',
            hintStyle: const TextStyle(color: C.dim2),
          ),
          onSubmitted: (_) => _commitRemind(),
        ),
      ),
    ],
  );

  void _commitRemind() {
    final spec = _remind.text.trim().replaceFirst(RegExp('^!'), '');
    if (spec.isNotEmpty) {
      final at = parseWhen(spec, DateTime.now());
      if (at == null) {
        Toaster.of(context).show('Try 15:00, 3pm, tomorrow 9, mon 14:30 or 2h');
        return;
      }
      widget.store.update(idea, remind: (at: at));
      _remind.clear();
    }
    widget.onDone();
  }

  Widget _projectField() => RawAutocomplete<String>(
    textEditingController: _project,
    focusNode: _projectFocus,
    optionsBuilder: (v) {
      final q = v.text.replaceFirst('@', '').toLowerCase();
      return widget.store.projects.where((p) => p != v.text && p.toLowerCase().contains(q));
    },
    onSelected: (p) {
      _project.text = p;
      _commitProject();
    },
    fieldViewBuilder: (context, controller, focus, onSubmit) => Container(
      width: 220,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: C.field,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: C.line2),
      ),
      child: TextField(
        controller: controller,
        focusNode: focus,
        style: const TextStyle(fontSize: 12),
        decoration: plainInput.copyWith(
          hintText: 'none: type a project',
          hintStyle: const TextStyle(color: C.dim2),
        ),
        onSubmitted: (_) {
          onSubmit();
          _commitProject();
          widget.onDone();
        },
      ),
    ),
    optionsViewBuilder: (context, onSelected, options) => Align(
      alignment: Alignment.topLeft,
      child: Material(
        color: C.bar,
        elevation: 8,
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220, maxHeight: 200),
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 4),
            shrinkWrap: true,
            children: [
              for (final p in options)
                Hoverable(
                  onTap: () => onSelected(p),
                  builder: (h) => Container(
                    color: h ? C.sel : null,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    child: Text('@$p', style: const TextStyle(fontSize: 12)),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _SegButton extends StatelessWidget {
  const _SegButton({required this.on, required this.onTap, required this.child});
  final bool on;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => Hoverable(
    onTap: onTap,
    builder: (hover) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: on ? const Color(0xFF2A2E3B) : (hover ? C.hover : C.field),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: on ? C.line2 : C.line),
      ),
      child: DefaultTextStyle.merge(
        style: TextStyle(color: on ? C.text : C.dim),
        child: child,
      ),
    ),
  );
}

// ==================================================================== settings

class SettingsSheet extends StatefulWidget {
  const SettingsSheet({required this.app, this.integrations, super.key});
  final AppController app;

  /// Installs the coding agents' Džep integrations; the real ones if null.
  final Integrations? integrations;

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  bool _recording = false;
  String? _hotKeyError;
  bool? _launchAtLogin;
  String? _launchError;

  /// kitty as the bridge would find it: its window count, or what's wrong.
  ({int? windows, String? error})? _kitty;

  /// The chosen coding agent's Džep integration, and how installing it went.
  IntegrationState? _integration;
  String? _installNote;
  bool _installFailed = false;

  /// Claude Code has mods off, so its installed plugin doesn't run
  /// ([Integrations.claudeModsOff]).
  bool _modsOff = false;
  bool _installing = false;
  late final Integrations _integrations = widget.integrations ?? Integrations();
  final _recorderFocus = FocusNode();

  /// What had the focus in this window before Settings: it gets it back.
  FocusNode? _before;

  AppController get app => widget.app;

  @override
  void initState() {
    super.initState();
    unawaited(Native.launchAtLogin().then((v) => mounted ? setState(() => _launchAtLogin = v) : null));
    unawaited(_checkKitty());
    unawaited(_checkIntegration());
    unawaited(app.chats?.checkAi());
    // Taken even from a focused field (autofocus wouldn't), so Esc closes
    // Settings and typing doesn't go into the field behind it.
    _before = FocusManager.instance.primaryFocus;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _recorderFocus.requestFocus();
      if (_before?.enclosingScope != _recorderFocus.enclosingScope) _before = null;
    });
  }

  Future<void> _checkKitty() async {
    ({int? windows, String? error}) r;
    try {
      r = (windows: (await app.kitty.windows()).length, error: null);
    } on KittyException catch (e) {
      r = (windows: null, error: e.message);
    }
    if (mounted) setState(() => _kitty = r);
  }

  Future<void> _checkIntegration() async {
    final agent = app.codingAgent;
    IntegrationState r;
    var modsOff = false;
    try {
      r = await _integrations.state(agent);
      if (agent == Agent.claude && r.installed) modsOff = await _integrations.claudeModsOff();
    } on Object catch (e) {
      r = (installed: false, current: false, problem: '$e');
    }
    if (mounted && agent == app.codingAgent) {
      setState(() {
        _integration = r;
        _modsOff = modsOff;
      });
    }
  }

  /// What to do while Claude Code has mods off: its rollout switch stays
  /// cached as off until Claude Code, logged in, fetches it again.
  static const _modsOffHint =
      'Claude Code has mods turned off for now: run claude /login, start claude once, '
      'then restart your Claude sessions';

  Future<void> _setAgent(Agent agent) async {
    if (agent == app.codingAgent) return;
    setState(() {
      _integration = _installNote = null;
      _installFailed = _modsOff = false;
    });
    await app.setCodingAgent(agent);
    await _checkIntegration();
  }

  Future<void> _install() async {
    final agent = app.codingAgent;
    setState(() => _installing = true);
    String? error;
    try {
      await _integrations.install(agent);
    } on Object catch (e) {
      error = "Couldn't install: $e";
    }
    if (!mounted) return;
    // Whether it runs: mods may be off.
    if (error == null) await _checkIntegration();
    if (!mounted) return;
    // Settings may have moved on to the other agent meanwhile.
    if (agent != app.codingAgent) return setState(() => _installing = false);
    setState(() {
      _installing = false;
      _installNote =
          error ??
          (_modsOff ? 'Installed · $_modsOffHint' : 'Installed · restart your ${agent.label} sessions to load it');
      _installFailed = error != null || _modsOff;
    });
    if (error != null) await _checkIntegration();
  }

  /// Where the chosen agent's integration stands, for its row.
  String get _integrationSub {
    final s = _integration;
    if (s == null) return 'Checking…';
    if (s.problem case final p?) return p;
    if (!s.installed) return 'Not installed · /idea, /do, /note and its sessions on your phone need it';
    if (_modsOff) return _modsOffHint;
    return s.current ? 'Installed and up to date' : 'Out of date';
  }

  @override
  void dispose() {
    _recorderFocus.dispose();
    final before = _before;
    if (before != null && before.context != null) before.requestFocus();
    super.dispose();
  }

  KeyEventResult _onRecordKey(FocusNode _, KeyEvent e) {
    if (!_recording || e is! KeyDownEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      setState(() => _recording = false);
      return KeyEventResult.handled;
    }
    final key = HotKey.fromEvent(e);
    if (key == null) return KeyEventResult.handled; // still waiting for a combo with ⌘/⌥/⌃
    setState(() => _recording = false);
    unawaited(
      app.setHotKey(key).then((ok) {
        if (mounted) setState(() => _hotKeyError = ok ? null : '${key.label} is taken by another app.');
      }),
    );
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: GestureDetector(
      onTap: () => app.setSettingsOpen(open: false),
      child: ColoredBox(
        color: const Color(0x99000000),
        child: Center(
          // Scrolls in a window too short for it.
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: GestureDetector(
              onTap: () {},
              child: Container(
                constraints: const BoxConstraints(maxWidth: 500),
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
                decoration: BoxDecoration(
                  color: C.win,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: C.line2),
                  boxShadow: const [BoxShadow(color: Color(0x99000000), blurRadius: 60, offset: Offset(0, 20))],
                ),
                child: Focus(
                  focusNode: _recorderFocus,
                  onKeyEvent: (n, e) {
                    if (!_recording && e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
                      app.setSettingsOpen(open: false);
                      return KeyEventResult.handled;
                    }
                    return _onRecordKey(n, e);
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Center(
                        child: Text('Settings', style: TextStyle(fontWeight: FontWeight.w600)),
                      ),
                      _group('ACCOUNT', [
                        _row(
                          leading: Avatar(url: app.avatarUrl, name: app.userName),
                          label: app.userName,
                          sub: 'Signed in with GitHub · ${_count(app.store?.ideas.length ?? 0, 'idea')}',
                          trailing: _button('Sign out', () => unawaited(app.signOut()), danger: true),
                        ),
                        _row(
                          label: 'Your server',
                          sub: '${app.backend?.host ?? ''} · Scan a code with your phone to connect it',
                          trailing: _button('Set up phone…', () => unawaited(showPairingQr(context, app))),
                        ),
                        ListenableBuilder(
                          listenable: app.chats!,
                          builder: (context, _) {
                            final ai = app.chats!.ai;
                            final connected = ai?.connected ?? false;
                            return _row(
                              label: 'AI',
                              sub: switch (ai) {
                                AiStatus(connected: true, :final model?, :final baseUrl?) =>
                                  'Ask uses $model · ${Uri.tryParse(baseUrl)?.host ?? baseUrl}',
                                AiStatus(connected: false) => 'Not connected · Ask needs an AI to answer',
                                _ => 'Ask answers with an AI service you choose',
                              },
                              trailing: _button(
                                connected ? 'Change…' : 'Connect…',
                                () => unawaited(showConnectAi(context, app)),
                              ),
                            );
                          },
                        ),
                        _row(
                          label: 'Delete account',
                          sub: 'Removes everything you saved, on every device',
                          trailing: _button('Delete…', () async {
                            if (!await confirmDeleteAccount(context)) return;
                            try {
                              await app.deleteAccount();
                            } on Object catch (e) {
                              if (context.mounted) Toaster.of(context).show('Account not deleted: $e');
                            }
                          }, danger: true),
                        ),
                      ]),
                      _group('GENERAL', [
                        _row(
                          label: 'Quick capture shortcut',
                          sub:
                              _hotKeyError ??
                              (app.hotKeyRegistered
                                  ? 'Click, then press the new combo'
                                  : '${app.hotKey.label} is taken by another app.'),
                          subError: _hotKeyError != null || !app.hotKeyRegistered,
                          trailing: _button(_recording ? 'Press keys…' : app.hotKey.label, () {
                            setState(() {
                              _recording = !_recording;
                              _hotKeyError = null;
                            });
                            _recorderFocus.requestFocus();
                          }, active: _recording),
                        ),
                        _row(
                          label: 'Launch at login',
                          sub: _launchError,
                          subError: _launchError != null,
                          trailing: Switch(
                            value: _launchAtLogin ?? false,
                            onChanged: _launchAtLogin == null
                                ? null
                                : (v) => unawaited(
                                    Native.setLaunchAtLogin(enabled: v).then(
                                      (r) => mounted
                                          ? setState(() {
                                              _launchAtLogin = r;
                                              _launchError = null;
                                            })
                                          : null,
                                      onError: (Object e) => mounted
                                          ? setState(() => _launchError = e is PlatformException ? e.message : '$e')
                                          : null,
                                    ),
                                  ),
                          ),
                        ),
                        _row(
                          label: 'Terminal from phone',
                          sub: !app.terminalOn
                              ? 'Your phone sees and types into kitty and coding sessions while this Mac is awake'
                              : _kitty?.error ??
                                    (_kitty == null
                                        ? 'Looking for kitty…'
                                        : '${_count(_kitty!.windows ?? 0, 'kitty window')} · '
                                              '${_count(app.live.sessions.length, 'coding session')} '
                                              '· keeps this Mac from idle sleep'),
                          subError: app.terminalOn && _kitty?.error != null,
                          trailing: Switch(
                            value: app.terminalOn,
                            onChanged: (v) {
                              unawaited(app.setTerminal(on: v));
                              unawaited(_checkKitty());
                            },
                          ),
                        ),
                        _row(
                          label: 'Coding agent',
                          sub: 'What a new session from your phone starts',
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            spacing: 6,
                            children: [
                              for (final a in Agent.values)
                                _button(
                                  Integrations.name(a),
                                  () => unawaited(_setAgent(a)),
                                  active: a == app.codingAgent,
                                ),
                            ],
                          ),
                        ),
                        _row(
                          label: 'Džep in ${Integrations.name(app.codingAgent)}',
                          sub: _installNote ?? _integrationSub,
                          subError: _installNote != null ? _installFailed : _integration?.problem != null || _modsOff,
                          trailing: _installing
                              ? _button('Installing…', () {}, active: true)
                              : switch (_integration) {
                                  (:final installed, current: false, problem: null) => _button(
                                    installed ? 'Update' : 'Install',
                                    () => unawaited(_install()),
                                  ),
                                  _ => const SizedBox.shrink(),
                                },
                        ),
                      ]),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          _button('Quit Džep', () => unawaited(Native.quit())),
                          const Spacer(),
                          _button('Done', () => app.setSettingsOpen(open: false)),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  /// "1 idea", "2 ideas".
  static String _count(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';

  Widget _group(String title, List<Widget> rows) => Padding(
    padding: const EdgeInsets.only(top: 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: const TextStyle(fontSize: 11, letterSpacing: .6, color: C.dim)),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1B1D23),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: C.line),
          ),
          child: Column(
            children: [
              for (final (i, r) in rows.indexed) ...[if (i > 0) const Divider(height: 1, color: C.line), r],
            ],
          ),
        ),
      ],
    ),
  );

  Widget _row({required String label, required Widget trailing, Widget? leading, String? sub, bool subError = false}) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            if (leading != null) ...[leading, const SizedBox(width: 12)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(fontSize: 13)),
                  if (sub != null)
                    Text(sub, style: TextStyle(fontSize: 11, color: subError ? const Color(0xFFFCA5A5) : C.dim)),
                ],
              ),
            ),
            trailing,
          ],
        ),
      );

  Widget _button(String label, VoidCallback onTap, {bool danger = false, bool active = false}) => Hoverable(
    onTap: onTap,
    builder: (h) => Container(
      constraints: const BoxConstraints(minWidth: 70),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: h ? const Color(0xFF2E313D) : const Color(0xFF262833),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: active ? C.accent : C.line2),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 12, color: danger ? const Color(0xFFFCA5A5) : (active ? C.accent : C.text)),
      ),
    ),
  );
}
