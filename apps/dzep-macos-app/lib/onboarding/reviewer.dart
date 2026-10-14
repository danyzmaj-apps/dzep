import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dzep_core/session.dart';
import 'package:dzep_core/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// Mac Settings → Reviewer access.
Future<void> showReviewerAccess(BuildContext context, Session session) => showDialog<void>(
  context: context,
  builder: (_) => ReviewerAccessSheet(session: session),
);

/// Reviewer codes, for App Store and Google Play review: reusable codes
/// (functions/pair, action reviewer) that sign a phone into a separate demo
/// account on this server, so a reviewer gets in without the owner's Mac.
/// Make one (how long, a label), hand over its QR or link, revoke it after.
/// A code is shown only right after it's made: the server keeps a hash.
class ReviewerAccessSheet extends StatefulWidget {
  const ReviewerAccessSheet({required this.session, this.downloads, super.key});
  final Session session;

  /// Where Save QR as PNG writes; ~/Downloads if null.
  final Directory? downloads;

  @override
  State<ReviewerAccessSheet> createState() => _ReviewerAccessSheetState();
}

class _ReviewerAccessSheetState extends State<ReviewerAccessSheet> {
  static const _lifetimes = [7, 30, 90];

  final _label = TextEditingController();
  int _days = 30;
  bool _making = false;

  /// The code just made: its QR and link show until the sheet closes.
  ReviewerCode? _made;

  /// Active codes, newest first; null while loading.
  List<ReviewerCode>? _codes;
  final _revoking = <String>{};
  String? _error;

  /// What the last Copy or Save did.
  String? _note;

