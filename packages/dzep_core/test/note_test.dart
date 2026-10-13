import 'package:dzep_core/idea.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('noteTitle', () {
    test('is the first line', () {
      expect(noteTitle('Groceries\nmilk\neggs'), 'Groceries');
    });

    test('skips blank lines and trims', () {
      expect(noteTitle('\n\n   Meeting notes  \nagenda'), 'Meeting notes');
    });

    test('drops Markdown heading marks', () {
      expect(noteTitle('## Release plan\n- ship'), 'Release plan');
      expect(noteTitle('#hashtag-ish'), 'hashtag-ish');
    });

    test('is empty for an empty note', () {
      expect(noteTitle(''), '');
      expect(noteTitle('  \n \n'), '');
    });
  });

  test('kinds read back from the server, unknown ones as ideas', () {
    expect(Kind.parse('note'), Kind.note);
    expect(Kind.parse('todo'), Kind.todo);
    expect(Kind.parse('idea'), Kind.idea);
    expect(Kind.parse('something-newer'), Kind.idea);
    expect(Kind.parse(null), Kind.idea);
  });

  test('a note row round-trips through the local cache', () {
    final note = Idea.fromServer({
      'id': 'n1',
      'kind': 'note',
      'title': 'Groceries',
      'notes': 'Groceries\nmilk',
      'created_at': '2026-10-08T10:00:00Z',
      'updated_at': '2026-10-08T11:00:00Z',
    });
    final back = Idea.fromLocal(note.toLocal());
    expect(back.isNote, isTrue);
    expect(back.toServer()['kind'], 'note');
    expect(back.notes, 'Groceries\nmilk');
  });
}
