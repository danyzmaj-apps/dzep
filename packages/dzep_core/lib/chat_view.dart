import 'dart:async';

import 'package:dzep_core/chat.dart';
import 'package:dzep_core/chat_images.dart';
import 'package:dzep_core/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// Copies [text] and says so: the Mac's toast, the iPhone's snackbar.
void copyAnswer(BuildContext context, String? text) {
  if (text == null || text.isEmpty) return;
  unawaited(Clipboard.setData(ClipboardData(text: text)));
  final toaster = context.findAncestorStateOfType<ToasterState>();
  if (toaster != null) {
    toaster.show('Copied ✓');
  } else {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Copied ✓')));
  }
}

/// A conversation's turns, newest at the bottom, all selectable (drag, ⌘C,
/// right-click → Copy). The list is reversed so streaming text stays in view.
class ChatTranscript extends StatelessWidget {
  const ChatTranscript({
    required this.chat,
    required this.conversation,
    this.shrinkWrap = false,
    this.padding = const EdgeInsets.fromLTRB(18, 10, 18, 14),
    super.key,
  });

  final ChatStore chat;
  final Conversation conversation;

  /// Sized to its content (the popup) instead of filling the space.
  final bool shrinkWrap;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final last = conversation.messages.lastOrNull;
    return SelectionArea(
      child: ListView(
        reverse: true,
        // Scrolling the transcript puts the iPhone keyboard away.
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        shrinkWrap: shrinkWrap,
        padding: padding,
        children: [
          for (final m in conversation.messages.reversed)
            if (m.fromUser)
              _Question(m, chat: chat)
            else
              _Answer(m, streaming: chat.streaming == conversation && m == last),
        ],
      ),
    );
  }
}

class _Question extends StatelessWidget {
  const _Question(this.m, {required this.chat});
  final ChatMessage m;
  final ChatStore chat;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 14, bottom: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (m.images.isNotEmpty) MessageImages(chat: chat, paths: m.images),
        if (m.images.isNotEmpty && m.text.isNotEmpty) const SizedBox(height: 8),
        if (m.text.isNotEmpty) Text(m.text, style: const TextStyle(fontSize: 13, height: 1.45, color: C.dim)),
      ],
    ),
  );
}

class _Answer extends StatelessWidget {
  const _Answer(this.m, {required this.streaming});
  final ChatMessage m;
  final bool streaming;

  static const _code = TextStyle(fontFamily: 'Menlo', fontSize: 12.5, color: Color(0xFFD7DAE3));