  Session get session => widget.session;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final codes = await session.reviewerCodes();
      if (mounted) setState(() => _codes = codes);
    } on PairingException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _make() async {
    setState(() {
      _making = true;
      _error = _note = null;
    });
    try {
      final code = await session.createReviewerCode(days: _days, label: _label.text.trim());
      if (!mounted) return;
      setState(() {
        _made = code;
        _codes = [code, ...?_codes];
        _label.clear();
      });
    } on PairingException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _making = false);
    }
  }

  Future<void> _revoke(ReviewerCode code) async {
    setState(() {
      _revoking.add(code.id);
      _error = null;
    });
    try {
      await session.revokeReviewerCode(code.id);
      if (!mounted) return;
      setState(() {
        _codes = [...?_codes?.where((c) => c.id != code.id)];
        if (_made?.id == code.id) _made = null;
      });
    } on PairingException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _revoking.remove(code.id));
    }
  }

  Future<void> _copy(Uri link) async {
    await Clipboard.setData(ClipboardData(text: '$link'));
    if (mounted) setState(() => _note = 'Link copied.');
  }

  Future<void> _save(ReviewerCode code) async {
    try {
      final dir = widget.downloads ?? Directory('${Platform.environment['HOME']}/Downloads');
      final base = 'Džep reviewer code${code.label.isEmpty ? '' : ' – ${code.label}'}'.replaceAll(RegExp('[/:]'), '-');
      var file = File('${dir.path}/$base.png');
      for (var n = 2; file.existsSync(); n++) {
        file = File('${dir.path}/$base $n.png');
      }
      await file.writeAsBytes(await qrPng('${code.link}'));
      final folder = dir.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
      if (mounted) setState(() => _note = 'Saved “${file.uri.pathSegments.last}” in $folder.');
    } on Object catch (e) {
      if (mounted) setState(() => _note = "Couldn't save the QR: $e");
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    backgroundColor: C.bar,
    title: const Text('Reviewer access'),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'For App Store or Google Play review: a code that signs a phone into a separate demo account '
              'on your server, so reviewers don\u2019t need your Mac. The demo account can\u2019t see your ideas, '
              'todos, notes or chats, but it can use Ask, which runs on your AI key. Revoke the code when the '
              'review is done.',
              style: TextStyle(color: C.dim, height: 1.45),
            ),
            const SizedBox(height: 14),
            if (_made case final made?) _madeCode(made) else _form(),
            if (_error case final e?) ...[
              const SizedBox(height: 10),
              Text(e, style: const TextStyle(color: Color(0xFFFCA5A5))),
            ],
            const SizedBox(height: 18),
            const Text('ACTIVE CODES', style: TextStyle(fontSize: 11, letterSpacing: .6, color: C.dim)),
            const SizedBox(height: 6),
            ..._list(),
          ],
        ),
      ),
    ),
    actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done'))],
  );

  Widget _form() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextField(
        controller: _label,
        enabled: !_making,
        decoration: setupField('Label, e.g. App Store review'),
        onSubmitted: (_) => unawaited(_make()),
      ),
      const SizedBox(height: 10),
      Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Padding(
            padding: EdgeInsets.only(right: 4),
            child: Text('Works for', style: TextStyle(color: C.dim)),
          ),
          for (final days in _lifetimes)
            ChoiceChip(
              label: Text('$days days'),
              selected: _days == days,
              onSelected: _making ? null : (_) => setState(() => _days = days),
            ),
        ],
      ),
      const SizedBox(height: 10),
      Align(
        alignment: Alignment.centerRight,
        child: FilledButton(
          onPressed: _making ? null : () => unawaited(_make()),
          child: _making
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Make a code'),
        ),
      ),
    ],
  );

  Widget _madeCode(ReviewerCode code) {
    final link = code.link!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
            width: 200,
            height: 200,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
            child: QrImageView(data: '$link', padding: EdgeInsets.zero),
          ),
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: C.field,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: C.line2),
          ),
          child: SelectableText('$link', style: const TextStyle(fontSize: 11.5, height: 1.4)),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            OutlinedButton(onPressed: () => unawaited(_copy(link)), child: const Text('Copy')),
            OutlinedButton(onPressed: () => unawaited(_save(code)), child: const Text('Save QR as PNG')),
            TextButton(onPressed: () => setState(() => _made = null), child: const Text('Make another')),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          _note ??
              'Works until ${_date(code.expiresAt)}, as often as needed. Give the reviewer the QR or the link '
                  '(the phone app: Paste a code instead). Shown only now: your server keeps no copy.',
          style: const TextStyle(fontSize: 11.5, color: C.dim2, height: 1.4),
        ),
      ],
    );
  }

  List<Widget> _list() {
    final codes = _codes;
    if (codes == null) {
      return [
        if (_error == null)
          const Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
      ];
    }
    if (codes.isEmpty) return const [Text('None.', style: TextStyle(color: C.dim2))];
    return [
      for (final c in codes)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(c.label.isEmpty ? 'Reviewer code' : c.label, style: const TextStyle(fontSize: 13)),
                    Text(
                      'Until ${_date(c.expiresAt)} · '
                      '${c.lastUsedAt == null ? 'not used yet' : 'last used ${_date(c.lastUsedAt!)}'}',
                      style: const TextStyle(fontSize: 11, color: C.dim),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: _revoking.contains(c.id) ? null : () => unawaited(_revoke(c)),
                style: TextButton.styleFrom(foregroundColor: const Color(0xFFFCA5A5)),
                child: const Text('Revoke'),
              ),
            ],
          ),
        ),
    ];
  }

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  /// "14 Nov 2026".
  static String _date(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';
}

/// [data] as a QR on white with a quiet margin, as PNG bytes: something to
/// attach to the App Store or Play review notes.
Future<Uint8List> qrPng(String data, {double size = 1024}) async {
  const margin = 64.0;
  final side = size + 2 * margin;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)
    ..drawRect(Rect.fromLTWH(0, 0, side, side), Paint()..color = Colors.white)
    ..translate(margin, margin);
  QrPainter(data: data, version: QrVersions.auto, gapless: true).paint(canvas, Size.square(size));
  final image = await recorder.endRecording().toImage(side.round(), side.round());
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return bytes!.buffer.asUint8List();
}
