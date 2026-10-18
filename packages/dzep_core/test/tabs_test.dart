import 'package:dzep_core/tabs.dart';
import 'package:flutter_test/flutter_test.dart';

enum _T { a, b, c }

void main() {
  test('a saved order keeps its tabs once, drops names it no longer has, and adds new tabs at the end', () {
    final t = TabChoice.parse(_T.values, order: ['c', 'gone', 'c', 'a'], hidden: ['a', 'gone']);
    expect(t.order, [_T.c, _T.a, _T.b]);
    expect(t.visible, [_T.c, _T.b]);
  });

  test('nothing saved, or everything hidden, shows every tab in the standard order', () {
    expect(TabChoice.parse(_T.values).visible, _T.values);
    expect(TabChoice.parse(_T.values, order: ['b', 'a', 'c'], hidden: ['a', 'b', 'c']).visible, _T.values);
  });

  test('the last tab showing stays on', () {
    final one = TabChoice.standard(_T.values).toggled(_T.a).toggled(_T.b);
    expect(one.visible, [_T.c]);
    expect(one.toggled(_T.c).visible, [_T.c]);
    expect(one.toggled(_T.a).visible, [_T.a, _T.c]);
  });

  test('moving works as a reorderable list reports it, down and up, hidden tabs keeping their place', () {
    final t = TabChoice.standard(_T.values).toggled(_T.b);
    expect(t.moved(0, 3).order, [_T.b, _T.c, _T.a]);
    expect(t.moved(2, 0).order, [_T.c, _T.a, _T.b]);
    expect(t.moved(0, 3).visible, [_T.c, _T.a]);
  });

  test('what it saves reads back the same', () {
    final t = TabChoice.standard(_T.values).moved(2, 0).toggled(_T.a);
    final back = TabChoice.parse(_T.values, order: t.orderNames, hidden: t.hiddenNames);
    expect(back.order, t.order);
    expect(back.hidden, t.hidden);
  });
}