  @override
  Widget build(BuildContext context) {
    if (m.error != null) {
      return Text(m.error!, style: const TextStyle(fontSize: 13, color: Color(0xFFFCA5A5)));
    }
    if (m.text.isEmpty) {
      return Text(streaming ? '…' : '', style: const TextStyle(fontSize: 14, color: C.dim));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MarkdownBody(
          data: m.text,
          onTapLink: (_, href, _) {
            final uri = href == null ? null : Uri.tryParse(href);
            if (uri != null) unawaited(launchUrl(uri));
          },
          styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
            p: const TextStyle(fontSize: 14, height: 1.5, color: C.text),
            listBullet: const TextStyle(fontSize: 14, height: 1.5, color: C.dim),
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
        ),
        if (!streaming)
          SelectionContainer.disabled(
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Hoverable(
                onTap: () => copyAnswer(context, m.text),
                builder: (hover) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.content_copy, size: 12, color: hover ? C.text : C.dim2),
                    const SizedBox(width: 5),
                    Text('Copy', style: TextStyle(fontSize: 11, color: hover ? C.text : C.dim2)),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The main window's middle pane in Chats: every saved conversation.
class ChatList extends StatelessWidget {
  const ChatList({required this.chat, required this.selected, required this.onSelect, required this.hotKey, super.key});

  final ChatStore chat;
  final Conversation? selected;

  /// The popup's shortcut as shown (⇧⌘Space unless changed in Settings).
  final String hotKey;

  /// Null starts a new chat.
  final ValueChanged<Conversation?> onSelect;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Container(
        padding: const EdgeInsets.fromLTRB(16, 40, 16, 12),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: C.line)),
        ),
        child: Row(
          children: [
            Text.rich(
              TextSpan(
                text: 'Chats',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                children: [
                  TextSpan(
                    text: '   ${chat.conversations.length}',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w400, color: C.dim),
                  ),
                ],
              ),
            ),
            const Spacer(),
            Hoverable(
              onTap: () => onSelect(null),
              builder: (hover) => Row(
                children: [
                  Icon(Icons.add, size: 14, color: hover ? C.text : C.dim),
                  const SizedBox(width: 4),
                  Text('New chat', style: TextStyle(fontSize: 12, color: hover ? C.text : C.dim)),
                ],
              ),
            ),
          ],
        ),
      ),
      Expanded(
        child: chat.conversations.isEmpty
            ? Center(
                child: Text('Ask something with $hotKey then ⌘4.', style: const TextStyle(color: C.dim)),
              )
            : ListView(
                padding: const EdgeInsets.symmetric(vertical: 6),
                children: [
                  for (final c in chat.conversations)
                    Hoverable(
                      onTap: () => onSelect(c),
                      builder: (hover) => Container(
                        color: c == selected ? C.sel : (hover ? C.hover : null),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        child: Row(
                          children: [
                            Icon(Icons.auto_awesome, size: 12, color: chat.streaming == c ? C.accent : C.dim2),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                c.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text(stamp(c.updatedAt), style: const TextStyle(fontSize: 11, color: C.dim)),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
      ),
    ],
  );
}

/// The main window's detail pane in Chats: one conversation, continued from
/// the field at the bottom (null: a new one).
class ChatThread extends StatefulWidget {
  const ChatThread({
    required this.chat,
    required this.conversation,
    required this.onSent,
    required this.onContinue,
    super.key,
  });

  final ChatStore chat;
  final Conversation? conversation;

  /// After a send; a new chat now exists.
  final ValueChanged<Conversation> onSent;

  /// Opens [conversation] in the ⇧⌘Space popup.
  final ValueChanged<Conversation> onContinue;

  @override
  State<ChatThread> createState() => _ChatThreadState();
}

class _ChatThreadState extends State<ChatThread> {
  final _field = TextEditingController();
  late final _focus = FocusNode(onKeyEvent: _onKey);
  final _attachments = ChatAttachments();

  @override
  void initState() {
    super.initState();
    _focus.requestFocus();
  }

  @override
  void dispose() {
    _field.dispose();
    _focus.dispose();
    _attachments.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    final keys = HardwareKeyboard.instance;
    if ((k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) && !keys.isShiftPressed) {
      final text = _field.text;
      final chat = widget.chat;
      if ((text.trim().isNotEmpty || !_attachments.isEmpty) && !chat.busy) {
        _field.clear();
        unawaited(chat.send(text, into: widget.conversation, images: _attachments.take()));
        widget.onSent(chat.current!);
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyC && keys.isMetaPressed && keys.isShiftPressed) {
      copyAnswer(context, widget.conversation?.lastAnswer);
      return KeyEventResult.handled;
    }
    // An image on the clipboard is attached; text still pastes as usual.
    if (isPasteKey(e)) unawaited(_attachments.paste());
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.conversation;
    final chat = widget.chat;
    Widget action(IconData icon, String label, VoidCallback onTap) => Hoverable(
      onTap: onTap,
      builder: (hover) => Padding(
        padding: const EdgeInsets.only(left: 14),
        child: Row(
          children: [
            Icon(icon, size: 13, color: hover ? C.text : C.dim),
            const SizedBox(width: 5),
            Text(label, style: TextStyle(fontSize: 12, color: hover ? C.text : C.dim)),
          ],
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(22, 40, 18, 12),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: C.line)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  c?.title ?? 'New chat',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
              if (c != null) ...[
                action(Icons.content_copy, 'Copy last answer  ⇧⌘C', () => copyAnswer(context, c.lastAnswer)),
                action(Icons.open_in_new, 'Continue in popup', () => widget.onContinue(c)),
                action(Icons.delete_outline, 'Delete', () => chat.delete(c)),
              ],
            ],
          ),
        ),
        Expanded(
          child: c == null || c.messages.isEmpty
              ? const Center(
                  child: Text('Ask a quick question below.', style: TextStyle(color: C.dim)),
                )
              : ChatTranscript(chat: chat, conversation: c, padding: const EdgeInsets.fromLTRB(22, 10, 22, 16)),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(22, 14, 22, 14),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: C.line)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AttachmentStrip(attachments: _attachments),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Icon(Icons.auto_awesome, size: 16, color: C.accent),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _field,
                      focusNode: _focus,
                      selectionWidthStyle: selectionWidth,
                      minLines: 1,
                      maxLines: 8,
                      style: const TextStyle(fontSize: 14, height: 1.45),
                      decoration: plainInput.copyWith(
                        hintText: c == null ? 'Ask a quick question…  ↵' : 'Follow up…  ↵',
                        hintStyle: const TextStyle(color: C.dim2),
                      ),
                    ),
                  ),
                  AttachButton(attachments: _attachments, size: 16),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
