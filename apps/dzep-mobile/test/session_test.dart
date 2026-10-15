import 'package:dzep_mobile/mobile.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A phone whose account goes without its own sign-out.
class _Phone extends MobileSession {
  _Phone(SharedPreferences prefs) : super(prefs, 'iPhone');

  /// The server refused a refresh, the account was deleted on another
  /// device, or the reviewer access ended.
  Future<void> signedOutByServer() => onSignedOut();
}

void main() {
  testWidgets("the server ending the session takes the account's widget token and followed sessions off the phone", (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'dzep_device_token': 'widget-token',
      'dzep_device_token_user': 'u1',
      'dzep_push_token': 'push-token',
      'dzep_push_user': 'u1',
    });
    final prefs = await SharedPreferences.getInstance();
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('dzep/native'), (call) async {
      calls.add(call);
      return call.method == 'liveActivities'
          ? [
              {'key': 'kitty-1/2', 'token': 'activity-token'},
            ]
          : null;
    });

    await _Phone(prefs).signedOutByServer();

    expect(calls.where((c) => c.method == 'setSharedToken').map((c) => c.arguments), [
      {'token': null},
    ], reason: "the widgets can't tick the gone account's todos, and stop showing them");
    expect(calls.where((c) => c.method == 'endActivity').map((c) => (c.arguments as Map)['key']), ['kitty-1/2']);
    expect(prefs.getString('dzep_device_token'), isNull);
    expect(prefs.getString('dzep_push_user'), isNull, reason: 'the next account registers for push afresh');
  });
}
