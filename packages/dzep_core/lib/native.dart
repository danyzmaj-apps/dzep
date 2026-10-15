import 'dart:async';
import 'dart:io';

import 'package:dzep_core/remind.dart';
import 'package:flutter/services.dart';

/// What functions/push calls this phone's push service: APNs on iOS, FCM on
/// Android.
String get pushPlatform => Platform.isAndroid ? 'android' : 'ios';

/// The native side: the Mac's (apps/dzep-macos-app/macos/Runner/MainFlutterWindow.swift: the
/// popup panel and the main window, menu-bar icon, global hotkey, launch at
/// login), the iPhone's (apps/dzep-mobile/ios/Runner/AppDelegate.swift) and Android's
/// (apps/dzep-mobile/android/app/src/main/kotlin/com/danyzmaj/dzep/MainActivity.kt).
class Native {
  static const _channel = MethodChannel('dzep/native');

  /// Events from the native side: hotKey, togglePopup, openMain,
  /// openSettings, blur (the popup lost focus), mainClosed (⌘W), closeNote
  /// (the note window's ⌘W or red button), noteKey ({key}: the note window
  /// got or lost the keyboard), openTodo ({id}: a reminder notification was
  /// clicked), openTerminal ({session}: a terminal push was tapped; see
  /// [takeTappedSession]), pending (an action waits in [takePending], e.g. a
  /// tick from the desktop widget), activityToken ({key, token}: a followed
  /// session's push token, new or changed), activityEnded ({key, token?}: it
  /// ended or was swiped away), pushToken (Android: FCM changed this
  /// phone's token; register again) and quitting (the Mac app is about to
  /// quit: it waits up to a second for what [onEvent] returns).
  static void listen(FutureOr<void> Function(String event, Map<Object?, Object?> args) onEvent) {
    _channel.setMethodCallHandler((call) async {
      await onEvent(call.method, call.arguments as Map<Object?, Object?>? ?? const {});
    });
  }

  /// Which Flutter view is which window (the engine runs in multi-view mode).
  static Future<({int popup, int main, int note})> viewIds() async {
    final ids = await _channel.invokeMapMethod<String, int>('viewIds');
    return (popup: ids!['popup']!, main: ids['main']!, note: ids['note']!);
  }

  static Future<void> showPopup() => _channel.invokeMethod('showPopup');
  static Future<void> hidePopup() => _channel.invokeMethod('hidePopup');
  static Future<void> showMain() => _channel.invokeMethod('showMain');

  /// [hideMain]: the main window gives way to the note window.
  static Future<void> showNote({required bool hideMain}) => _channel.invokeMethod('showNote', {'hideMain': hideMain});
  static Future<void> hideNote() => _channel.invokeMethod('hideNote');
  static Future<void> quit() => _channel.invokeMethod('quit');
  static Future<void> startDrag() => _channel.invokeMethod('startDrag');
  static Future<void> setTodoCount(int count) => _channel.invokeMethod('setTodoCount', {'count': count});

  /// Mac: seconds since the last keyboard or mouse input.
  static Future<double> idleSeconds() async => await _channel.invokeMethod<double>('idleSeconds') ?? 0;

  /// Mac: a folder picker (sheet on the main window); the folders chosen,
  /// none if cancelled.
  static Future<List<String>> pickFolders() async => await _channel.invokeListMethod<String>('pickFolders') ?? const [];

  // Mac and phone: todo reminders, as local notifications.
  /// Replaces every pending reminder with [reminders] (lib/remind.dart picks
  /// them); the first non-empty set asks for permission.
  static Future<void> setReminders(List<Reminder> reminders) => _channel.invokeMethod('setReminders', {
    'reminders': [
      for (final r in reminders) {'id': r.id, 'title': r.title, 'at': r.at.millisecondsSinceEpoch},
    ],
  });

  /// Phone: the todo whose reminder was tapped, once (a tap that launched
  /// the app lands before Dart listens, so openTodo only says "look").
  static Future<String?> takeTappedTodo() => _channel.invokeMethod<String>('takeTappedTodo');

  /// Phone: the coding session (its key) whose terminal push was tapped, once.
  static Future<String?> takeTappedSession() => _channel.invokeMethod<String>('takeTappedSession');

  /// Phone: asks for notification permission and this phone's push token
  /// (APNs on iOS, FCM on Android), with its push key. Null: not allowed, or
  /// no token (APNs didn't answer; an Android build without Firebase).
  static Future<({String token, String key})?> registerPush() async {
    final m = await _channel.invokeMapMethod<String, String>('registerPush');
    final token = m?['token'];
    final key = m?['key'];
    return token == null || key == null ? null : (token: token, key: key);
  }

  // Phone: followed coding sessions, as Live Activities on iOS
  // (apps/dzep-mobile/ios/Shared/SessionActivity.swift) and ongoing notifications on Android
  // (SessionActivities.kt); lib/live_activity.dart. [since]: when it got into
  // [state].

