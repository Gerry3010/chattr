// SPDX-FileCopyrightText: 2025-2026 Gerald Hofbauer <info@geraldhofbauer.net>
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:ui' show ImageFilter;

import 'package:easy_localization/easy_localization.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';

/// The emoji picker's header: fixed corners, scrolling middle.
///
/// ```
/// ┌──────────────────────────────────────────────┐
/// │ [🔍][🕘]  ‹ categories scroll through ›   [✋] │
/// └──────────────────────────────────────────────┘
/// ```
///
/// On the left are the two routes one must **always** be able to reach — search
/// and history. On the right the skin tone. Both stay put; only the categories in
/// the middle scroll, and they do so **underneath the corners**. That is why the
/// corners are frosted (`BackdropFilter`): an icon diving under them fades away
/// gradually instead of being cut off at a hard edge — one can see that the row
/// continues, and the fixed buttons stay readable regardless.
///
/// Why a header of our own rather than the package's bar: its
/// `DefaultCategoryView` is a `TabBar` over *all* categories plus at most **one**
/// extra button ([CategoryExtraTab]) — either search or backspace, never both, and
/// none of it can be pinned while the rest scrolls. It is built through the
/// intended hook `CategoryViewConfig.customCategoryView`; no fork needed.
class ChattrEmojiCategoryBar extends CategoryView {
  /// Konstruktor.
  const ChattrEmojiCategoryBar(
    super.config,
    super.state,
    super.tabController,
    super.pageController, {
    required this.skinTone,
    required this.onSkinTone,
    super.key,
  });

  /// The currently chosen skin tone ('' = none).
  final String skinTone;

  /// Called when a different skin tone has been chosen.
  final ValueChanged<String> onSkinTone;

  @override
  ChattrEmojiCategoryBarState createState() => ChattrEmojiCategoryBarState();
}

/// Zustand zu [ChattrEmojiCategoryBar].
class ChattrEmojiCategoryBarState
    extends CategoryViewState<ChattrEmojiCategoryBar> {
  final ScrollController _scroll = ScrollController();
  final Map<int, GlobalKey> _tabKeys = {};

  /// Width of the two fixed corners. Two buttons on the left, one on the right.
  static const double _leftWidth = 88;
  static const double _rightWidth = 56;

  @override
  void initState() {
    super.initState();
    widget.tabController.addListener(_onCategoryChanged);
  }

  @override
  void dispose() {
    widget.tabController.removeListener(_onCategoryChanged);
    _scroll.dispose();
    super.dispose();
  }

  void _onCategoryChanged() {
    if (!mounted) return;
    setState(() {});
    // Whoever swipes sideways in the grid changes category without touching the
    // bar — then the bar has to follow, otherwise it points at an icon that is
    // no longer visible.
    WidgetsBinding.instance.addPostFrameCallback((_) => _bringIntoView());
  }

  void _bringIntoView() {
    final key = _tabKeys[widget.tabController.index];
    final ctx = key?.currentContext;
    if (ctx == null || !_scroll.hasClients) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      // Keep it roughly centred, so the chosen icon does not land straight back
      // under one of the frosted corners.
      alignment: 0.5,
    );
  }

  /// Jumps to the category at [index] of the package list.
  void _showCategory(int index) {
    closeSkinToneOverlay();
    // Move the page only: the `PageView` pulls the TabController along itself
    // in its `onPageChanged`. Setting both by hand would pit the two
    // controllers against each other.
    widget.pageController.jumpToPage(index);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final aktiv = widget.tabController.index;

    // The history is the first category and moves to the left, to the fixed
    // buttons — it has no business in the scrolling middle, because it is
    // needed most often.
    final entries = widget.state.categoryEmoji;
    final recentIndex =
        entries.indexWhere((e) => e.category == Category.RECENT);

    return SizedBox(
      height: widget.config.categoryViewConfig.tabBarHeight,
      child: Stack(
        children: [
          // Middle: scrolls underneath the corners. The padding left and right
          // is exactly as wide as the corners, so the first and last icon can
          // stand clear instead of staying permanently half-covered.
          Positioned.fill(
            child: ListView(
              controller: _scroll,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(
                left: _leftWidth + 4,
                right: _rightWidth + 4,
              ),
              children: [
                for (var i = 0; i < entries.length; i++)
                  if (i != recentIndex)
                    _CategoryButton(
                      key: _tabKeys.putIfAbsent(i, GlobalKey.new),
                      icon: getIconForCategory(
                        widget.config.categoryViewConfig.categoryIcons,
                        entries[i].category,
                      ),
                      gewaehlt: i == aktiv,
                      onTap: () => _showCategory(i),
                    ),
              ],
            ),
          ),

          // Linke Ecke: Suche + Verlauf.
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: _leftWidth,
            child: _FrostedCorner(
              color: colors.surface,
              towardsEdge: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _CornerButton(
                    icon: Icons.search,
                    tooltip: 'emoji_picker.search'.tr(),
                    onTap: () {
                      closeSkinToneOverlay();
                      widget.state.onShowSearchView();
                    },
                  ),
                  if (recentIndex != -1)
                    _CornerButton(
                      icon: widget
                          .config.categoryViewConfig.categoryIcons.recentIcon,
                      tooltip: 'emoji_picker.recents'.tr(),
                      gewaehlt: aktiv == recentIndex,
                      onTap: () => _showCategory(recentIndex),
                    ),
                ],
              ),
            ),
          ),

          // Rechte Ecke: Hautton.
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: _rightWidth,
            child: _FrostedCorner(
              color: colors.surface,
              towardsEdge: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 6),
                child: _SkinToneButton(
                  skinTone: widget.skinTone,
                  onGewaehlt: (t) {
                    closeSkinToneOverlay();
                    widget.onSkinTone(t);
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One of the two fixed corners: a frosted ground, so the scrolling content
/// underneath disappears softly instead of tearing off hard.
class _FrostedCorner extends StatelessWidget {
  const _FrostedCorner({
    required this.color,
    required this.towardsEdge,
    required this.child,
  });

  final Color color;
  final Alignment towardsEdge;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: DecoratedBox(
          decoration: BoxDecoration(
            // Opaque towards the outer edge, transparent towards the middle:
            // that way the frosted zone does not end at a visible edge.
            gradient: LinearGradient(
              begin: towardsEdge,
              end: towardsEdge == Alignment.centerLeft
                  ? Alignment.centerRight
                  : Alignment.centerLeft,
              // Let it run out softly: with an edge that sets in late one would
              // see the transition as a line, and that is exactly what the
              // frosting is meant to avoid.
              colors: [color, color.withValues(alpha: 0.0)],
              stops: const [0.5, 1.0],
            ),
          ),
          child: Align(
            alignment: towardsEdge,
            child: child,
          ),
        ),
      ),
    );
  }
}

