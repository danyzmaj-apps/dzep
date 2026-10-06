import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:app_links/app_links.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ideja/idea.dart';
import 'package:ideja/main_window.dart' show Avatar, SignInPage;
import 'package:ideja/popup.dart' show parseTitle;
import 'package:ideja/session.dart';
import 'package:ideja/store.dart';
import 'package:ideja/ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The iPhone side of [Session]: registers a device token for the Siri /
/// Action Button intent (ios/Runner/AddIdeaIntent.swift) and saves ideas the
/// intent had to queue while offline.
class MobileSession extends Session {
  MobileSession(super.client, this._prefs, super.device);

  final SharedPreferences _prefs;

  // Read by AddIdeaIntent.swift as UserDefaults "flutter.<key>".
  static const _tokenKey = 'ideja_device_token';
  static const _tokenUserKey = 'ideja_device_token_user';
  static const _pendingKey = 'ideja_pending';

  static String _hash(String token) => sha256.convert(utf8.encode(token)).toString();

  @override
  Future<void> onSignedIn(IdeaStore store) async {
    await drainPending();
    if (_prefs.getString(_tokenKey) != null && _prefs.getString(_tokenUserKey) == store.userId) return;
    final token = List.generate(32, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    try {
      await client.from('device_tokens').insert({'token_hash': _hash(token), 'label': device});
      await _prefs.setString(_tokenKey, token);
      await _prefs.setString(_tokenUserKey, store.userId);
    } on Object catch (e) {
      // Siri can't save directly until this works; retried on next launch.
      debugPrint('Ideja: device token registration failed: $e');
    }
  }

  @override
  Future<void> onSigningOut() async {
    final token = _prefs.getString(_tokenKey);
    await _prefs.remove(_tokenKey);
    await _prefs.remove(_tokenUserKey);
    if (token != null) await client.from('device_tokens').delete().eq('token_hash', _hash(token));
  }

  /// Ideas Siri captured offline (the intent appends JSON strings).
  Future<void> drainPending() async {
    final store = this.store;
    if (store == null) return;
    await _prefs.reload();
    final pending = _prefs.getStringList(_pendingKey) ?? const [];
    if (pending.isEmpty) return;
    for (final raw in pending) {
      try {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        store.add(title: j['title'] as String? ?? '', notes: j['notes'] as String? ?? '');
      } on Object catch (e) {
        debugPrint('Ideja: dropped unreadable queued idea: $e');
      }
    }
    await _prefs.remove(_pendingKey);
  }
}

class MobileApp extends StatelessWidget {
  const MobileApp({required this.session, super.key});
  final MobileSession session;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Ideja',
    debugShowCheckedModeBanner: false,
    theme: appTheme().copyWith(
      scaffoldBackgroundColor: C.win,
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: Color(0xFF1F2A22),
        contentTextStyle: TextStyle(color: Color(0xFFBBF7D0)),
        actionTextColor: Colors.white,
      ),
    ),
    home: ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final store = session.store;
        if (store == null) {
          return Scaffold(
            body: SafeArea(child: SignInPage(session: session)),
          );
        }
        return HomePage(session: session, store: store);
      },
    ),
  );
}

// ==================================================================== home

typedef _Filter = ({bool project, String id});

class HomePage extends StatefulWidget {
  const HomePage({required this.session, required this.store, super.key});
  final MobileSession session;
  final IdeaStore store;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  _Filter _filter = (project: false, id: 'inbox');
  String _query = '';
  final _search = TextEditingController();
  StreamSubscription<Uri>? _links;

