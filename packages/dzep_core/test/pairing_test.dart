import 'package:dzep_core/session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test("the pair function's own reason comes through", () {
    const used = "That code doesn't work: it may have run out, been used already or been revoked.";
    expect(pairingProblem(const FunctionsHttpException(status: 400, details: {'error': used})), used);
    expect(
      pairingProblem(const FunctionsHttpException(status: 401, details: {'error': 'Sign in first'})),
      'Sign in first',
    );
  });

  test('a server without the pair function is told to update', () {
    final problem = pairingProblem(
      const FunctionsHttpException(
        status: 404,
        details: {'code': 'NOT_FOUND', 'message': 'Requested function was not found'},
      ),
    );
    expect(problem, contains('Update it'));
  });

  test('no connection reads as one, other failures keep their status', () {
    expect(pairingProblem(const FunctionsFetchException(details: 'SocketException')), contains('connection'));
    expect(pairingProblem(const FunctionsHttpException(status: 502, details: 'Bad gateway')), contains('502'));
  });
}
