import 'package:flutter/services.dart';

/// The Swift side (macos/Runner/MainFlutterWindow.swift): window shapes,
/// menu-bar icon, global hotkey, launch at login.
class Native {
  static const _channel = MethodChannel('dzep/native');

  /// Events from the Swift side: hotKey, togglePopup, openMain,
  /// openSettings, blur, closed.
  static void listen(void Function(String event) onEvent) {
    _channel.setMethodCallHandler((call) async => onEvent(call.method));
  }

  static Future<void> showPopup() => _channel.invokeMethod('showPopup');
  static Future<void> showMain() => _channel.invokeMethod('showMain');
  static Future<void> hide() => _channel.invokeMethod('hide');
  static Future<void> quit() => _channel.invokeMethod('quit');
  static Future<void> startDrag() => _channel.invokeMethod('startDrag');
  static Future<void> setTodoCount(int count) => _channel.invokeMethod('setTodoCount', {'count': count});

  // iPhone: the App Group the Siri intents and the widget read.
  static Future<void> setSharedToken(String? token) => _channel.invokeMethod('setSharedToken', {'token': token});
  static Future<void> setSharedTodos(List<Map<String, String>> todos) =>
      _channel.invokeMethod('setSharedTodos', {'todos': todos});
  static Future<List<String>> takePending() async =>
      (await _channel.invokeListMethod<String>('takePending')) ?? const [];

  static Future<bool> setHotKey(HotKey key) async =>
      await _channel.invokeMethod<bool>('setHotKey', {'keyCode': key.keyCode, 'modifiers': key.carbonModifiers}) ??
      false;

  static Future<String> deviceName() async => await _channel.invokeMethod<String>('deviceName') ?? 'Mac';
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
