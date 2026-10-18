/// Which of an app's tabs show, and in what order: the phone's bottom bar,
/// the Mac popup's strip. Each app keeps it on the device, as [orderNames]
/// and [hiddenNames]. At least one tab always shows.
class TabChoice<T extends Enum> {
  TabChoice._(this.order, this.hidden) : assert(order.any((t) => !hidden.contains(t)), 'a tab must show');

  /// Every tab, in the order [all] lists them, all showing.
  TabChoice.standard(List<T> all) : this._(List.unmodifiable(all), const {});

  /// What was saved: [order] (each tab once; tabs it doesn't name, new in
  /// this version, go at the end) and the [hidden] ones. Nothing saved, or
  /// nothing left showing, is [TabChoice.standard].
  factory TabChoice.parse(List<T> all, {List<String>? order, List<String>? hidden}) {
    final byName = {for (final t in all) t.name: t};
    final saved = [
      for (final n in {...?order}) ?byName[n],
    ];
    final ordered = [...saved, ...all.where((t) => !saved.contains(t))];
    final off = {for (final n in hidden ?? const <String>[]) ?byName[n]};
    if (ordered.every(off.contains)) return TabChoice.standard(all);
    return TabChoice._(List.unmodifiable(ordered), Set.unmodifiable(off));
  }

  /// Every tab, shown or not, in the chosen order.
  final List<T> order;

  /// The tabs switched off.
  final Set<T> hidden;

  /// The tabs that show, in order.
  List<T> get visible => [
    for (final t in order)
      if (!hidden.contains(t)) t,
  ];

  bool shows(T tab) => !hidden.contains(tab);

  /// [tab] switched on or off; the last one showing can't be switched off.
  TabChoice<T> toggled(T tab) {
    if (hidden.contains(tab)) return TabChoice._(order, Set.unmodifiable({...hidden}..remove(tab)));
    if (visible.length == 1) return this;
    return TabChoice._(order, Set.unmodifiable({...hidden, tab}));
  }

  /// The tab at [from] moved to [to], as a reorderable list reports it
  /// ([to] counts the moved one still in place).
  TabChoice<T> moved(int from, int to) {
    final next = [...order];
    final tab = next.removeAt(from);
    next.insert(to > from ? to - 1 : to, tab);
    return TabChoice._(List.unmodifiable(next), hidden);
  }

  List<String> get orderNames => [for (final t in order) t.name];
  List<String> get hiddenNames => [for (final t in order.where(hidden.contains)) t.name];
}
