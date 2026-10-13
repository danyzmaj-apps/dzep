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

/// A popup text field and its focus.
typedef _Field = ({TextEditingController text, FocusNode focus});

/// The ⇧⌘Space panel. It opens straight into the mode it was last used in,
/// field focused: an idea, a todo, a note or a quick question (⌘1–⌘4 or the
/// strip at the top switch; ⌘5 opens the app). ↵ saves and gets out of the
/// way; in Note mode ⌘P puts the note in its own window.
class Popup extends StatefulWidget {
  const Popup({required this.app, super.key});
  final AppController app;

  @override
  State<Popup> createState() => _PopupState();
}

class _PopupState extends State<Popup> with WidgetsBindingObserver {
  final _title = TextEditingController();
  final _notes = TextEditingController();
  late final FocusNode _titleFocus = FocusNode(onKeyEvent: _onTitleKey);
  late final FocusNode _notesFocus = FocusNode(onKeyEvent: _onNotesKey);
  bool _withNotes = false;

  /// Whose draft [_title] / [_notes] hold now, and the other's, kept aside.
  PopupMode _shownDraft = PopupMode.idea;
  final _drafts = <PopupMode, ({TextEditingValue title, TextEditingValue notes})>{};

  final _question = TextEditingController();
  late final FocusNode _questionFocus = FocusNode(onKeyEvent: _onQuestionKey);
  final _attachments = ChatAttachments();

  final _note = TextEditingController();
  late final FocusNode _noteFocus = FocusNode(onKeyEvent: _onNoteKey);

  PopupMode _mode = PopupMode.idea;
  bool get _asking => _mode == PopupMode.ask;

