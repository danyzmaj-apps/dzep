/// Reminders on todos, in plain Dart so tests can pin the clock: the `!`
/// token in a todo's title, how a reminder time reads, and which reminders a
/// device should have pending. Scheduling them is native (lib/native.dart).
library;

import 'package:dzep/idea.dart';

/// A notification a device should have pending; `id` is the todo's.
typedef Reminder = ({String id, String title, DateTime at});

typedef _Clock = ({int hour, int minute});

/// When a day without a time (`!tomorrow`, `!fri`) reminds.
const _Clock _morning = (hour: 9, minute: 0);

const _weekdays = ['monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday'];
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

final _token = RegExp(r'(^|\s)!(\S+)');
final _nextWord = RegExp(r'\s+(\S+)');
final _clock = RegExp(r'^(\d{1,2})(?:[:.](\d{2}))?(am|pm)?$');
final _span = RegExp(r'^(?:(\d{1,4})d)?(?:(\d{1,4})h)?(?:(\d{1,4})m(?:in)?)?$');

/// Takes the first `!` token that reads as a time out of a todo title:
/// `call bank !15:00`, `!9`, `!3pm`, `!tomorrow 9`, `!mon 14:30`, `!30m`,
/// `!2h` (see [parseWhen]). A token that doesn't read stays in the title.
({String title, DateTime? at}) parseReminder(String raw, DateTime now) {
  for (final m in _token.allMatches(raw)) {
    final start = m.start + m[1]!.length;
    // A day takes the next word as its time when it is one: `!tomorrow 9`.
    final next = _nextWord.matchAsPrefix(raw, m.end);
    final candidates = [if (next != null) ('${m[2]} ${next[1]}', next.end), (m[2]!, m.end)];
    for (final (spec, end) in candidates) {
      final at = parseWhen(spec, now);
      if (at != null) {
        return (title: '${raw.substring(0, start).trimRight()} ${raw.substring(end).trimLeft()}'.trim(), at: at);
      }
    }
  }
  return (title: raw.trim(), at: null);
}

/// The moment [spec] (a `!` token without the `!`) names after [now], or
/// null when it doesn't read:
/// - a time, `15:00`, `9`, `9.30`, `3pm`: today, or tomorrow once it's past;
/// - a day, `today`, `tomorrow`/`tmr`, a weekday (`mon`, `thurs`, `friday`),
///   optionally followed by a time (9:00 without one; `today` needs one): a
///   weekday is the next one still ahead, so today's only before that time;
/// - a span from now: `30m`, `2h`, `1d`, `1h30m`.
DateTime? parseWhen(String spec, DateTime now) {
  final words = spec.trim().toLowerCase().split(RegExp(r'\s+'));
  if (words.length > 2) return null;
  final day = words.first;
  if (words.length == 1) {
    final span = _spanOf(day);
    if (span != null) return now.add(span);
    final time = _timeOf(day);
    if (time != null) {
      final today = _on(now, 0, time);
      return today.isAfter(now) ? today : _on(now, 1, time);
    }
  }
  final time = words.length == 2 ? _timeOf(words[1]) : _morning;
  if (time == null) return null;
  switch (day) {
    case 'today':
      final at = _on(now, 0, time);
      return words.length == 2 && at.isAfter(now) ? at : null;
    case 'tomorrow' || 'tmr' || 'tmrw':
      return _on(now, 1, time);
  }
  final weekday = day.length < 3 ? 0 : _weekdays.indexWhere((d) => d.startsWith(day)) + 1;
  if (weekday == 0) return null;
  final ahead = (weekday - now.weekday) % 7;
  final at = _on(now, ahead, time);
  return at.isAfter(now) ? at : _on(now, ahead + 7, time);
}

/// How a reminder reads on a chip or a row: "Today 15:00", "Tomorrow 09:00",
/// "Fri 14:30" within the week, "13 Oct 09:00" further out (with the year if
/// it isn't this one), "Yesterday 15:00" once past.
String reminderLabel(DateTime at, DateTime now) {
  final l = at.toLocal();
  // UTC dates: a day across a DST change is still one day.
  final days = DateTime.utc(l.year, l.month, l.day).difference(DateTime.utc(now.year, now.month, now.day)).inDays;
  final time = '${_two(l.hour)}:${_two(l.minute)}';
  final weekday = _weekdays[l.weekday - 1];
  return switch (days) {
    0 => 'Today $time',
    1 => 'Tomorrow $time',
    -1 => 'Yesterday $time',
    > 1 && < 7 => '${weekday[0].toUpperCase()}${weekday.substring(1, 3)} $time',
    _ => '${l.day} ${_months[l.month - 1]}${l.year == now.year ? '' : ' ${l.year}'} $time',
  };
}

/// The notifications a device should have pending: open todos whose reminder
/// is still ahead, soonest first, at most [limit] (iOS keeps only an app's
/// soonest 64).
List<Reminder> pendingReminders(Iterable<Idea> ideas, DateTime now, {int limit = 64}) {
  final due = [
    for (final i in ideas)
      if (i.remindAt case final at? when i.isTodo && !i.done && !i.deleted && at.isAfter(now))
        (id: i.id, title: i.title.isEmpty ? 'Untitled todo' : i.title, at: at),
  ]..sort((a, b) => a.at.compareTo(b.at));
  return due.length > limit ? due.sublist(0, limit) : due;
}

DateTime _on(DateTime now, int days, _Clock time) =>
    DateTime(now.year, now.month, now.day + days, time.hour, time.minute);

_Clock? _timeOf(String word) {
  final m = _clock.firstMatch(word);
  if (m == null) return null;
  var hour = int.parse(m[1]!);
  final minute = int.parse(m[2] ?? '0');
  final half = m[3];
  if (minute > 59 || hour > (half == null ? 23 : 12) || (half != null && hour == 0)) return null;
  if (half != null) hour = hour % 12 + (half == 'pm' ? 12 : 0);
  return (hour: hour, minute: minute);
}

Duration? _spanOf(String word) {
  final m = _span.firstMatch(word);
  if (m == null) return null;
  final span = Duration(days: int.parse(m[1] ?? '0'), hours: int.parse(m[2] ?? '0'), minutes: int.parse(m[3] ?? '0'));
  return span > Duration.zero ? span : null;
}

String _two(int n) => n.toString().padLeft(2, '0');
