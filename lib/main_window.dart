import 'dart:async';

import 'package:dzep/controller.dart';
import 'package:dzep/idea.dart';
import 'package:dzep/native.dart';
import 'package:dzep/popup.dart';
import 'package:dzep/session.dart';
import 'package:dzep/store.dart';
import 'package:dzep/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Sidebar selection: the todo lists, an idea status ('inbox', …, or 'all'),
/// or a project.
typedef Shelf = ({bool project, String id});

const Shelf _todos = (project: false, id: 'todos');
const Shelf _todosDone = (project: false, id: 'todos-done');
const Shelf _all = (project: false, id: 'all');

/// Drag strip for the transparent title bar.
class _TitleDrag extends StatelessWidget {
  const _TitleDrag();

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
          if (store == null) SignInPage(session: app) else Library(app: app, store: store),
          const Positioned(top: 0, left: 80, right: 0, child: _TitleDrag()),
          if (store != null && app.settingsOpen) SettingsSheet(app: app),
        ],
      ),
    );
  }
}

// ==================================================================== sign in

class SignInPage extends StatelessWidget {
  const SignInPage({required this.session, super.key});
  final Session session;

  @override
  Widget build(BuildContext context) => Center(
    child: SizedBox(
      width: 340,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: const LinearGradient(
                colors: [Color(0xFF2A3150), Color(0xFF141722)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              border: Border.all(color: const Color(0xFF3A4160)),
            ),
            child: const Text('💡', style: TextStyle(fontSize: 36)),
          ),
          const SizedBox(height: 18),
          const Text('Džep', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          const Text(
            'Sign in to sync your ideas across your Mac and iPhone.',
            textAlign: TextAlign.center,
            style: TextStyle(color: C.dim),
          ),
          const SizedBox(height: 26),
          GithubButton(onPressed: () => unawaited(session.signIn())),
          const SizedBox(height: 16),
          Text(
            session.authError ?? 'Required. Opens your browser once; you stay signed in after that.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: session.authError == null ? C.dim2 : const Color(0xFFFCA5A5)),
          ),
        ],
      ),
    ),
  );
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
  String? _focusNotesOf;
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _newIdea = TextEditingController();
  final _newFocus = FocusNode();
  final _listFocus = FocusNode();
  final _rowsScroll = ScrollController();

  IdeaStore get store => widget.store;

  @override
  void initState() {
    super.initState();
    widget.app.addListener(_takePendingSelect);
    _takePendingSelect();
    _listFocus.requestFocus();
  }

  @override
  void dispose() {
    widget.app.removeListener(_takePendingSelect);
    _search.dispose();
    _searchFocus.dispose();
    _newIdea.dispose();
    _newFocus.dispose();
    _listFocus.dispose();
    _rowsScroll.dispose();
    super.dispose();
  }

  /// The popup asked to open a specific idea or todo.
  void _takePendingSelect() {
    final id = widget.app.pendingSelect;
    if (id == null) return;
    widget.app.pendingSelect = null;
    final item = store.byId(id);
    if (item == null) return;
    setState(() {
      _view = !item.isTodo ? _all : (item.done ? _todosDone : _todos);
      _query = '';
      _search.clear();
      _selId = id;
    });
  }

  bool get _todoView => !_view.project && (_view == _todos || _view == _todosDone);

  bool _inView(Idea i, Shelf v) => !v.project || i.project == v.id;

  bool _matches(Idea i) {
    final words = _query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    final hay = '${i.title} ${i.notes} @${i.project}'.toLowerCase();
    return words.every(hay.contains);
  }

  List<Idea> get _visible {
    if (_view == _todos) return store.openTodos.where(_matches).toList();
    if (_view == _todosDone) return store.doneTodos.where(_matches).toList();
    return store.ideas.where((i) => _inView(i, _view) && _matches(i)).toList();
  }

  String _viewName(Shelf v) {
    if (v.project) return '@${v.id}';
    if (v == _todos) return 'Todos';
    if (v == _todosDone) return 'Done';
    return 'All ideas';
  }

  void _select(String? id) => setState(() => _selId = id);

  void _setView(Shelf v) {
    setState(() {
      _view = v;
      _selId = _visible.firstOrNull?.id;
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
      i.isTodo ? 'Todo deleted' : 'Idea deleted',
      undo: () {
        store.restore(i);
        setState(() => _selId = i.id);
      },
    );
  }

  void _addFromField() {
    if (_todoView) {
      final title = _newIdea.text.trim();
      if (title.isEmpty) return;
      final todo = store.add(title: title, kind: Kind.todo);
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

  bool get _typing {
    final ctx = FocusManager.instance.primaryFocus?.context;
    return ctx != null && ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final cmd = HardwareKeyboard.instance.isMetaPressed;
    if (cmd && k == LogicalKeyboardKey.keyN) {
      _newFocus.requestFocus();
      return KeyEventResult.handled;
    }
    if (cmd && k == LogicalKeyboardKey.comma) {
      widget.app.setSettingsOpen(open: true);
      return KeyEventResult.handled;
    }
    if (_typing) {
      if (k == LogicalKeyboardKey.escape) {
        if (_searchFocus.hasFocus && _search.text.isNotEmpty) {
          _search.clear();
          setState(() => _query = '');
        }
        _listFocus.requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (cmd || HardwareKeyboard.instance.isControlPressed) return KeyEventResult.ignored;
    final v = _visible;
    final pos = v.indexWhere((i) => i.id == _selId);
    final cur = pos >= 0 ? v[pos] : null;
    if (k == LogicalKeyboardKey.slash) {
      _searchFocus.requestFocus();
    } else if (k == LogicalKeyboardKey.keyJ || k == LogicalKeyboardKey.arrowDown) {
      if (v.isNotEmpty) _select(v[(pos + 1).clamp(0, v.length - 1)].id);
    } else if (k == LogicalKeyboardKey.keyK || k == LogicalKeyboardKey.arrowUp) {
      if (v.isNotEmpty) _select(v[(pos - 1).clamp(0, v.length - 1)].id);
    } else if (cur != null && cur.isTodo && (k == LogicalKeyboardKey.keyD || k == LogicalKeyboardKey.space)) {
      _toggleDone(cur);
    } else if (cur != null && (k == LogicalKeyboardKey.backspace || k == LogicalKeyboardKey.delete)) {
      _delete(cur);
    } else if (cur != null && k == LogicalKeyboardKey.enter) {
      setState(() => _focusNotesOf = '${cur.id}#title');
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final visible = _visible;
      if (_selId != null && store.byId(_selId!) == null) _selId = null;
      final selected = _selId == null ? null : store.byId(_selId!);
      return Focus(
        focusNode: _listFocus,
        onKeyEvent: _onKey,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(width: 210, child: _sidebar()),
            const VerticalDivider(width: 1, color: C.line),
            SizedBox(width: 370, child: _listPane(visible)),
            const VerticalDivider(width: 1, color: C.line),
            Expanded(
              child: selected == null
                  ? const _EmptyDetail()
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

  Widget _sidebar() {
    Widget nav(Shelf v, Widget icon, String name) {
      final n = v == _todos
          ? store.openTodos.length
          : v == _todosDone
          ? 0
          : store.ideas.where((i) => _inView(i, v)).length;
      final on = _view == v;
      return Hoverable(
        onTap: () => _setView(v),
        builder: (hover) => Container(
          margin: const EdgeInsets.symmetric(horizontal: 8),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: on ? C.sel : (hover ? C.hover : null),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
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
    }

    Widget header(String t) => Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 10, 4),
      child: Text(
        t,
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: C.dim2),
      ),
    );

    final user = widget.app;
    return ColoredBox(
      color: C.side,
      child: Column(
        children: [
          const SizedBox(height: 44),
          Expanded(
            child: ListView(
              children: [
                header('TODOS'),
                nav(_todos, const Icon(Icons.radio_button_unchecked, size: 13, color: C.dim), 'Todos'),
                nav(_todosDone, const Icon(Icons.check_circle_outline, size: 13, color: C.dim), 'Done'),
                header('IDEAS'),
                nav(_all, const Icon(Icons.lightbulb_outline, size: 14, color: C.dim), 'All ideas'),
                if (store.projects.isNotEmpty) header('PROJECTS'),
                for (final p in store.projects)
                  nav((project: true, id: p), const Icon(Icons.crop_square, size: 13, color: C.dim), p),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: C.line)),
            ),
            child: Row(
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
                IconButton(
                  tooltip: 'Settings  ⌘,',
                  iconSize: 16,
                  color: C.dim,
                  onPressed: () => user.setSettingsOpen(open: true),
                  icon: const Icon(Icons.settings_outlined),
                ),
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
      final g = _group(i.isTodo && i.done ? i.doneAt! : i.createdAt);
      if (g != group) {
        group = g;
        rows.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              g,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: C.dim2),
            ),
          ),
        );
      }
      rows.add(_row(i));
    }
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
                      text: '   ${visible.length} idea${visible.length == 1 ? '' : 's'}',
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
                    const Kbd('/'),
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
                    hintText: _todoView ? 'New todo…  ↵  (⌘N)' : 'New idea…  ↵  (⌘N)',
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
                        : _view == _all
                        ? 'No ideas yet.\n${widget.app.hotKey.label} then 1 adds one from anywhere.'
                        : _view == _todos
                        ? 'All done 🎉\n${widget.app.hotKey.label} then ⌘T adds a todo from anywhere.'
                        : 'Nothing here yet.',
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
    final firstNote = i.notes.split('\n').first;
    return Hoverable(
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
            else
              const Padding(padding: EdgeInsets.only(top: 5), child: Dot(C.dim)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    highlight(i.title.isEmpty ? 'Untitled' : i.title, _query, titleStyle),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (firstNote.isNotEmpty)
                    Text.rich(
                      highlight(firstNote, _query, const TextStyle(fontSize: 12, color: C.dim)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  if (i.project.isNotEmpty)
                    Padding(padding: const EdgeInsets.only(top: 4), child: ProjectChip(i.project)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(stamp(i.createdAt), style: const TextStyle(fontSize: 11, color: C.dim2)),
          ],
        ),
      ),
    );
  }

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

class Avatar extends StatelessWidget {
  const Avatar({required this.url, required this.name, this.size = 24, super.key});
  final String? url;
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final letter = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(colors: [Color(0xFF7C9CFF), Color(0xFFC084FC)]),
      ),
      child: Text(
        name.isEmpty ? '?' : name[0].toUpperCase(),
        style: TextStyle(fontSize: size * .45, fontWeight: FontWeight.w700, color: const Color(0xFF111111)),
      ),
    );
    if (url == null) return letter;
    return ClipOval(
      child: Image.network(url!, width: size, height: size, errorBuilder: (_, _, _) => letter),
    );
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
        Opacity(opacity: .5, child: Text('💡', style: TextStyle(fontSize: 40))),
        SizedBox(height: 8),
        Text('Select an idea', style: TextStyle(color: C.dim)),
        SizedBox(height: 14),
        _Hint('⌘N', 'new idea here'),
        _Hint('j  k', 'move'),
        _Hint('/', 'search'),
      ],
    ),
  );
}

class _Hint extends StatelessWidget {
  const _Hint(this.keys, this.label);
  final String keys;
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 60,
          child: Align(alignment: Alignment.centerRight, child: Kbd(keys)),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 120,
          child: Text(label, style: const TextStyle(fontSize: 12, color: C.dim)),
        ),
      ],
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
            Text(widget.viewName, style: const TextStyle(color: C.dim, fontSize: 13)),
            const Text('  ›  ', style: TextStyle(color: C.dim)),
            Expanded(
              child: Text(
                idea.title.isEmpty ? 'Untitled' : idea.title,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
            ),
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
                      const SizedBox(width: 6),
                      const Text('d', style: TextStyle(fontSize: 10, color: C.dim2)),
                    ],
                  ),
                ),
              )
            else
              _prop('Project', _projectField()),
            const SizedBox(height: 22),
            TextField(
              controller: _notes,
              focusNode: _notesFocus,
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
  const SettingsSheet({required this.app, super.key});
  final AppController app;

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  bool _recording = false;
  String? _hotKeyError;
  bool? _launchAtLogin;
  String? _launchError;
  final _recorderFocus = FocusNode();

  AppController get app => widget.app;

  @override
  void initState() {
    super.initState();
    unawaited(Native.launchAtLogin().then((v) => mounted ? setState(() => _launchAtLogin = v) : null));
  }

  @override
  void dispose() {
    _recorderFocus.dispose();
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
          child: GestureDetector(
            onTap: () {},
            child: Container(
              width: 500,
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
              decoration: BoxDecoration(
                color: C.win,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: C.line2),
                boxShadow: const [BoxShadow(color: Color(0x99000000), blurRadius: 60, offset: Offset(0, 20))],
              ),
              child: Focus(
                focusNode: _recorderFocus,
                autofocus: true,
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
                        sub: 'Signed in with GitHub · ${app.store?.ideas.length ?? 0} ideas',
                        trailing: _button('Sign out', () => unawaited(app.signOut()), danger: true),
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
  );

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
