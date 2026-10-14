import 'package:dzep_macos/controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test("kitty's sockets are in /tmp unless DZEP_KITTY_DIR names another directory", () {
    expect(AppController.kittyDir({}), '/tmp');
    expect(AppController.kittyDir({'DZEP_KITTY_DIR': ''}), '/tmp');
    expect(AppController.kittyDir({'DZEP_KITTY_DIR': '/tmp/dzep-e2e'}), '/tmp/dzep-e2e');
  });
}
