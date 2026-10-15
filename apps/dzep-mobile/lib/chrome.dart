import 'dart:io' show Platform;

import 'package:dzep_core/ui.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:native_liquid_glass/native_liquid_glass.dart';

/// The phone app's chrome in each platform's own idiom. On an iPhone the tab
/// bar, its + and the Pocket tab's search and kind picker are UIKit's own
/// controls (`native_liquid_glass` hosts them), so iOS 26 draws them in its
/// Liquid Glass and older iOS in its standard look; the lists are iOS's inset
/// grouped ones. Everywhere else, Android and widget tests (which can't host
/// UIKit views) included, Material 3: tonal surfaces, the navigation bar with
/// its pill, a rounded-square + button.
final bool nativeIos = !kIsWeb && Platform.isIOS;

/// iOS's dark system colours for inset grouped lists.
abstract final class S {
  static const background = Color(0xFF000000);
  static const cell = Color(0xFF1C1C1E);
  static const fill = Color(0xFF2C2C2E);
  static const separator = Color(0xFF38383A);
  static const secondaryLabel = Color(0xFF8E8E93);
}

/// Android's tonal surfaces (Material 3 surface containers, in the app's dark palette).
abstract final class M {
  static const container = Color(0xFF1C1E25);
  static const containerHigh = Color(0xFF23262F);
  static const indicator = Color(0x337C9CFF);
}

/// What the screens sit on.
Color get screenColor => nativeIos ? S.background : C.win;

/// A screen's big title, with what goes on its right.
class PageTitle extends StatelessWidget {
  const PageTitle(this.title, {this.trailing = const [], super.key});
  final String title;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 10, 12, 6),
    child: Row(
      children: [
        // Large text sizes: the title gives way, never the account button.
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: nativeIos
                ? const TextStyle(fontSize: 34, fontWeight: FontWeight.w700, letterSpacing: .4)
                : const TextStyle(fontSize: 28, fontWeight: FontWeight.w500),
          ),
        ),
        ...trailing,
      ],
    ),
  );
}

/// A group of rows: an inset rounded card (iOS's inset grouped list, or a
/// Material 3 tonal surface) with thin separators, under an optional small
/// heading.
class Panel extends StatelessWidget {
  const Panel({required this.children, this.title, this.onTitleTap, this.titleTrailing, super.key});
  final List<Widget> children;
  final String? title;
  final VoidCallback? onTitleTap;
  final Widget? titleTrailing;

  @override
  Widget build(BuildContext context) {
    final heading = title == null
        ? null
        : InkWell(
            onTap: onTitleTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(32, 18, 24, 7),
              child: Row(
                children: [
                  Text(
                    title!,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: nativeIos ? FontWeight.w400 : FontWeight.w600,
                      letterSpacing: nativeIos ? .2 : .1,
                      color: nativeIos ? S.secondaryLabel : C.accent,
                    ),
                  ),
                  const Spacer(),
                  ?titleTrailing,
                ],
              ),
            ),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ?heading,
        if (children.isNotEmpty)
          Padding(
            padding: EdgeInsets.fromLTRB(16, title == null ? 8 : 0, 16, 0),
            // A Material, so the rows' ink and list tiles paint on it.
            child: Material(
              color: nativeIos ? S.cell : M.container,
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(nativeIos ? 22 : 24)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, row) in children.indexed) ...[
                    if (i > 0) Divider(height: 1, thickness: 0.5, indent: 52, color: nativeIos ? S.separator : C.line),
                    row,
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// A capsule filter: iOS's plain filled capsule, or a Material 3 filter chip.
class Pill extends StatelessWidget {
  const Pill({required this.label, required this.selected, required this.onTap, this.color, super.key});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// The selected colour (the app's accent unless said).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? C.accent;
    if (!nativeIos) {
      return FilterChip(
        selected: selected,
        onSelected: (_) => onTap(),
        showCheckmark: false,
        label: Text(label),
        labelStyle: TextStyle(fontSize: 13, color: selected ? C.text : C.dim),
        backgroundColor: M.container,
        selectedColor: M.indicator,
        side: BorderSide(color: selected ? Colors.transparent : C.line2),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      );
    }
    return Semantics(
      button: true,
      selected: selected,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? tint.withValues(alpha: .24) : S.fill,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected ? tint : C.text,
            ),
          ),
        ),
      ),
    );
  }
}

