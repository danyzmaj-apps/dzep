import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:ideja/controller.dart';
import 'package:ideja/local_api.dart';
import 'package:ideja/main_window.dart';
import 'package:ideja/mobile.dart';
import 'package:ideja/native.dart';
import 'package:ideja/popup.dart';
import 'package:ideja/ui.dart';
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
    debugPrint('Ideja: terminal API unavailable: $e');
  }
  runApp(IdejaApp(app: app));
  await app.start();
}

class IdejaApp extends StatelessWidget {
  const IdejaApp({required this.app, super.key});
  final AppController app;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Ideja',
    debugShowCheckedModeBanner: false,
    theme: appTheme(),
    color: Colors.transparent,
    home: Material(
      type: MaterialType.transparency,
      child: Toaster(
        child: ListenableBuilder(
          listenable: app,
          builder: (context, _) => switch (app.mode) {
            Mode.popup => Popup(app: app),
            Mode.main => MainWindow(app: app),
            Mode.hidden => const SizedBox.shrink(),
          },
        ),
      ),
    ),
  );
}
