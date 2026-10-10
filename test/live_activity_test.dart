import 'package:dzep/live.dart';
import 'package:dzep/live_activity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  LiveSummary summary({bool busy = false, LiveAsk? ask}) =>
      LiveSummary(key: 'kitty-1/2', id: 's', title: 'Fix it', cwd: '/x/dzep', busy: busy, ask: ask, epoch: 'e', seq: 0);

  const question = LiveAsk.questions('q', [
    LiveQuestion(id: 'a', question: 'Which?', options: ['A', 'B']),
  ]);

  test('a session maps to working, done, or needs with what it waits for', () {
    expect(summaryStatus(summary(busy: true)), (state: ActivityState.working, kind: null));
    expect(summaryStatus(summary()), (state: ActivityState.done, kind: null));
    expect(summaryStatus(summary(ask: question)), (state: ActivityState.needs, kind: ActivityKind.question));
    expect(summaryStatus(summary(busy: true, ask: const LiveAsk.approval('t', tool: 'bash'))), (
      state: ActivityState.needs,
      kind: ActivityKind.approval,
    ));
    expect(summaryStatus(summary(busy: true, ask: const LiveAsk.plan('p'))), (
      state: ActivityState.needs,
      kind: ActivityKind.plan,
    ));
  });

  test('a session gone from the Mac has ended', () {
    expect(summaryStatus(null), (state: ActivityState.ended, kind: null));
  });

  test('pushes carry the state and, only when it needs you, the kind', () {
    expect(activityJson((state: ActivityState.working, kind: null)), {'state': 'working'});
    expect(activityJson((state: ActivityState.needs, kind: ActivityKind.plan)), {'state': 'needs', 'kind': 'plan'});
  });
}
