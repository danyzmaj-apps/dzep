import 'dart:async';

import 'package:dzep/native.dart';
import 'package:dzep/session.dart';
import 'package:dzep/store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What the one window is showing.
enum Mode { hidden, popup, main }

/// The Mac app: [Session] plus the window mode and the hotkey.
class AppController extends Session {
  AppController(super.client, this._prefs, super.device);

  final SharedPreferences _prefs;

  Mode get mode => _mode;
  Mode _mode = Mode.hidden;

  /// The capture panel shown over the main window (the hotkey while the main
  /// window is open). Turning the main window into the popup and back is a
  /// real window resize each way, and Flutter's renderer (Impeller) crashes
  /// when those come quickly (hotkey spam), so the main window keeps its
  /// shape and the same panel opens inside it.
  bool get captureInMain => _captureInMain;
  bool _captureInMain = false;

  /// Whether the capture panel is on screen, in the popup or in the main window.
  bool get captureVisible => _mode == Mode.popup || (_mode == Mode.main && _captureInMain);

  /// Bumped on every capture open so it resets (focus, selection).
  int popupSession = 0;

  bool settingsOpen = false;

  /// Idea the main window should select next (from the popup's list).
  String? pendingSelect;

  HotKey get hotKey => _hotKey;
  late HotKey _hotKey = _loadHotKey();
  bool hotKeyRegistered = false;

  Future<void> start() async {
    Native.listen(_onNative);
    hotKeyRegistered = await Native.setHotKey(_hotKey);
    await startAuth();
    // Signed out: there's nothing to do but sign in, so say so.
    if (user == null) await openMain();
  }

  @override
  Future<void> signOut() async {
    settingsOpen = false;
    await super.signOut();
    _shownTodoCount = 0;
    await Native.setTodoCount(0);
  }

  int _shownTodoCount = 0;

  @override
  Future<void> onSignedIn(IdeaStore store) async {
    void update() {
      final n = store.openTodos.length;
      if (n == _shownTodoCount || this.store != store) return;
      _shownTodoCount = n;
      unawaited(Native.setTodoCount(n));
    }

    store.addListener(update);
    update();
  }

  // ---------------------------------------------------------------- window

  void _onNative(String event) {
    switch (event) {
      case 'hotKey' || 'togglePopup':
        unawaited(captureVisible ? closePopup() : openPopup());
      case 'openMain':
        unawaited(openMain());
      case 'openSettings':
        settingsOpen = true;
        unawaited(openMain());
      case 'blur':
        // Clicking elsewhere dismisses the popup, like Spotlight.
        if (_mode == Mode.popup) unawaited(hide());
      case 'closed':
        _mode = Mode.hidden;
        _captureInMain = false;
        notifyListeners();
    }
  }

  Future<void> openPopup() async {
    popupSession++;
    if (_mode == Mode.main) {
      _captureInMain = true;
      notifyListeners();
      await Native.showMain(); // already that shape: brings it forward, no resize
      return;
    }
    _mode = Mode.popup;
    notifyListeners();
    await Native.showPopup();
  }

  /// Esc / save / hotkey again: the popup hides, the in-window panel closes.
  Future<void> closePopup() async {
    if (_mode == Mode.main) {
      _captureInMain = false;
      notifyListeners();
    } else {
      await hide();
    }
  }

  Future<void> openMain({String? select}) async {
    if (select != null) pendingSelect = select;
    _captureInMain = false;
    final wasMain = _mode == Mode.main;
    _mode = Mode.main;
    notifyListeners();
    if (!wasMain) await Native.showMain();
  }

  Future<void> hide() async {
    _mode = Mode.hidden;
    _captureInMain = false;
    notifyListeners();
    await Native.hide();
  }

  void setSettingsOpen({required bool open}) {
    settingsOpen = open;
    notifyListeners();
  }

  // ---------------------------------------------------------------- hotkey

  HotKey _loadHotKey() {
    final saved = _prefs.getString('hotkey');
    if (saved == null) return HotKey.fallback;
    try {
      return HotKey.decode(saved);
    } on Object {
      return HotKey.fallback;
    }
  }

  /// False when macOS refused it (another app owns the combo); the old one
  /// stays then.
  Future<bool> setHotKey(HotKey key) async {
    final ok = await Native.setHotKey(key);
    if (ok) {
      _hotKey = key;
      hotKeyRegistered = true;
      await _prefs.setString('hotkey', key.encode());
    } else {
      hotKeyRegistered = await Native.setHotKey(_hotKey);
    }
    notifyListeners();
    return ok;
  }
}