  /// What ↵ saves in the idea and todo modes.
  Kind get _kind => _mode == PopupMode.todo ? Kind.todo : Kind.idea;
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
    WidgetsBinding.instance.addObserver(this);
    _onApp();
  }

  @override
  void dispose() {
    app.removeListener(_onApp);
    HardwareKeyboard.instance.removeHandler(_onAnyKey);
    WidgetsBinding.instance.removeObserver(this);
    _title.dispose();
    _notes.dispose();
    _titleFocus.dispose();
    _notesFocus.dispose();
    _question.dispose();
    _questionFocus.dispose();
    _note.dispose();
    _noteFocus.dispose();
    _attachments.dispose();
    super.dispose();
  }

  /// The popup takes the keyboard without making Džep the active app, so as
  /// it comes on screen the engine reports the app inactive or hidden, and
  /// Flutter's FocusManager puts the focus away (until a "resumed" that
  /// never comes): the field had no caret until a key focused it again.
  /// It takes it back.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && app.popupOpen && store != null && !_fieldFocused) _focusMode();
  }

  /// The popup was open when [app] last changed.
  bool _open = false;

  /// A new open resets right away (not on the next frame), so a quick
  /// ⇧⌘Space-then-typing never lands on a stale screen.
  void _onApp() {
    if (_open && !app.popupOpen) _letGoOfFocus();
    _open = app.popupOpen;
    if (_session == app.popupSession) return;
    _session = app.popupSession;
    _sel = -1;
    _mode = app.askNext ? PopupMode.ask : app.popupMode;
    app.askNext = false;
    _showDraftOf(_mode);
    _titleFocus.unfocus();
    _notesFocus.unfocus();
    _questionFocus.unfocus();
    _noteFocus.unfocus();
    if (app.popupOpen) {
      // The draft comes back with the caret after it.
      final text = _modeField.text;
      text.selection = TextSelection.collapsed(offset: text.text.length);
      _focusMode();
    }
    if (mounted) setState(() {});
  }

  /// Hidden, the popup holds no focus. Both windows share one FocusManager,
  /// so the main window's keys would otherwise go to a hidden popup field.
  /// The main window takes the focus back itself (`Library`).
  void _letGoOfFocus() {
    _awaiting = null;
    final focus = FocusManager.instance.primaryFocus;
    final at = focus?.context;
    if (focus == null || focus is FocusScopeNode || at == null || View.maybeOf(at) != View.maybeOf(context)) return;
    focus.unfocus();
  }

  void _setMode(PopupMode mode) {
    // Clicking a tab took the focus from the field, even the current tab's:
    // always hand it back, so typing just works.
    if (mode != _mode) {
      setState(() {
        _mode = mode;
        _sel = -1;
        _showDraftOf(mode);
      });
      app.setPopupMode(mode);
    }
    _focusMode();
  }

  /// Idea and todo share one field (and its description), but each keeps its
  /// own text, like note and ask: switching puts the other's draft in.
  void _showDraftOf(PopupMode mode) {
    if (mode != PopupMode.idea && mode != PopupMode.todo || mode == _shownDraft) return;
    _drafts[_shownDraft] = (title: _title.value, notes: _notes.value);
    final next = _drafts[mode];
    _title.value = next?.title ?? TextEditingValue.empty;
    _notes.value = next?.notes ?? TextEditingValue.empty;
    _withNotes = _notes.text.isNotEmpty;
    _shownDraft = mode;
  }

  /// The field typing goes to in the current mode.
  _Field get _modeField => switch (_mode) {
    PopupMode.ask => (text: _question, focus: _questionFocus),
    PopupMode.note => (text: _note, focus: _noteFocus),
    _ => (text: _title, focus: _titleFocus),
  };

  bool get _fieldFocused => [_titleFocus, _notesFocus, _questionFocus, _noteFocus].any((f) => f.hasFocus);

  /// Focuses the mode's field: now if it's on screen, else right after the
  /// frame that builds it (asked for here, since nothing else may ask: the
  /// popup can sit there with no frame coming).
  void _focusMode() {
    final field = _modeField;
    _awaiting = field;
    void apply() {
      if (!mounted || _awaiting != field) return;
      _awaiting = null;
      field.focus.requestFocus();
    }

    if (field.focus.context != null) return apply();
    WidgetsBinding.instance
      ..addPostFrameCallback((_) => apply())
      ..scheduleFrame();
  }

  /// Clicks elsewhere in the panel leave the field focused (on the Mac a
  /// field lets go of the focus on any click outside it): the list, the hint
  /// bar and the padding are nothing to focus instead.
  void _keepFocus(PointerDownEvent _) {}

  // ---------------------------------------------------------------- keys

  bool get _cmd => HardwareKeyboard.instance.isMetaPressed;
  bool get _shift => HardwareKeyboard.instance.isShiftPressed;

  /// The field the popup is about to focus: characters typed before it has
  /// focus go into it.
  _Field? _awaiting;

  static final Map<LogicalKeyboardKey, PopupMode> _modeKeys = {
    LogicalKeyboardKey.digit1: PopupMode.idea,
    LogicalKeyboardKey.digit2: PopupMode.todo,
    LogicalKeyboardKey.digit3: PopupMode.note,
    LogicalKeyboardKey.digit4: PopupMode.ask,
  };

  /// Sees every key, whatever has focus: the window can take keys a frame
  /// before Flutter has rebuilt it, and a click can leave no field focused.
  bool _onAnyKey(KeyEvent e) {
    if (!app.popupOpen || e is KeyUpEvent) return false;
    final k = e.logicalKey;
    if (_cmd && !_shift && _modeKeys[k] != null) {
      _setMode(_modeKeys[k]!);
      return true;
    }
    if (_cmd && !_shift && k == LogicalKeyboardKey.digit5) {
      unawaited(app.openMain());
      return true;
    }
    // ⌘W hides it, as it closes any window.
    if (_cmd && !_shift && k == LogicalKeyboardKey.keyW) {
      unawaited(app.closePopup());
      return true;
    }
    // The chat's keys work whether the field or the transcript has focus.
    final chat = app.chats;
    if (_asking && chat != null) {
      if (k == LogicalKeyboardKey.escape) {
        unawaited(app.closePopup());
        return true;
      } else if (k == LogicalKeyboardKey.keyN && _cmd) {
        chat.newChat();
        _question.clear();
        _attachments.take();
        _questionFocus.requestFocus();
        return true;
      } else if (k == LogicalKeyboardKey.keyO && _cmd) {
        unawaited(app.openMain(conversation: chat.current, chats: true));
        return true;
      } else if (k == LogicalKeyboardKey.keyC && _cmd && _shift) {
        copyAnswer(context, chat.current?.lastAnswer);
        return true;
      } else if (isPasteKey(e)) {
        // An image on the clipboard is attached; text still pastes as usual.
        unawaited(_attachments.paste());
        return false;
      }
    }
    // The mode's field isn't focused yet (just opened or switched), or a
    // click left no field focused: its keys still work, and typing goes in.
    final field = _awaiting ?? (_fieldFocused ? null : _modeField);
    if (field == null || field.focus.hasFocus) return false;
    if (_unfocusedKey(e) == KeyEventResult.handled) return true;
    final ch = e.character;
    if (store == null || _cmd || !_printable(ch)) return false;
    _type(field.text, ch!);
    if (_awaiting == null) _focusMode();
    return true;
  }

  /// What the mode's field would do with [e], for when it doesn't have focus.
  KeyEventResult _unfocusedKey(KeyEvent e) {
    if (store == null) {
      if (e.logicalKey != LogicalKeyboardKey.escape) return KeyEventResult.ignored;
      unawaited(app.closePopup());
      return KeyEventResult.handled;
    }
    return switch (_mode) {
      PopupMode.ask => _onQuestionKey(_questionFocus, e),
      PopupMode.note => _onNoteKey(_noteFocus, e),
      _ => _onTitleKey(_titleFocus, e),
    };
  }

  /// Puts [ch] where the caret is (after the text if the field never had
  /// one), as typing into the field would.
  static void _type(TextEditingController text, String ch) {
    final v = text.value;
    final at = v.selection.isValid ? v.selection : TextSelection.collapsed(offset: v.text.length);
    text.value = TextEditingValue(
      text: v.text.replaceRange(at.start, at.end, ch),
      selection: TextSelection.collapsed(offset: at.start + ch.length),
    );
  }

  /// Text a key types: no control characters, and none of the private-use
  /// ones macOS gives arrow and function keys.
  static bool _printable(String? ch) =>
      ch != null && ch.isNotEmpty && ch.runes.every((r) => r >= 0x20 && r != 0x7f && (r < 0xF700 || r > 0xF8FF));

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
      // The selected item, else this mode's list (Todos or Ideas).
      unawaited(app.openMain(select: _sel >= 0 ? _shown[_sel].id : null, section: _kind));
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

  KeyEventResult _onNoteKey(FocusNode _, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if ((k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) && _cmd) {
      _saveNote();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyO && _cmd) {
      unawaited(app.openMain(section: Kind.note));
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyP && _cmd) {
      _openNoteWindow();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape) {
      unawaited(app.closePopup());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _saveNote() {
    final s = store;
    final text = _note.text.trim();
    if (s == null || text.isEmpty) return;
    s.addNote(text);
    _note.clear();
    Toaster.of(context).show('Note saved ✓');
    unawaited(app.closePopup());
  }

  /// ⌘P: the note in its own window, apart from the app (which stays as it
  /// is). The note being written goes there; nothing written, a new one.
  void _openNoteWindow() {
    final s = store;
    if (s == null) return;
    final text = _note.text.trim();
    final note = text.isEmpty ? null : s.addNote(text);
    if (note != null) _note.clear();
    unawaited(app.openNoteWindow(id: note?.id));
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
    // Idea and todo are one pane (the same field, only what ↵ saves differs):
    // two copies cross-fading would share its focus node, and the outgoing
    // one would take the focus with it.
    final stage = s == null
        ? 'locked'
        : switch (_mode) {
            PopupMode.idea || PopupMode.todo => 'capture',
            _ => _mode.name,
          };
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
            // Clicks on the panel stay on the panel, and one on nothing in
            // particular hands the focus back to the field.
            onTap: () {
              if (s != null && !_fieldFocused) _focusMode();
            },
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
                    if (s != null) _modes(),
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
                              : switch (_mode) {
                                  PopupMode.ask => _askPane(app.chats!),
                                  PopupMode.note => Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: _notePane(s),
                                  ),
                                  _ => Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: _capture(s),
                                  ),
                                },
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

  /// The strip on top: which mode ↵ saves in (⌘1–⌘4), and the way to the app
  /// (⌘5).
  Widget _modes() {
    Widget button(IconData icon, String label, int n, {required bool on, required VoidCallback onTap}) => Hoverable(
      onTap: onTap,
      builder: (hover) => Container(
        margin: const EdgeInsets.only(right: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(color: on ? C.sel : (hover ? C.hover : null), borderRadius: BorderRadius.circular(7)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: on ? C.accent : C.dim),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontSize: 12.5, color: on ? C.text : C.dim)),
            const SizedBox(width: 6),
            Text('⌘$n', style: const TextStyle(fontSize: 11, color: C.dim2)),
          ],
        ),
      ),
    );

    Widget tab(PopupMode mode, IconData icon, String label, int n) =>
        button(icon, label, n, on: _mode == mode, onTap: () => _setMode(mode));

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
      child: Row(
        children: [
          tab(PopupMode.idea, Icons.lightbulb_outline, 'Idea', 1),
          tab(PopupMode.todo, Icons.check_circle_outline, 'Todo', 2),
          tab(PopupMode.note, Icons.sticky_note_2_outlined, 'Note', 3),
          tab(PopupMode.ask, Icons.auto_awesome, 'Ask', 4),
          const Spacer(),
          button(Icons.open_in_new, 'Open app', 5, on: false, onTap: () => unawaited(app.openMain())),
        ],
      ),
    );
  }

  /// A note: one free text field (↵ is a new line, ⌘↵ saves); the recent
  /// notes below open in the main window.
  List<Widget> _notePane(IdeaStore s) {
    final recent = s.notes.take(5).toList();
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Icon(Icons.sticky_note_2_outlined, size: 18, color: C.accent),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _note,
                focusNode: _noteFocus,
                onTapOutside: _keepFocus,
                // A draft coming back keeps its caret (see the title field).
                selectAllOnFocus: false,
                selectionWidthStyle: selectionWidth,
                minLines: 3,
                maxLines: 10,
                keyboardType: TextInputType.multiline,
                style: const TextStyle(fontSize: 16, height: 1.5),
                decoration: plainInput.copyWith(
                  hintText: 'Write a note…  the first line is its title',
                  hintStyle: const TextStyle(color: C.dim2),
                ),
              ),
            ),
          ],
        ),
      ),
      if (recent.isNotEmpty)
        Container(
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: C.line)),
          ),
          padding: const EdgeInsets.only(bottom: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(18, 8, 18, 4),
                child: Text('RECENT NOTES', style: TextStyle(fontSize: 11, letterSpacing: .6, color: C.dim)),
              ),
              for (final n in recent)
                Hoverable(
                  onTap: () => unawaited(app.openMain(select: n.id)),
                  builder: (hover) => Container(
                    color: hover ? C.hover : null,
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
                    child: Row(
                      children: [
                        const Icon(Icons.notes, size: 13, color: C.dim),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            n.title.isEmpty ? 'Empty note' : n.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(stamp(n.updatedAt), style: const TextStyle(fontSize: 11, color: C.dim)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
    ];
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
                    onTapOutside: _keepFocus,
                    // A draft coming back into focus keeps its caret: the
                    // Mac's select-all-on-focus would let the next key wipe it.
                    selectAllOnFocus: false,
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
                        onTapOutside: _keepFocus,
                        selectAllOnFocus: false,
                        selectionWidthStyle: selectionWidth,
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
                        onTapOutside: _keepFocus,
                        selectAllOnFocus: false,
                        selectionWidthStyle: selectionWidth,
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
        else if (_asking) ...const [
          KeyHint('↵', 'ask'),
          KeyHint('⇧↵', 'newline'),
          KeyHint('⌘N', 'new chat'),
          KeyHint('⌘O', 'chats'),
          KeyHint('esc', 'hide'),
        ] else if (_mode == PopupMode.note) ...const [
          KeyHint('⌘↵', 'save'),
          KeyHint('⌘O', 'notes'),
          KeyHint('⌘P', 'window'),
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
