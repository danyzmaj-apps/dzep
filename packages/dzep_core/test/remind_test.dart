import 'package:dzep_core/idea.dart';
import 'package:dzep_core/remind.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Wednesday 7 Oct 2026, 10:00 local.
  final now = DateTime(2026, 10, 7, 10);

  ({String title, DateTime? at}) parse(String raw, [DateTime? at]) => parseReminder(raw, at ?? now);

  group('parseReminder', () {
    test('takes the token out of the title', () {
      expect(parse('call bank !15:00'), (title: 'call bank', at: DateTime(2026, 10, 7, 15)));
      expect(parse('!15:00 call bank'), (title: 'call bank', at: DateTime(2026, 10, 7, 15)));
      expect(parse('call !15:00 bank'), (title: 'call bank', at: DateTime(2026, 10, 7, 15)));
    });

    test('a time already past today is tomorrow', () {
      expect(parse('x !9').at, DateTime(2026, 10, 8, 9));
      expect(parse('x !10:00').at, DateTime(2026, 10, 8, 10), reason: 'exactly now is not ahead');
      expect(parse('x !10:01').at, DateTime(2026, 10, 7, 10, 1));
    });

    test('24h and 12h clocks', () {
      expect(parse('x !23:59').at, DateTime(2026, 10, 7, 23, 59));
      expect(parse('x !9.30').at, DateTime(2026, 10, 8, 9, 30));
      expect(parse('x !3pm').at, DateTime(2026, 10, 7, 15));
      expect(parse('x !3:30PM').at, DateTime(2026, 10, 7, 15, 30));
      expect(parse('x !11am').at, DateTime(2026, 10, 7, 11));
      expect(parse('x !12pm').at, DateTime(2026, 10, 7, 12));
      expect(parse('x !12am').at, DateTime(2026, 10, 8), reason: 'midnight is past for today');
    });

    test('spans from now', () {
      expect(parse('x !30m').at, now.add(const Duration(minutes: 30)));
      expect(parse('x !2h').at, now.add(const Duration(hours: 2)));
      expect(parse('x !1h30m').at, now.add(const Duration(minutes: 90)));
      expect(parse('x !45min').at, now.add(const Duration(minutes: 45)));
      expect(parse('x !1d').at, now.add(const Duration(days: 1)));
    });

    test('a day takes the next word as its time, or 9:00', () {
      expect(parse('call bank !tomorrow 9'), (title: 'call bank', at: DateTime(2026, 10, 8, 9)));
      expect(parse('!tomorrow 3pm call bank'), (title: 'call bank', at: DateTime(2026, 10, 8, 15)));
      expect(parse('!tmr call bank'), (title: 'call bank', at: DateTime(2026, 10, 8, 9)));
      expect(parse('!today 17 call bank'), (title: 'call bank', at: DateTime(2026, 10, 7, 17)));
    });

    test('a weekday is the next one still ahead', () {
      expect(parse('x !mon 14:30').at, DateTime(2026, 10, 12, 14, 30));
      expect(parse('x !fri').at, DateTime(2026, 10, 9, 9));
      expect(parse('x !wed 11').at, DateTime(2026, 10, 7, 11), reason: 'later today');
      expect(parse('x !wednesday 9').at, DateTime(2026, 10, 14, 9), reason: 'past today: next week');
      expect(parse('x !wed').at, DateTime(2026, 10, 14, 9));
      expect(parse('x !thurs').at, DateTime(2026, 10, 8, 9));
      expect(parse('x !sunday 20:00').at, DateTime(2026, 10, 11, 20));
    });

    test('rolls over months and years', () {
      final newYearsEve = DateTime(2026, 12, 31, 23);
      expect(parse('x !9', newYearsEve).at, DateTime(2027, 1, 1, 9));
      expect(parse('x !tomorrow 9', newYearsEve).at, DateTime(2027, 1, 1, 9));
      expect(parse('x !thu', newYearsEve).at, DateTime(2027, 1, 7, 9), reason: 'Thursday 9:00 has passed');
      expect(parse('x !2h', newYearsEve).at, DateTime(2027, 1, 1, 1));
    });

    test('what does not read stays in the title', () {
      for (final raw in [
        'fix bug !urgent',
        'x !25:00',
        'x !13pm',
        'x !0am',
        'x !9:75',
        'x !0m',
        'x !today',
        'x !today 9',
        'x !mo 9',
        'Wow!',
        'x ! 15:00',
      ]) {
        expect(parse(raw), (title: raw, at: null), reason: raw);
      }
    });

    test('the first token that reads wins; the next word stays unless it is a time', () {
      expect(parse('!soon pay !15:00 !16:00'), (title: '!soon pay !16:00', at: DateTime(2026, 10, 7, 15)));
      expect(parse('!9 people'), (title: 'people', at: DateTime(2026, 10, 8, 9)));
      expect(parse('!15:00 tomorrow'), (title: 'tomorrow', at: DateTime(2026, 10, 7, 15)));
    });
  });

  group('reminderLabel', () {
    test('reads relative to today', () {
      expect(reminderLabel(DateTime(2026, 10, 7, 15), now), 'Today 15:00');
      expect(reminderLabel(DateTime(2026, 10, 8, 9, 5), now), 'Tomorrow 09:05');
      expect(reminderLabel(DateTime(2026, 10, 6, 15), now), 'Yesterday 15:00');
      expect(reminderLabel(DateTime(2026, 10, 12, 14, 30), now), 'Mon 14:30');
      expect(reminderLabel(DateTime(2026, 10, 14, 9), now), '14 Oct 09:00');
      expect(reminderLabel(DateTime(2027, 1, 4, 9), now), '4 Jan 2027 09:00');
      expect(reminderLabel(DateTime(2026, 10, 7, 13).toUtc(), now), 'Today 13:00', reason: 'shown in local time');
    });
  });

  group('pendingReminders', () {
    Idea todo(String id, DateTime? at, {Kind kind = Kind.todo, bool done = false, bool deleted = false}) => Idea(
      id: id,
      title: id,
      kind: kind,
      createdAt: now,
      updatedAt: now,
      remindAt: at,
      doneAt: done ? now : null,
      deletedAt: deleted ? now : null,
    );

    test('open todos with a reminder ahead, soonest first', () {
      final due = pendingReminders([
        todo('later', now.add(const Duration(hours: 2))),
        todo('none', null),
        todo('past', now.subtract(const Duration(minutes: 1))),
        todo('done', now.add(const Duration(hours: 1)), done: true),
        todo('deleted', now.add(const Duration(hours: 1)), deleted: true),
        todo('idea', now.add(const Duration(hours: 1)), kind: Kind.idea),
        todo('soon', now.add(const Duration(minutes: 5))),
      ], now);
      expect([for (final r in due) r.id], ['soon', 'later']);
      expect(due.first, (id: 'soon', title: 'soon', at: now.add(const Duration(minutes: 5))));
    });

    test('keeps only the soonest [limit]', () {
      final todos = [for (var k = 70; k > 0; k--) todo('$k', now.add(Duration(minutes: k)))];
      final due = pendingReminders(todos, now);
      expect(due, hasLength(64));
      expect(due.first.id, '1');
      expect(due.last.id, '64');
    });
  });
}