/// One icon in the scrolling middle.
class _CategoryButton extends StatelessWidget {
  const _CategoryButton({
    required this.icon,
    required this.gewaehlt,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final bool gewaehlt;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
      child: Material(
        // Explicitly transparent rather than `null`: a `Material` without a
        // colour takes the theme's — and then every icon sat on a white plate,
        // which would also have scrolled along over the frosted corners.
        color: gewaehlt
            ? colors.primary.withValues(alpha: 0.14)
            : Colors.transparent,
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: 44,
            child: Icon(
              icon,
              size: 22,
              color: gewaehlt ? colors.primary : colors.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// One button in one of the fixed corners.
class _CornerButton extends StatelessWidget {
  const _CornerButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.gewaehlt = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool gewaehlt;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return IconButton(
      icon: Icon(icon, size: 22),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      color: gewaehlt ? colors.primary : colors.onSurfaceVariant,
      onPressed: onTap,
    );
  }
}

/// The skin-tone choice on the right of the header.
///
/// What is shown is a **neutral circle** in the chosen colour, not a hand in
/// the chosen tone. The hand was ambiguous: it looks like an emoji one taps to
/// send it — in a grid full of emoji that do exactly that. A colour circle
/// visibly belongs to the controls rather than to the grid, and at the same
/// time says unmistakably what it sets.
class _SkinToneButton extends StatelessWidget {
  const _SkinToneButton({required this.skinTone, required this.onGewaehlt});

  final String skinTone;
  final ValueChanged<String> onGewaehlt;

  static const List<String> _toene = ['', ...SkinTone.values];

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'emoji_picker.skin_tone'.tr(),
      padding: EdgeInsets.zero,
      position: PopupMenuPosition.under,
      onSelected: onGewaehlt,
      itemBuilder: (context) => [
        PopupMenuItem<String>(
          // Not tappable, so the entry does not react as a whole — the circles
          // inside take the taps individually.
          enabled: false,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final ton in _toene)
                IconButton(
                  tooltip: ton.isEmpty
                      ? 'emoji_picker.skin_tone_default'.tr()
                      : null,
                  visualDensity: VisualDensity.compact,
                  onPressed: () => Navigator.pop(context, ton),
                  icon: _SkinToneDot(
                    skinTone: ton,
                    gewaehlt: ton == skinTone,
                    size: 26,
                  ),
                ),
            ],
          ),
        ),
      ],
      child: Center(child: _SkinToneDot(skinTone: skinTone, size: 24)),
    );
  }
}

/// A circle in the colour of a skin tone.
class _SkinToneDot extends StatelessWidget {
  const _SkinToneDot({
    required this.skinTone,
    this.gewaehlt = false,
    this.size = 24,
  });

  final String skinTone;
  final bool gewaehlt;
  final double size;

  /// The colours of the five Fitzpatrick tones, as the emoji fonts use them too
  /// — plus the emoji yellow for "no skin tone", because that is exactly what
  /// one then gets to see.
  static const Map<String, Color> _colors = {
    '': Color(0xFFFFCC4D),
    SkinTone.light: Color(0xFFF7DECE),
    SkinTone.mediumLight: Color(0xFFF3D2A2),
    SkinTone.medium: Color(0xFFD5AB88),
    SkinTone.mediumDark: Color(0xFFAF7E57),
    SkinTone.dark: Color(0xFF7C533E),
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: _colors[skinTone] ?? _colors['']!,
        // Without a border the light tone would blur into a light ground and
        // the dark one into a dark one. The border therefore comes from the
        // theme, not from the tone colour — and turns primary where it is meant
        // to say "this is it".
        border: Border.all(
          color: gewaehlt ? colors.primary : colors.outlineVariant,
          width: gewaehlt ? 2.5 : 1.5,
        ),
      ),
    );
  }
}
