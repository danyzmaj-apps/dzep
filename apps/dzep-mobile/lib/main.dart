import 'package:dzep_core/native.dart';
import 'package:dzep_mobile/mobile.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final device = await Native.deviceName();
  final session = MobileSession(prefs, device);
  runApp(MobileApp(session: session));
  await session.start();
}