  /// Starts one for session [key], or updates the one it has; false when
  /// Live Activities (iOS) or notifications (Android) are off for Džep.
  static Future<bool> startActivity({
    required String key,
    required String title,
    required String project,
    required String state,
    required DateTime since,
    String? kind,
  }) async =>
      await _channel.invokeMethod<bool>('startActivity', {
        'key': key,
        'title': title,
        'project': project,
        'state': state,
        'kind': ?kind,
        'since': since.millisecondsSinceEpoch,
      }) ??
      false;

  static Future<void> updateActivity({
    required String key,
    required String state,
    required DateTime since,
    String? kind,
  }) => _channel.invokeMethod('updateActivity', {
    'key': key,
    'state': state,
    'kind': ?kind,
    'since': since.millisecondsSinceEpoch,
  });

  /// [immediate]: gone at once (the person ended it), else Ended shows for
  /// a few minutes.
  static Future<void> endActivity(String key, {bool immediate = false}) =>
      _channel.invokeMethod('endActivity', {'key': key, 'immediate': immediate});

  /// The running ones: their session keys and push tokens (if iOS has
  /// handed one over yet; on Android, the phone's FCM token).
  static Future<List<({String key, String? token})>> liveActivities() async => [
    for (final m
        in await _channel.invokeListMethod<Map<Object?, Object?>>('liveActivities') ?? const <Map<Object?, Object?>>[])
      (key: m['key']! as String, token: m['token'] as String?),
  ];

  // What the widgets read:
  // apps/dzep-mobile/ios/Shared/DzepShared.swift, android/…/DzepShared.kt.
  static Future<void> setSharedToken(String? token) => _channel.invokeMethod('setSharedToken', {'token': token});

  /// Null on the Mac's sign-out, which its widget shows as signed out (the
  /// phone's goes with the token).
  static Future<void> setSharedTodos(List<Map<String, String>>? todos) =>
      _channel.invokeMethod('setSharedTodos', {'todos': todos});
  static Future<List<String>> takePending() async =>
      (await _channel.invokeListMethod<String>('takePending')) ?? const [];

  static Future<bool> setHotKey(HotKey key) async =>
      await _channel.invokeMethod<bool>('setHotKey', {'keyCode': key.keyCode, 'modifiers': key.carbonModifiers}) ??
      false;

  /// The backend (lib/backend.dart) kept where the widgets read it.
  static Future<({String url, String key})?> getBackend() async {
    final m = await _channel.invokeMapMethod<String, String>('getBackend');
    final url = m?['url'];
    final key = m?['key'];
    return url == null || key == null ? null : (url: url, key: key);
  }

  /// Null for both forgets it.
  static Future<void> setBackend({String? url, String? key}) =>
      _channel.invokeMethod('setBackend', {'url': url, 'key': key});

  static Future<String> deviceName() async => await _channel.invokeMethod<String>('deviceName') ?? 'Mac';

  /// Phone: keeps the screen from dimming and locking while [on].
  static Future<void> setKeepAwake({required bool on}) => _channel.invokeMethod('setKeepAwake', {'on': on});
  static Future<bool> launchAtLogin() async => await _channel.invokeMethod<bool>('launchAtLogin') ?? false;
  static Future<bool> setLaunchAtLogin({required bool enabled}) async =>
      await _channel.invokeMethod<bool>('setLaunchAtLogin', {'enabled': enabled}) ?? false;
}

/// A global shortcut as macOS registers it: a virtual key code (kVK_*) plus
/// modifiers.
class HotKey {
  const HotKey({
    required this.keyCode,
    required this.command,
    required this.shift,
    required this.option,
    required this.control,
  });

  factory HotKey.decode(String s) {
    final p = s.split(',').map(int.parse).toList();
    return HotKey(keyCode: p[0], command: p[1] == 1, shift: p[2] == 1, option: p[3] == 1, control: p[4] == 1);
  }

  /// ⇧⌘Space.
  static const fallback = HotKey(keyCode: 49, command: true, shift: true, option: false, control: false);

  /// From a Flutter key press, or null for a key with no macOS code here or
  /// no modifier (a bare letter can't be global).
  static HotKey? fromEvent(KeyEvent event) {
    final code = _macKeyCodes[event.physicalKey];
    final keys = HardwareKeyboard.instance;
    if (code == null || !(keys.isMetaPressed || keys.isControlPressed || keys.isAltPressed)) return null;
    return HotKey(
      keyCode: code,
      command: keys.isMetaPressed,
      shift: keys.isShiftPressed,
      option: keys.isAltPressed,
      control: keys.isControlPressed,
    );
  }

  final int keyCode;
  final bool command;
  final bool shift;
  final bool option;
  final bool control;

