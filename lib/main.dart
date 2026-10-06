import 'dart:async';
import 'dart:io';

import 'package:dzep/controller.dart';
import 'package:dzep/local_api.dart';
import 'package:dzep/main_window.dart';
import 'package:dzep/mobile.dart';
import 'package:dzep/native.dart';
import 'package:dzep/popup.dart';
import 'package:dzep/ui.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The Supabase project (publishable key: safe in the client, RLS guards
/// the data).
const supabaseUrl = 'https://tgqmhieundubwtyvsnih.supabase.co';
const supabaseKey = 'sb_publishable_THRH7YNiM27mZTwXcWY7Rg_emvQ5ncw';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final supabase = await Supabase.initialize(url: supabaseUrl, publishableKey: supabaseKey);
  final prefs = await SharedPreferences.getInstance();
  final device = await Native.deviceName();
  if (Platform.isIOS) {
    final session = MobileSession(supabase.client, prefs, device);
    runApp(MobileApp(session: session));
    await session.startAuth();
    return;
  }
  final app = AppController(supabase.client, prefs, device);
  final api = LocalApi(() => app.store);
  try {
    await api.start();
  } on Object catch (e) {
    debugPrint('Džep: terminal API unavailable: $e');
  }
  runApp(DzepApp(app: app));
  await app.start();
}

class DzepApp extends StatelessWidget {
  const DzepApp({required this.app, super.key});
  final AppController app;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Džep',
    debugShowCheckedModeBanner: false,
    theme: appTheme(),
    color: Colors.transparent,
    home: Material(
      type: MaterialType.transparency,
      child: Toaster(
        child: ListenableBuilder(
          listenable: app,
          // The popup stays mounted when hidden so it can reset and take keys
          // the moment the hotkey fires, before the next frame.
          // StackFit.expand: a hidden Offstage takes no size, which would
          // shrink the Stack (and the main window inside it) to nothing.
          builder: (context, _) => Stack(
            fit: StackFit.expand,
            children: [
              Offstage(
                offstage: app.mode != Mode.popup,
                child: Popup(app: app),
              ),
              if (app.mode == Mode.main) Positioned.fill(child: MainWindow(app: app)),
            ],
          ),
        ),
      ),
    ),
  );
}