  IdeaStore get store => widget.store;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // The widget opens ideja://add. The stream also carries the link that
    // cold-started the app, so getInitialLink() would handle it twice.
    _links = AppLinks().uriLinkStream.listen(_onLink);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_links?.cancel());
    _search.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(widget.session.drainPending());
      unawaited(store.syncNow());
    }
  }

  void _onLink(Uri? uri) {
    if (uri == null || uri.scheme != 'ideja' || uri.host != 'add' || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_openAdd()));
  }

  bool _addOpen = false;

  Future<void> _openAdd() async {
    if (_addOpen) return;
    _addOpen = true;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: C.bar,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => AddSheet(store: store, defaultProject: _filter.project ? _filter.id : ''),
    );
    _addOpen = false;
  }

  bool _matches(Idea i) {
    if (_filter.project) {
      if (i.project != _filter.id) return false;
    } else if (_filter.id != 'all' && i.status.name != _filter.id) {
      return false;
    }
    final hay = '${i.title} ${i.notes} @${i.project}'.toLowerCase();
    return _query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).every(hay.contains);
  }

  void _delete(Idea i) {
    store.delete(i);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('Idea deleted'),
          action: SnackBarAction(label: 'Undo', onPressed: () => store.restore(i)),
        ),
      );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final ideas = store.ideas.where(_matches).toList();
      return Scaffold(
        floatingActionButton: FloatingActionButton(
          key: const ValueKey('add'),
          tooltip: 'New idea',
          backgroundColor: C.accent,
          foregroundColor: const Color(0xFF0E0F12),
          onPressed: () => unawaited(_openAdd()),
          child: const Icon(Icons.add, size: 28),
        ),
        body: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 12, 4),
                child: Row(
                  children: [
                    const Text('💡', style: TextStyle(fontSize: 22)),
                    const SizedBox(width: 8),
                    const Text('Ideja', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
                    const Spacer(),
                    SyncDot(store.syncState),
                    IconButton(
                      tooltip: 'Account',
                      onPressed: () => unawaited(_openAccount()),
                      icon: Avatar(url: widget.session.avatarUrl, name: widget.session.userName, size: 28),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
                child: TextField(
                  controller: _search,
                  onChanged: (q) => setState(() => _query = q),
                  style: const TextStyle(fontSize: 15),
                  decoration: InputDecoration(
                    hintText: 'Search',
                    hintStyle: const TextStyle(color: C.dim2),
                    prefixIcon: const Icon(Icons.search, color: C.dim, size: 20),
                    filled: true,
                    fillColor: C.field,
                    isDense: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                  ),
                ),
              ),
              SizedBox(height: 38, child: _filters()),
              const Divider(height: 1, color: C.line),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: store.syncNow,
                  child: ideas.isEmpty
                      ? ListView(
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(40),
                              child: Text(
                                _query.isNotEmpty
                                    ? 'No matches.'
                                    : _filter.id == 'inbox'
                                    ? 'Inbox zero 🎉\nTap + or say “Hey Siri, add an idea to Ideja”.'
                                    : 'Nothing here yet.',
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: C.dim, height: 1.5),
                              ),
                            ),
                          ],
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.only(bottom: 96),
                          itemCount: ideas.length,
                          itemBuilder: (context, k) => _row(ideas[k]),
                        ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  Widget _filters() {
    Widget chip(_Filter f, String label, {Color? dot}) {
      final on = _filter == f;
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: ChoiceChip(
          selected: on,
          showCheckmark: false,
          onSelected: (_) => setState(() => _filter = f),
          backgroundColor: C.field,
          selectedColor: C.sel,
          side: BorderSide(color: on ? C.accent : C.line2),
          avatar: dot == null ? null : Dot(dot),
          label: Text(label, style: TextStyle(fontSize: 13, color: on ? C.text : C.dim)),
          visualDensity: VisualDensity.compact,
        ),
      );
    }

    return ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        chip((project: false, id: 'inbox'), 'Inbox'),
        chip((project: false, id: 'all'), 'All'),
        for (final s in Status.values.skip(1)) chip((project: false, id: s.name), s.label, dot: s.color),
        for (final p in store.projects) chip((project: true, id: p), '@$p'),
      ],
    );
  }

  Widget _row(Idea i) {
    final faded = i.status == Status.shipped || i.status == Status.dropped;
    final firstNote = i.notes.split('\n').first;
    return Dismissible(
      key: ValueKey(i.id),
      direction: DismissDirection.endToStart,
      background: Container(
        color: const Color(0xFF7F1D1D),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        child: const Icon(Icons.delete_outline, color: Colors.white),
      ),
      onDismissed: (_) => _delete(i),
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => DetailPage(idea: i, store: store),
          ),
        ),
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: Color(0xFF1D1F25))),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(padding: const EdgeInsets.only(top: 6), child: Dot(i.status.color)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text.rich(
                      highlight(
                        i.title.isEmpty ? 'Untitled' : i.title,
                        _query,
                        TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: faded ? C.dim : C.text,
                          decoration: i.status == Status.dropped ? TextDecoration.lineThrough : null,
                          decorationColor: C.dim,
                        ),
                      ),
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
              const SizedBox(width: 8),
              Text(ago(i.createdAt), style: const TextStyle(fontSize: 12, color: C.dim2)),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openAccount() => showModalBottomSheet<void>(
    context: context,
    backgroundColor: C.bar,
    builder: (sheet) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Avatar(url: widget.session.avatarUrl, name: widget.session.userName, size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.session.userName, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                      Text('${store.ideas.length} ideas · signed in with GitHub', style: const TextStyle(color: C.dim)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            const Text('Capture without opening the app', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            const Text(
              '• Say “Hey Siri, add an idea to Ideja”.\n'
              '• Action Button: Settings → Action Button → Shortcut → Ideja → Add Idea.\n'
              '• Add the Ideja widget to your Home or Lock Screen.',
              style: TextStyle(color: C.dim, height: 1.6),
            ),
            const SizedBox(height: 18),
            OutlinedButton(
              onPressed: () {
                Navigator.of(sheet).pop();
                unawaited(widget.session.signOut());
              },
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFFCA5A5),
                side: const BorderSide(color: C.line2),
              ),
              child: const Text('Sign out'),
            ),
          ],
        ),
      ),
    ),
  );
}

