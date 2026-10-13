import 'dart:async';

import 'package:dzep/controller.dart';
import 'package:dzep/idea.dart';
import 'package:dzep/main_window.dart';
import 'package:dzep/store.dart';
import 'package:dzep/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The note window (`NotePanel` in MainFlutterWindow.swift): one note, apart
/// from the app, saved as it's typed. Opened from a note in the main window
/// (which hides until it closes) or with ⌘6 in the popup.
class NoteWindow extends StatelessWidget {
  const NoteWindow({required this.app, super.key});
  final AppController app;

  @override
  Widget build(BuildContext context) {
    final store = app.store;
    return ColoredBox(
      color: C.win,
      child: !app.noteOpen || store == null
          ? const SizedBox.expand()
          // Every open starts over on its note.
          : _NotePad(key: ValueKey(app.noteSession), app: app, store: store),
    );
  }
}

class _NotePad extends StatefulWidget {
  const _NotePad({required this.app, required this.store, super.key});
  final AppController app;
  final IdeaStore store;

  @override
  State<_NotePad> createState() => _NotePadState();
}

class _NotePadState extends State<_NotePad> {
  /// Null for a new note, made once something is written.
  late Idea? _note = switch (app.noteId) {
    final id? => store.byId(id),
    null => null,
  };
  late final _text = TextEditingController(text: _note?.notes ?? '');
  final _focus = FocusNode();
  bool _hadKey = false;

  AppController get app => widget.app;
  IdeaStore get store => widget.store;

  @override
  void initState() {
    super.initState();
    // Caret after the text, to keep writing.
    _text.selection = TextSelection.collapsed(offset: _text.text.length);
    store.addListener(_onStore);
    app.addListener(_onApp);
    _onApp();
    WidgetsBinding.instance.addPostFrameCallback((_) => _takeFocus());
  }

  @override
  void dispose() {
    store.removeListener(_onStore);
    app.removeListener(_onApp);
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// The window got the keyboard (clicked back into, or after the popup): the
  /// editor takes the focus, which another window may have taken meanwhile.
  void _onApp() {
    final key = app.noteKey;
    if (key && !_hadKey) _takeFocus();
    _hadKey = key;
  }

  void _takeFocus() {
    if (mounted && !_focus.hasFocus) _focus.requestFocus();
  }

  /// Edited elsewhere: shown unless it's being typed in here. Deleted
  /// elsewhere: the window closes.
  void _onStore() {
    final note = _note;
    if (note == null || !mounted) return;
    if (store.byId(note.id) == null) {
      unawaited(app.closeNoteWindow());
      return;
    }
    if (!(_focus.hasFocus && app.noteKey) && _text.text != note.notes) _text.text = note.notes;
    setState(() {});
  }

  void _changed(String text) {
    final note = _note;
    if (note != null) {
      store.editNote(note, text);
    } else if (text.trim().isNotEmpty) {
      final made = store.addNote(text);
      // The main window opens on it when this closes.
      app.noteId = made.id;
      setState(() => _note = made);
    }
  }

  @override
  Widget build(BuildContext context) {
    final note = _note;
    final title = note == null ? 'New note' : (note.title.isEmpty ? 'Empty note' : note.title);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The title bar: the close button on the left, the title, Copy.
        Container(
          height: 28,
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: C.line)),
          ),
          child: Stack(
            children: [
              const Positioned.fill(child: TitleDrag()),
              Row(
                children: [
                  const SizedBox(width: 56),
                  Expanded(
                    // Not in the way of the drag.
                    child: IgnorePointer(
                      child: Text(
                        title,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: C.dim),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 56,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: IconButton(
                        tooltip: 'Copy',
                        iconSize: 13,
                        color: C.dim,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(width: 28, height: 27),
                        icon: const Icon(Icons.copy_outlined),
                        onPressed: note == null
                            ? null
                            : () {
                                unawaited(Clipboard.setData(ClipboardData(text: note.notes.trim())));
                                Toaster.of(context).show('Copied');
                              },
                      ),
                    ),
                  ),
                ],
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
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
              child: TextField(
                controller: _text,
                focusNode: _focus,
                selectionWidthStyle: selectionWidth,
                maxLines: null,
                keyboardType: TextInputType.multiline,
                style: const TextStyle(fontSize: 14, height: 1.55, color: Color(0xFFD7DAE2)),
                decoration: plainInput.copyWith(
                  hintText: 'Write anything. The first line is the title.',
                  hintStyle: const TextStyle(color: C.dim2),
                ),
                onChanged: _changed,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
