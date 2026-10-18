import 'dart:async';

import 'package:dzep_core/idea.dart';
import 'package:dzep_core/store.dart';
import 'package:dzep_core/ui.dart';
import 'package:dzep_mobile/chrome.dart';
import 'package:dzep_mobile/mobile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// What the Pocket tab shows.
enum PocketShow {
  all('All'),
  todos('Todos'),
  ideas('Ideas'),
  notes('Notes');

  const PocketShow(this.label);
  final String label;
}

/// Todos, ideas and notes in one list. All: open todos first, then ideas
/// and notes most recently changed first, then done todos (folded). The
/// pills on top narrow it to one kind; ideas also by project.
class PocketView extends StatefulWidget {
  const PocketView({required this.store, required this.show, required this.onShow, super.key});
  final IdeaStore store;
  final PocketShow show;
  final ValueChanged<PocketShow> onShow;

  @override
  State<PocketView> createState() => PocketViewState();
}

class PocketViewState extends State<PocketView> {
  String _query = '';
  bool _showDone = false;

  /// Ideas of this project only; empty for all.
  String _project = '';

  /// The project a new idea goes under: the one picked here.
  String get project => widget.show == PocketShow.ideas ? _project : '';

  IdeaStore get store => widget.store;
  bool _hit(Idea i) {
    final hay = '${i.title} ${i.notes} @${i.project}'.toLowerCase();
    return _query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).every(hay.contains);
  }

  /// Todos ticked (or un-ticked) a moment ago, keyed by id: they stay in
  /// their section drawn flipped until the timer moves them, so the check
  /// is seen filling first. A second tap in the meantime cancels.
  final _pending = <Object, Timer>{};

  /// Pending todos fading out, just before they move.
  final _leaving = <Object>{};

  /// Whether [t] reads as done, counting a pending flip.
  bool _looksDone(Idea t) => t.done != _pending.containsKey(t.id);

  @override
  void dispose() {
    for (final timer in _pending.values) {
      timer.cancel();
    }
    super.dispose();
  }

  /// The check button: flips the row in place, moves it shortly after.
  void _tapCheck(Idea todo) {
    unawaited(HapticFeedback.lightImpact());
    if (_pending.remove(todo.id) case final timer?) {
      timer.cancel();
      setState(() => _leaving.remove(todo.id));
      return;
    }
    // The check fills, then the row fades out, then it moves.
    setState(() {
      _pending[todo.id] = Timer(const Duration(milliseconds: 350), () {
        if (!mounted) return;
        setState(() => _leaving.add(todo.id));
        _pending[todo.id] = Timer(_fadeOut, () {
          _pending.remove(todo.id);
          _leaving.remove(todo.id);
          if (mounted) _toggleDone(todo, haptic: false);
        });
      });
    });
  }

  static const Duration _fadeOut = Motion.fast;

  void _toggleDone(Idea todo, {bool haptic = true}) {
    _pending.remove(todo.id)?.cancel();
    _leaving.remove(todo.id);
    store.update(todo, done: !todo.done);
    if (haptic) unawaited(HapticFeedback.lightImpact());
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(undoSnackBar(todo.done ? 'Done ✓' : 'Reopened', () => store.update(todo, done: !todo.done)));
  }

  void _delete(Idea i) {
    store.delete(i);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        undoSnackBar(switch (i.kind) {
          Kind.todo => 'Todo deleted',
          Kind.note => 'Note deleted',
          Kind.idea => 'Idea deleted',
        }, () => store.restore(i)),
      );
  }

  void _open(Idea i) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => i.isNote ? NotePage(store: store, note: i) : DetailPage(idea: i, store: store),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final show = widget.show;
    final projects = store.projects;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SearchField(onChanged: (q) => setState(() => _query = q)),
        Segments(
          labels: [
            for (final s in PocketShow.values)
              if (s == PocketShow.todos && store.openTodos.isNotEmpty)
                '${s.label} ${store.openTodos.length}'
              else
                s.label,
          ],
          keys: [for (final s in PocketShow.values) ValueKey('show-${s.name}')],
          selected: show.index,
          onSelect: (i) => widget.onShow(PocketShow.values[i]),
        ),
        Reveal(
          visible: show == PocketShow.ideas && projects.isNotEmpty,
          child: SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                for (final p in projects)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Center(
                      child: Pill(
                        label: '@$p',
                        selected: _project == p,
                        color: C.projectFg,
                        onTap: () => setState(() => _project = _project == p ? '' : p),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        Expanded(
          child: RefreshIndicator(onRefresh: store.syncNow, child: _list()),
        ),
      ],
    );
  }

  Widget _list() {
    final show = widget.show;
    final open = show == PocketShow.all || show == PocketShow.todos ? store.openTodos.where(_hit).toList() : <Idea>[];
    final done = show == PocketShow.all || show == PocketShow.todos ? store.doneTodos.where(_hit).toList() : <Idea>[];
    final others = switch (show) {
      PocketShow.todos => <Idea>[],
      PocketShow.ideas => store.ideas.where((i) => _project.isEmpty || i.project == _project).where(_hit).toList(),
      PocketShow.notes => store.notes.where(_hit).toList(),
      PocketShow.all => [
        ...store.ideas,
        ...store.notes,
      ].where(_hit).toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)),
    };
    if (open.isEmpty && done.isEmpty && others.isEmpty) {
      return ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(40),
            child: Text(
              _query.isNotEmpty
                  ? 'No matches.'
                  : switch (show) {
                      PocketShow.all => 'Your pocket is empty.\nTap + to add a todo, an idea or a note.',
                      PocketShow.todos => 'All done 🎉\nTap + to add one.',
                      PocketShow.ideas => _project.isEmpty ? 'No ideas yet.\nTap + to add one.' : 'Nothing here yet.',
                      PocketShow.notes => 'No notes yet.\nTap ✎ to write one.',
                    },
              textAlign: TextAlign.center,
              style: const TextStyle(color: C.dim, height: 1.5),
            ),
          ),
        ],
      );
    }
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.only(bottom: AppTabBar.contentInset),
      children: [
        if (show == PocketShow.todos && open.isEmpty)
          const Padding(
            padding: EdgeInsets.all(40),
            child: Text(
              'All done 🎉',
              textAlign: TextAlign.center,
              style: TextStyle(color: C.dim),
            ),
          ),
        if (open.isNotEmpty)
          // Keyed by section, so a filter switch draws each list afresh
          // instead of resizing one section's card into another's.
          Panel(
            key: const ValueKey('panel-open'),
            title: show == PocketShow.all ? 'TO DO' : null,
            count: open.length,
            children: [for (final t in open) _todoRow(t)],
          ),
        if (others.isNotEmpty)
          Panel(
            key: ValueKey('panel-${show.name}'),
            title: show == PocketShow.all ? 'RECENT' : null,
            children: [
              for (final i in others)
                if (i.isNote) _noteRow(i) else _ideaRow(i),
            ],
          ),
        if (done.isNotEmpty)
          Panel(
            key: const ValueKey('panel-done'),
            title: 'DONE',
            count: done.length,
            onTitleTap: () => setState(() => _showDone = !_showDone),
            titleTrailing: AnimatedRotation(
              turns: _showDone ? .5 : 0,
              duration: Motion.fast,
              curve: Motion.fold,
              child: const Icon(Icons.expand_more, color: C.dim, size: 20),
            ),
            children: [
              if (_showDone)
                for (final t in done) _todoRow(t),
            ],
          ),
      ],
    );
  }

  static const _rowPadding = EdgeInsets.fromLTRB(4, 6, 16, 6);

  Widget _swipeToDelete(Idea i, Widget child) => Dismissible(
    key: ValueKey(i.id),
    direction: DismissDirection.endToStart,
    background: _swipeBg(Alignment.centerRight, const Color(0xFF7F1D1D), Icons.delete_outline),
    onDismissed: (_) => _delete(i),
    child: child,
  );

  static Widget _swipeBg(Alignment side, Color color, IconData icon) => Container(
    color: color,
    alignment: side,
    padding: const EdgeInsets.symmetric(horizontal: 24),
    child: Icon(icon, color: Colors.white),
  );

  /// A kind's mark, where a todo has its check: both 48 wide after the row's
  /// 4pt inset, so marks share one centre and titles start at 52.
  static Widget _mark(IconData icon) => SizedBox(
    width: 48,
    child: Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Icon(icon, size: 19, color: C.dim),
    ),
  );

  /// Title type shared by todo, idea and note rows.
  static const _titleStyle = TextStyle(fontSize: 15, color: C.text);

  Widget _stamp(DateTime t) => Padding(
    padding: const EdgeInsets.only(left: 8, top: 2),
    child: Text(stamp(t), style: const TextStyle(fontSize: 12, color: C.dim2)),
  );

  Widget _todoRow(Idea t) {
    final done = _looksDone(t);
    return Dismissible(
      key: ValueKey('todo-${t.id}-${t.done}'),
      background: _swipeBg(Alignment.centerLeft, const Color(0xFF14532D), t.done ? Icons.undo : Icons.check),
      secondaryBackground: _swipeBg(Alignment.centerRight, const Color(0xFF7F1D1D), Icons.delete_outline),
      onDismissed: (dir) => dir == DismissDirection.startToEnd ? _toggleDone(t) : _delete(t),
      // Leaving: it fades and folds shut together, so the rows under it
      // slide up instead of jumping.
      child: ClipRect(
        child: AnimatedAlign(
          alignment: Alignment.topCenter,
          heightFactor: _leaving.contains(t.id) ? 0 : 1,
          duration: _fadeOut,
          curve: Motion.ease,
          child: AnimatedOpacity(
            opacity: _leaving.contains(t.id) ? 0 : 1,
            duration: _fadeOut,
            curve: Motion.ease,
            child: InkWell(
              onTap: () => _open(t),
              onLongPress: t.done ? null : () => unawaited(pickReminder(context, store, t)),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 2, 16, 2),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: done ? 'Reopen' : 'Done',
                      onPressed: () => _tapCheck(t),
                      icon: TodoCheck(done: done, size: 22),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text.rich(
                            highlight(
                              t.title,
                              _query,
                              _titleStyle.copyWith(
                                color: done ? C.dim : C.text,
                                decoration: done ? TextDecoration.lineThrough : null,
                                decorationColor: C.dim,
                              ),
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (t.remindAt case final at? when !done)
                            Padding(padding: const EdgeInsets.only(top: 3), child: ReminderChip(at)),
                        ],
                      ),
                    ),
                    _stamp(t.createdAt),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _ideaRow(Idea i) {
    final firstNote = i.notes.split('\n').first;
    return _swipeToDelete(
      i,
      InkWell(
        onTap: () => _open(i),
        child: Padding(
          padding: _rowPadding.copyWith(top: 12, bottom: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _mark(Icons.lightbulb_outline_rounded),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      highlight(i.title.isEmpty ? 'Untitled' : i.title, _query, _titleStyle),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (firstNote.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          firstNote,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13, color: C.dim),
                        ),
                      ),
                    if (i.project.isNotEmpty)
                      Padding(padding: const EdgeInsets.only(top: 6), child: ProjectChip(i.project)),
                  ],
                ),
              ),
              _stamp(i.createdAt),
            ],
          ),
        ),
      ),
    );
  }

  Widget _noteRow(Idea n) {
    final preview = n.notes.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).skip(1).firstOrNull;
    return _swipeToDelete(
      n,
      InkWell(
        onTap: () => _open(n),
        child: Padding(
          padding: _rowPadding.copyWith(top: 12, bottom: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _mark(Icons.sticky_note_2_outlined),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      highlight(n.title.isEmpty ? 'Empty note' : n.title, _query, _titleStyle),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (preview != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          preview,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13, color: C.dim, height: 1.35),
                        ),
                      ),
                  ],
                ),
              ),
              _stamp(n.updatedAt),
            ],
          ),
        ),
      ),
    );
  }
}