// ==================================================================== add

class AddSheet extends StatefulWidget {
  const AddSheet({required this.store, required this.defaultProject, super.key});
  final IdeaStore store;
  final String defaultProject;

  @override
  State<AddSheet> createState() => _AddSheetState();
}

class _AddSheetState extends State<AddSheet> {
  final _title = TextEditingController();
  final _notes = TextEditingController();
  late String _project = widget.defaultProject;

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _save() {
    final parsed = parseTitle(_title.text);
    if (parsed.title.isEmpty) return;
    widget.store.add(
      title: parsed.title,
      notes: _notes.text,
      project: parsed.project.isNotEmpty ? parsed.project : _project,
    );
    unawaited(HapticFeedback.lightImpact());
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved to Inbox ✓')));
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey('add-title'),
              controller: _title,
              autofocus: true,
              textInputAction: TextInputAction.done,
              textCapitalization: TextCapitalization.sentences,
              style: const TextStyle(fontSize: 19, height: 1.35),
              decoration: plainInput.copyWith(
                hintText: 'Drop an idea…',
                hintStyle: const TextStyle(color: C.dim2),
              ),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('add-notes'),
              controller: _notes,
              minLines: 2,
              maxLines: 6,
              textCapitalization: TextCapitalization.sentences,
              style: const TextStyle(fontSize: 15, height: 1.5, color: Color(0xFFC9CCD5)),
              decoration: plainInput.copyWith(
                hintText: 'Description (optional)',
                hintStyle: const TextStyle(color: C.dim2),
              ),
            ),
            if (widget.store.projects.isNotEmpty) ...[
              const SizedBox(height: 12),
              SizedBox(
                height: 34,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final p in widget.store.projects)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          selected: _project == p,
                          showCheckmark: false,
                          onSelected: (on) => setState(() => _project = on ? p : ''),
                          backgroundColor: C.field,
                          selectedColor: C.projectBg,
                          side: BorderSide(color: _project == p ? C.projectFg : C.line2),
                          label: Text(
                            '@$p',
                            style: TextStyle(fontSize: 12, color: _project == p ? C.projectFg : C.dim),
                          ),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 14),
            ListenableBuilder(
              listenable: _title,
              builder: (context, _) => FilledButton(
                key: const ValueKey('add-save'),
                onPressed: _title.text.trim().isEmpty ? null : _save,
                style: FilledButton.styleFrom(
                  backgroundColor: C.accent,
                  foregroundColor: const Color(0xFF0E0F12),
                  minimumSize: const Size.fromHeight(46),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: const Text('Save', style: TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

// ==================================================================== detail

class DetailPage extends StatefulWidget {
  const DetailPage({required this.idea, required this.store, super.key});
  final Idea idea;
  final IdeaStore store;

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  late final _title = TextEditingController(text: widget.idea.title);
  late final _notes = TextEditingController(text: widget.idea.notes);
  late final _project = TextEditingController(text: widget.idea.project);

  Idea get idea => widget.idea;

  @override
  void dispose() {
    final p = _project.text.trim().replaceFirst(RegExp('^@'), '');
    if (p != idea.project) widget.store.update(idea, project: p);
    _title.dispose();
    _notes.dispose();
    _project.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      backgroundColor: C.win,
      surfaceTintColor: Colors.transparent,
      actions: [
        IconButton(
          tooltip: 'Delete',
          icon: const Icon(Icons.delete_outline, color: C.dim),
          onPressed: () {
            widget.store.delete(idea);
            Navigator.of(context).pop();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text('Idea deleted'),
                action: SnackBarAction(label: 'Undo', onPressed: () => widget.store.restore(idea)),
              ),
            );
          },
        ),
      ],
    ),
    body: ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 40),
        children: [
          TextField(
            controller: _title,
            maxLines: null,
            textCapitalization: TextCapitalization.sentences,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
            decoration: plainInput.copyWith(
              hintText: 'Untitled idea',
              hintStyle: const TextStyle(color: C.dim2),
            ),
            onChanged: (t) => widget.store.update(idea, title: t),
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final s in Status.values)
                ChoiceChip(
                  selected: idea.status == s,
                  showCheckmark: false,
                  onSelected: (_) => widget.store.update(idea, status: s),
                  backgroundColor: C.field,
                  selectedColor: C.sel,
                  side: BorderSide(color: idea.status == s ? C.accent : C.line2),
                  avatar: Dot(s.color),
                  label: Text(s.label, style: TextStyle(color: idea.status == s ? C.text : C.dim)),
                ),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _project,
            style: const TextStyle(fontSize: 14, color: C.projectFg),
            decoration: InputDecoration(
              prefixText: '@ ',
              prefixStyle: const TextStyle(color: C.dim),
              hintText: 'project',
              hintStyle: const TextStyle(color: C.dim2),
              filled: true,
              fillColor: C.field,
              isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _notes,
            maxLines: null,
            minLines: 8,
            textCapitalization: TextCapitalization.sentences,
            style: const TextStyle(fontSize: 16, height: 1.6, color: Color(0xFFD7DAE2)),
            decoration: plainInput.copyWith(
              hintText: 'Description: context, links, how it could work…',
              hintStyle: const TextStyle(color: C.dim2),
            ),
            onChanged: (t) => widget.store.update(idea, notes: t),
          ),
          const SizedBox(height: 24),
          Text(
            'Added ${ago(idea.createdAt)} ago${idea.device.isEmpty ? '' : ' on ${idea.device}'}',
            style: const TextStyle(fontSize: 12, color: C.dim2),
          ),
        ],
      ),
    ),
  );
}