  // Carbon's cmdKey, shiftKey, optionKey, controlKey.
  int get carbonModifiers =>
      (command ? 0x100 : 0) | (shift ? 0x200 : 0) | (option ? 0x800 : 0) | (control ? 0x1000 : 0);

  String encode() => [keyCode, command, shift, option, control].map((v) => v is bool ? (v ? 1 : 0) : v).join(',');

  String get label {
    final key = _labels[keyCode] ?? '?';
    return '${control ? '⌃' : ''}${option ? '⌥' : ''}${shift ? '⇧' : ''}${command ? '⌘' : ''}$key';
  }
}

const _letters = r"ASDFHGZXCV-BQWERYT123465=97-80]OU[IP-LJ'K;\,/NM.";

final Map<PhysicalKeyboardKey, int> _macKeyCodes = {
  for (final (key, code) in [
    (PhysicalKeyboardKey.keyA, 0),
    (PhysicalKeyboardKey.keyS, 1),
    (PhysicalKeyboardKey.keyD, 2),
    (PhysicalKeyboardKey.keyF, 3),
    (PhysicalKeyboardKey.keyH, 4),
    (PhysicalKeyboardKey.keyG, 5),
    (PhysicalKeyboardKey.keyZ, 6),
    (PhysicalKeyboardKey.keyX, 7),
    (PhysicalKeyboardKey.keyC, 8),
    (PhysicalKeyboardKey.keyV, 9),
    (PhysicalKeyboardKey.keyB, 11),
    (PhysicalKeyboardKey.keyQ, 12),
    (PhysicalKeyboardKey.keyW, 13),
    (PhysicalKeyboardKey.keyE, 14),
    (PhysicalKeyboardKey.keyR, 15),
    (PhysicalKeyboardKey.keyY, 16),
    (PhysicalKeyboardKey.keyT, 17),
    (PhysicalKeyboardKey.digit1, 18),
    (PhysicalKeyboardKey.digit2, 19),
    (PhysicalKeyboardKey.digit3, 20),
    (PhysicalKeyboardKey.digit4, 21),
    (PhysicalKeyboardKey.digit6, 22),
    (PhysicalKeyboardKey.digit5, 23),
    (PhysicalKeyboardKey.equal, 24),
    (PhysicalKeyboardKey.digit9, 25),
    (PhysicalKeyboardKey.digit7, 26),
    (PhysicalKeyboardKey.minus, 27),
    (PhysicalKeyboardKey.digit8, 28),
    (PhysicalKeyboardKey.digit0, 29),
    (PhysicalKeyboardKey.bracketRight, 30),
    (PhysicalKeyboardKey.keyO, 31),
    (PhysicalKeyboardKey.keyU, 32),
    (PhysicalKeyboardKey.bracketLeft, 33),
    (PhysicalKeyboardKey.keyI, 34),
    (PhysicalKeyboardKey.keyP, 35),
    (PhysicalKeyboardKey.keyL, 37),
    (PhysicalKeyboardKey.keyJ, 38),
    (PhysicalKeyboardKey.quote, 39),
    (PhysicalKeyboardKey.keyK, 40),
    (PhysicalKeyboardKey.semicolon, 41),
    (PhysicalKeyboardKey.backslash, 42),
    (PhysicalKeyboardKey.comma, 43),
    (PhysicalKeyboardKey.slash, 44),
    (PhysicalKeyboardKey.keyN, 45),
    (PhysicalKeyboardKey.keyM, 46),
    (PhysicalKeyboardKey.period, 47),
    (PhysicalKeyboardKey.space, 49),
    (PhysicalKeyboardKey.backquote, 50),
    (PhysicalKeyboardKey.enter, 36),
    (PhysicalKeyboardKey.f1, 122),
    (PhysicalKeyboardKey.f2, 120),
    (PhysicalKeyboardKey.f3, 99),
    (PhysicalKeyboardKey.f4, 118),
    (PhysicalKeyboardKey.f5, 96),
    (PhysicalKeyboardKey.f6, 97),
    (PhysicalKeyboardKey.f7, 98),
    (PhysicalKeyboardKey.f8, 100),
    (PhysicalKeyboardKey.f9, 101),
    (PhysicalKeyboardKey.f10, 109),
    (PhysicalKeyboardKey.f11, 103),
    (PhysicalKeyboardKey.f12, 111),
  ])
    key: code,
};

final Map<int, String> _labels = {
  for (var i = 0; i < _letters.length; i++)
    if (_letters[i] != '-' || i == 27) i: _letters[i],
  49: 'Space',
  50: '`',
  36: '↩',
  122: 'F1',
  120: 'F2',
  99: 'F3',
  118: 'F4',
  96: 'F5',
  97: 'F6',
  98: 'F7',
  100: 'F8',
  101: 'F9',
  109: 'F10',
  103: 'F11',
  111: 'F12',
};
