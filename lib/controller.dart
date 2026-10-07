import 'dart:async';

import 'package:dzep/native.dart';
import 'package:dzep/session.dart';
import 'package:dzep/store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Mac app: [Session] plus its two windows (the ⇧⌘Space popup panel and
/// the main window, each its own Flutter view) and the hotkey.
class AppController extends Session {
  AppController(super.client, this._prefs, super.device);

  final SharedPreferences _prefs;

  /// The popup panel is on screen.
  bool get popupOpen => _popupOpen;
  bool _popupOpen = false;

  /// The main window is open (Džep is a regular app with a Dock icon then).
  bool get mainOpen => _mainOpen;
  bool _mainOpen = false;

  /// Bumped on every popup open so it resets (focus, selection).
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
        unawaited(_popupOpen ? closePopup() : openPopup());
      case 'openMain':
        unawaited(openMain());
      case 'openSettings':
        settingsOpen = true;
        unawaited(openMain());
      case 'blur':
        // Clicking elsewhere dismisses the popup, like Spotlight.
        if (_popupOpen) unawaited(closePopup());
      case 'mainClosed':
        _mainOpen = false;
        notifyListeners();
    }
  }

  Future<void> openPopup() async {
    popupSession++;
    _popupOpen = true;
    notifyListeners();
    await Native.showPopup();
  }

  Future<void> closePopup() async {
    _popupOpen = false;
    notifyListeners();
    await Native.hidePopup();
  }

  Future<void> openMain({String? select}) async {
    if (select != null) pendingSelect = select;
    if (_popupOpen) await closePopup();
    _mainOpen = true;
    notifyListeners();
    await Native.showMain();
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
