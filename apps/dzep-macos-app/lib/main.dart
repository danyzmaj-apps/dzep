import 'dart:async';

import 'package:dzep_core/native.dart';
import 'package:dzep_core/ui.dart';
import 'package:dzep_macos/controller.dart';
import 'package:dzep_macos/local_api.dart';
import 'package:dzep_macos/main_window.dart';
import 'package:dzep_macos/note_window.dart';
import 'package:dzep_macos/popup.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final device = await Native.deviceName();
  final app = AppController(prefs, device);
  final api = LocalApi(() => app.store, app.live);
  try {
    await api.start();
    app.onQuit = api.stop;
  } on Object catch (e) {
    debugPrint('Džep: terminal API unavailable: $e');
  }
  // The engine runs in multi-view mode: the popup panel, the main window and
  // the note window are separate Flutter views of this one app.
  runWidget(DzepWindows(app: app, ids: await Native.viewIds()));
  await app.start();
}

/// One [View] per native window, each with its own [MaterialApp]; both read
/// the same [AppController].
class DzepWindows extends StatefulWidget {
  const DzepWindows({required this.app, required this.ids, super.key});
  final AppController app;
  final ({int popup, int main, int note}) ids;

  @override
  State<DzepWindows> createState() => _DzepWindowsState();
}

class _DzepWindowsState extends State<DzepWindows> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Views can arrive after the first build.
  @override
  void didChangeMetrics() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    // Built inside the builder, so every change to [app] rebuilds the
    // window's content (a prebuilt child would be reused as is, and screens
    // reading app state — the Settings sheet — would never update).
    Widget window(Widget Function() content) => MaterialApp(
      title: 'Džep',
      debugShowCheckedModeBanner: false,
      theme: appTheme(),
      color: Colors.transparent,
      home: Material(
        type: MaterialType.transparency,
        child: Toaster(
          child: ListenableBuilder(listenable: app, builder: (_, _) => content()),
        ),
      ),
    );

    return ViewCollection(
      views: [
        for (final view in WidgetsBinding.instance.platformDispatcher.views)
          if (view.viewId == widget.ids.popup)
            View(
              view: view,
              // Stays mounted while hidden so it resets and takes keys the
              // moment the hotkey fires, before the next frame.
              child: window(
                () => Offstage(
                  offstage: !app.popupOpen,
                  child: Popup(app: app),
                ),
              ),
            )
          else if (view.viewId == widget.ids.main)
            View(
              view: view,
              child: window(() => MainWindow(app: app)),
            )
          else if (view.viewId == widget.ids.note)
            View(
              view: view,
              child: window(() => NoteWindow(app: app)),
            ),
      ],
    );
  }
}