/// The search field: UIKit's search field on iPhone, Material 3's search bar shape on Android.
class SearchField extends StatelessWidget {
  const SearchField({required this.onChanged, super.key});
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
    child: nativeIos
        ? LiquidGlassSearchBar(expandable: false, showCancelButton: false, onChanged: onChanged)
        : TextField(
            onTapOutside: dismissKeyboard,
            onChanged: onChanged,
            style: const TextStyle(fontSize: 15),
            decoration: InputDecoration(
              hintText: 'Search',
              hintStyle: const TextStyle(color: C.dim2),
              prefixIcon: const Icon(Icons.search, color: C.dim, size: 20),
              filled: true,
              fillColor: M.containerHigh,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 11),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(28), borderSide: BorderSide.none),
            ),
          ),
  );
}

/// One choice out of a few: UIKit's segmented control on iPhone, Material 3
/// filter chips in a row on Android. Each Android chip is keyed by [keys].
class Segments extends StatelessWidget {
  const Segments({required this.labels, required this.keys, required this.selected, required this.onSelect, super.key});
  final List<String> labels;
  final List<Key> keys;
  final int selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    if (nativeIos) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        child: LiquidGlassSegmentedControl(labels: labels, selectedIndex: selected, onValueChanged: onSelect),
      );
    }
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          for (final (i, label) in labels.indexed)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Center(
                child: Pill(key: keys[i], label: label, selected: i == selected, onTap: () => onSelect(i)),
              ),
            ),
        ],
      ),
    );
  }
}

/// One tab of [AppTabBar]: Material icons on Android, SF Symbols on iPhone.
typedef TabSpec = ({IconData icon, IconData selectedIcon, String symbol, String label, int badge});

/// The three tabs: on iPhone UIKit's tab bar, with the screen's + as its
/// separate action button; on Android Material 3's navigation bar, where the
/// + is a [AddButton] above it.
class AppTabBar extends StatelessWidget {
  const AppTabBar({required this.tabs, required this.index, required this.onSelect, required this.onAdd, super.key});
  final List<TabSpec> tabs;
  final int index;
  final ValueChanged<int> onSelect;

  /// The iPhone's +.
  final VoidCallback? onAdd;

  /// Room the lists leave at the bottom, clear of the bar and the +.
  static const contentInset = 120.0;

  @override
  Widget build(BuildContext context) {
    if (nativeIos) {
      return SafeArea(
        top: false,
        child: LiquidGlassTabBar(
          currentIndex: index,
          onTabSelected: onSelect,
          selectedItemColor: C.accent,
          items: [
            for (final t in tabs)
              LiquidGlassTabItem(
                label: t.label,
                icon: NativeLiquidGlassIcon.sfSymbol(t.symbol),
                iosBadgeValue: t.badge > 0 ? '${t.badge}' : null,
              ),
          ],
          // One + for every tab: changing it would rebuild the native bar.
          iosActionButton: const LiquidGlassTabItem(label: 'New', icon: NativeLiquidGlassIcon.sfSymbol('plus')),
          onActionButtonPressed: onAdd,
        ),
      );
    }
    Widget icon(TabSpec t, {required bool on}) {
      final icon = Icon(on ? t.selectedIcon : t.icon);
      return t.badge > 0 ? Badge(label: Text('${t.badge}'), child: icon) : icon;
    }

    return NavigationBar(
      selectedIndex: index,
      onDestinationSelected: onSelect,
      backgroundColor: M.container,
      indicatorColor: M.indicator,
      height: 72,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      destinations: [
        for (final (i, t) in tabs.indexed)
          NavigationDestination(
            icon: icon(t, on: false),
            selectedIcon: icon(t, on: i == index),
            label: t.label,
          ),
      ],
    );
  }
}

/// Android's +: Material 3's rounded-square FAB. (The iPhone's is in [AppTabBar].)
class AddButton extends StatelessWidget {
  const AddButton({required this.tooltip, required this.onPressed, this.icon = Icons.add, super.key});
  final String tooltip;
  final VoidCallback? onPressed;
  final IconData icon;

  @override
  Widget build(BuildContext context) => FloatingActionButton(
    key: const ValueKey('add'),
    tooltip: tooltip,
    onPressed: onPressed,
    backgroundColor: C.accent,
    foregroundColor: const Color(0xFF0E0F12),
    child: Icon(icon, size: 26),
  );
}
