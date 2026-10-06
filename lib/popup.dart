import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ideja/controller.dart';
import 'package:ideja/idea.dart';
import 'package:ideja/native.dart';
import 'package:ideja/store.dart';
import 'package:ideja/ui.dart';

/// `@name` tokens in the title: the first one is the project.
final _projectToken = RegExp(r'(^|\s)@([\w.-]+)');

({String title, String project}) parseTitle(String raw) {
  final m = _projectToken.firstMatch(raw);
  final title = raw.replaceAll(_projectToken, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  return (title: title, project: m?.group(2) ?? '');
}

/// The ⇧⌘Space panel: title field focused, ↵ saves to Inbox and gets out of
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
  final GlobalKey _panelKey = GlobalKey();
  bool _withNotes = false;
  int _sel = -1;
  List<Idea> _shown = const [];
  double _height = 0;
  int _session = -1;

  AppController get app => widget.app;
  IdeaStore? get store => app.store;

  @override
  void initState() {
    super.initState();
    _title.addListener(() => setState(() => _sel = -1));
    _notesFocus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    _titleFocus.dispose();
    _notesFocus.dispose();
    super.dispose();
  }

  void _reportHeight() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final h = _panelKey.currentContext?.size?.height;
      if (h != null && h != _height) {
        _height = h;
        unawaited(Native.resizePopup(h));
      }
    });
  }

  // ---------------------------------------------------------------- keys

  bool get _cmd => HardwareKeyboard.instance.isMetaPressed;
  bool get _shift => HardwareKeyboard.instance.isShiftPressed;

  KeyEventResult _onTitleKey(FocusNode _, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.tab && !_shift) {
      if (_completeProject()) return KeyEventResult.handled;
      setState(() => _withNotes = true);
      _notesFocus.requestFocus();
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

  void _save({required bool stay}) {
    final s = store;
    if (s == null) return;
    final parsed = parseTitle(_title.text);
    var title = parsed.title;
    var notes = _notes.text.trim();
    if (title.isEmpty && notes.isEmpty) return;
    if (title.isEmpty) {
      final lines = notes.split('\n');
      title = lines.first.trim();
      notes = lines.skip(1).join('\n').trim();
    }
    s.add(title: title, notes: notes, project: parsed.project);
    _title.clear();
    _notes.clear();
    setState(() => _withNotes = false);
    Toaster.of(context).show('Saved to Inbox ✓');
    if (stay) {
      _titleFocus.requestFocus();
    } else {
      unawaited(app.closePopup());
    }
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    if (_session != app.popupSession) {
      _session = app.popupSession;
      _sel = -1;
      // The draft survives Esc; focus always lands back in the title.
      WidgetsBinding.instance.addPostFrameCallback((_) => _titleFocus.requestFocus());
    }
    _reportHeight();
    final s = store;
    return Align(
      alignment: Alignment.topCenter,
      child: SingleChildScrollView(
        physics: const NeverScrollableScrollPhysics(),
        child: Container(
          key: _panelKey,
          decoration: BoxDecoration(
            color: const Color(0xF517181D),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: C.line2),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [if (s == null) _locked() else ..._capture(s), _bar(s)],
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

  List<Widget> _capture(IdeaStore s) {
    final parsed = parseTitle(_title.text);
    final words = parsed.title.toLowerCase().split(RegExp(r'\s+')).where((w) => w.length > 2).toList();
    _shown =
        (words.isEmpty
                ? s.ideas
                : s.ideas.where((i) {
                    final hay = '${i.title} ${i.notes}'.toLowerCase();
                    return words.any(hay.contains);
                  }))
            .take(7)
            .toList();
    if (_sel >= _shown.length) _sel = _shown.length - 1;

    final completing = RegExp(r'@([\w.-]*)$').firstMatch(_title.text);
    final suggestions = completing == null
        ? const <String>[]
        : s.projects.where((p) => p.startsWith(completing.group(1)!)).take(4).toList();

    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Text('💡', style: TextStyle(fontSize: 18)),
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
                      hintText: 'Drop an idea…  @project',
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
        constraints: const BoxConstraints(maxHeight: 280),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: 6),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
              child: Text(
                words.isEmpty ? 'RECENT' : '${_shown.length} SIMILAR',
                style: const TextStyle(fontSize: 11, letterSpacing: .6, color: C.dim),
              ),
            ),
            if (_shown.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(18, 8, 18, 10),
                child: Text('Nothing similar. Press ↵ to save it.', style: TextStyle(color: C.dim)),
              ),
            for (final (k, i) in _shown.indexed)
              Hoverable(
                onTap: () => unawaited(app.openMain(select: i.id)),
                builder: (hover) => Container(
                  color: k == _sel ? C.sel : (hover ? C.hover : null),
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
                  child: Row(
                    children: [
                      Dot(i.status.color),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text.rich(
                          highlight(i.title, words.join(' '), const TextStyle(fontSize: 13, color: C.text)),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (i.project.isNotEmpty) ...[const SizedBox(width: 8), ProjectChip(i.project)],
                      const SizedBox(width: 10),
                      Text(ago(i.createdAt), style: const TextStyle(fontSize: 11, color: C.dim)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    ];
  }

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
        else if (_notesFocus.hasFocus) ...const [
          KeyHint('↵', 'newline'),
          KeyHint('⌘↵', 'save'),
          KeyHint('⇧⇥', 'title'),
          KeyHint('esc', 'hide'),
        ] else ...const [
          KeyHint('↵', 'save'),
          KeyHint('⌘↵', 'save & stay'),
          KeyHint('⇥', 'description'),
          KeyHint('↓', 'browse'),
          KeyHint('esc', 'hide'),
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
