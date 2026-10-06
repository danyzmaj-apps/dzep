import 'dart:async';

import 'package:dzep/store.dart';
import 'package:flutter/material.dart';

/// The mockup's palette (design/mockup.html).
abstract final class C {
  static const win = Color(0xFF17181D);
  static const side = Color(0xFF121317);
  static const bar = Color(0xFF1E2027);
  static const field = Color(0xFF1D1F26);
  static const hover = Color(0xFF1B1D24);
  static const sel = Color(0xFF262B3D);
  static const line = Color(0xFF262933);
  static const line2 = Color(0xFF30343F);
  static const text = Color(0xFFE8E9EE);
  static const dim = Color(0xFF8A8F9C);
  static const dim2 = Color(0xFF5C616E);
  static const accent = Color(0xFF7C9CFF);
  static const ok = Color(0xFF4ADE80);
  static const warn = Color(0xFFFBBF24);
  static const projectBg = Color(0xFF22302A);
  static const projectFg = Color(0xFF86EFAC);
  static const projectLine = Color(0xFF2C4636);
}

ThemeData appTheme() {
  final base = ThemeData(brightness: Brightness.dark, useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: Colors.transparent,
    colorScheme: base.colorScheme.copyWith(primary: C.accent, surface: C.win),
    textTheme: base.textTheme.apply(bodyColor: C.text, displayColor: C.text),
    textSelectionTheme: const TextSelectionThemeData(cursorColor: C.accent, selectionColor: Color(0x557C9CFF)),
    tooltipTheme: const TooltipThemeData(waitDuration: Duration(milliseconds: 500)),
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: Colors.transparent,
  );
}

const plainInput = InputDecoration(border: InputBorder.none, isCollapsed: true, contentPadding: EdgeInsets.zero);

class Kbd extends StatelessWidget {
  const Kbd(this.label, {super.key});
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
    decoration: BoxDecoration(
      color: const Color(0xFF262833),
      borderRadius: BorderRadius.circular(5),
      border: const Border(
        top: BorderSide(color: Color(0xFF363A47)),
        left: BorderSide(color: Color(0xFF363A47)),
        right: BorderSide(color: Color(0xFF363A47)),
        bottom: BorderSide(color: Color(0xFF363A47), width: 2),
      ),
    ),
    child: Text(
      label,
      style: const TextStyle(fontSize: 11, color: Color(0xFFCFD3DD), fontFamily: 'Menlo'),
    ),
  );
}

/// "⏎ save" style hint.
class KeyHint extends StatelessWidget {
  const KeyHint(this.keys, this.label, {super.key});
  final String keys;
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 12),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Kbd(keys),
        const SizedBox(width: 5),
        Text(label, style: const TextStyle(fontSize: 12, color: C.dim)),
      ],
    ),
  );
}

class Dot extends StatelessWidget {
  const Dot(this.color, {super.key, this.size = 8});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

/// A todo's round checkbox.
class TodoCheck extends StatelessWidget {
  const TodoCheck({required this.done, this.size = 16, super.key});
  final bool done;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: done ? C.ok : null,
      border: Border.all(color: done ? C.ok : const Color(0xFF5A606E), width: 1.5),
    ),
    child: done ? Icon(Icons.check, size: size * .7, color: const Color(0xFF111111)) : null,
  );
}

class ProjectChip extends StatelessWidget {
  const ProjectChip(this.name, {super.key});
  final String name;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
    decoration: BoxDecoration(
      color: C.projectBg,
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: C.projectLine),
    ),
    child: Text('@$name', style: const TextStyle(fontSize: 11, color: C.projectFg)),
  );
}

class SyncDot extends StatelessWidget {
  const SyncDot(this.state, {super.key});
  final SyncState? state;

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (state) {
      SyncState.synced => (C.ok, 'Synced'),
      SyncState.syncing => (C.warn, 'Syncing…'),
      SyncState.offline => (C.warn, 'Offline · saved on this Mac'),
      null => (const Color(0xFF6B7280), 'Signed out'),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Dot(color, size: 7),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 12, color: C.dim)),
      ],
    );
  }
}

String ago(DateTime t) {
  final s = DateTime.now().difference(t).inSeconds;
  if (s < 60) return 'now';
  if (s < 3600) return '${s ~/ 60}m';
  if (s < 86400) return '${s ~/ 3600}h';
  return '${s ~/ 86400}d';
}

/// Text with every query word highlighted.
TextSpan highlight(String text, String query, TextStyle style) {
  final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.length > 1).toList();
  if (words.isEmpty) return TextSpan(text: text, style: style);
  final lower = text.toLowerCase();
  final marks = List<bool>.filled(text.length, false);
  for (final w in words) {
    var i = lower.indexOf(w);
    while (i >= 0) {
      for (var k = i; k < i + w.length; k++) {
        marks[k] = true;
      }
      i = lower.indexOf(w, i + w.length);
    }
  }
  final spans = <TextSpan>[];
  var start = 0;
  for (var i = 1; i <= text.length; i++) {
    if (i == text.length || marks[i] != marks[start]) {
      spans.add(
        TextSpan(
          text: text.substring(start, i),
          style: marks[start]
              ? style.copyWith(color: const Color(0xFFC7D2FF), backgroundColor: const Color(0x2E7C9CFF))
              : style,
        ),
      );
      start = i;
    }
  }
  return TextSpan(children: spans);
}

/// A small bottom toast with an optional Undo.
class Toaster extends StatefulWidget {
  const Toaster({required this.child, super.key});
  final Widget child;

  static ToasterState of(BuildContext context) => context.findAncestorStateOfType<ToasterState>()!;

  @override
  State<Toaster> createState() => ToasterState();
}

class ToasterState extends State<Toaster> {
  String? _text;
  VoidCallback? _undo;
  Timer? _timer;

  void show(String text, {VoidCallback? undo}) {
    _timer?.cancel();
    setState(() {
      _text = text;
      _undo = undo;
    });
    _timer = Timer(Duration(milliseconds: undo == null ? 1600 : 4000), () {
      if (mounted) setState(() => _text = null);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      widget.child,
      Positioned(
        left: 0,
        right: 0,
        bottom: 24,
        child: IgnorePointer(
          ignoring: _text == null,
          child: AnimatedOpacity(
            opacity: _text == null ? 0 : 1,
            duration: const Duration(milliseconds: 200),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF1F2A22),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: C.projectLine),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_text ?? '', style: const TextStyle(color: Color(0xFFBBF7D0), fontSize: 13)),
                    if (_undo != null) ...[
                      const SizedBox(width: 12),
                      GestureDetector(
                        onTap: () {
                          _undo?.call();
                          setState(() => _text = null);
                        },
                        child: const MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: Text(
                            'Undo',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              decoration: TextDecoration.underline,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ],
  );
}

/// Hover background for clickable rows.
class Hoverable extends StatefulWidget {
  const Hoverable({required this.builder, this.onTap, super.key});
  // ignore: avoid_positional_boolean_parameters, a builder callback's shape.
  final Widget Function(bool hover) builder;
  final VoidCallback? onTap;

  @override
  State<Hoverable> createState() => _HoverableState();
}

class _HoverableState extends State<Hoverable> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: widget.onTap, child: widget.builder(_hover)),
  );
}
