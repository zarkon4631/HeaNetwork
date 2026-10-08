import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'backdrop.dart';
import 'home_page.dart';
import 'routing_page.dart';
import 'settings_page.dart';
import 'theme.dart';

/// The selected top-level tab, reachable from any page so that e.g. a
/// banner can jump to the settings.
class ShellTab extends InheritedNotifier<ValueNotifier<int>> {
  const ShellTab({super.key, required ValueNotifier<int> tab, required super.child})
      : super(notifier: tab);

  static const home = 0;
  static const routing = 1;
  static const settings = 2;

  static ValueNotifier<int> of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellTab>()!.notifier!;
}

/// The app icon, as drawn by tool/gen_icons.mjs.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 40});
  final double size;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.26),
        child: Image.asset('assets/icons/app.png',
            width: size, height: size, filterQuality: FilterQuality.medium),
      );
}

class Shell extends StatefulWidget {
  const Shell({super.key, this.initialTab = ShellTab.home});

  final int initialTab;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  late final _tab = ValueNotifier(widget.initialTab);

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return AnimatedBackdrop(
      connected: state.isConnected,
      animate: state.settings.animations,
      child: ShellTab(
        tab: _tab,
        child: ValueListenableBuilder<int>(
          valueListenable: _tab,
          builder: (context, index, _) => _build(context, state, index),
        ),
      ),
    );
  }

  Widget _build(BuildContext context, AppState state, int index) {
    final s = S.of(context);
    final destinations = [
      (Icons.home_outlined, Icons.home_rounded, s.navHome),
      (Icons.alt_route_outlined, Icons.alt_route_rounded, s.navRouting),
      (Icons.settings_outlined, Icons.settings_rounded, s.navSettings),
    ];
    final pages = IndexedStack(
      index: index,
      children: const [HomePage(), RoutingPage(), SettingsPage()],
    );
    final body = Column(
      children: [
        const _Banners(),
        Expanded(child: pages),
      ],
    );

    return LayoutBuilder(builder: (context, constraints) {
      if (state.compactView && state.isWindows) {
        return const Scaffold(backgroundColor: Colors.transparent, body: CompactView());
      }

      // A TV always gets the side rail: it is what a remote navigates best,
      // and its panel loses the edges to overscan, hence the padding.
      if (constraints.maxWidth >= 700 || state.isTv) {
        return Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            minimum: state.isTv
                ? const EdgeInsets.symmetric(horizontal: 28, vertical: 18)
                : EdgeInsets.zero,
            child: Row(
              children: [
                _Rail(
                  state: state,
                  index: index,
                  destinations: destinations,
                  onSelect: (i) => _tab.value = i,
                ),
                Expanded(child: body),
              ],
            ),
          ),
        );
      }
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Column(
            children: [
              _TopBar(state: state),
              Expanded(child: body),
            ],
          ),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: index,
          onDestinationSelected: (i) => _tab.value = i,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          destinations: [
            for (final (icon, selected, label) in destinations)
              NavigationDestination(
                icon: Icon(icon),
                selectedIcon: Icon(selected),
                label: label,
              ),
          ],
        ),
      );
    });
  }
}

/// Quick switches that are not worth a trip to the settings.
class _QuickToggles extends StatelessWidget {
  const _QuickToggles({required this.state, this.axis = Axis.vertical});
  final AppState state;
  final Axis axis;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final children = [
      IconButton(
        tooltip: s.themeToggle,
        onPressed: () => state.updateSettings(
            (st) => st.themeMode = dark ? 'light' : 'dark',
            affectsCore: false),
        icon: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          transitionBuilder: (child, a) => RotationTransition(
              turns: Tween(begin: 0.75, end: 1.0).animate(a),
              child: FadeTransition(opacity: a, child: child)),
          child: Icon(dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
              key: ValueKey(dark), size: 20),
        ),
      ),
      if (state.isWindows)
        IconButton(
          tooltip: s.compactView,
          onPressed: () => state.setCompactView(true),
          icon: const Icon(Icons.picture_in_picture_alt_outlined, size: 20),
        ),
    ];
    return axis == Axis.vertical
        ? Column(mainAxisSize: MainAxisSize.min, children: children)
        : Row(mainAxisSize: MainAxisSize.min, children: children);
  }
}

class _Rail extends StatelessWidget {
  const _Rail({
    required this.state,
    required this.index,
    required this.destinations,
    required this.onSelect,
  });

  final AppState state;
  final int index;
  final List<(IconData, IconData, String)> destinations;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final status = StatusColors.of(context);
    return Container(
      width: 78,
      margin: const EdgeInsets.fromLTRB(10, 10, 0, 10),
      decoration: BoxDecoration(
        color: status.glass,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: status.glassBorder),
      ),
      // Scrolls on very short windows instead of overflowing.
      child: LayoutBuilder(
        builder: (context, c) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: c.maxHeight),
            child: IntrinsicHeight(
              child: Column(
                children: [
                  const SizedBox(height: 12),
                  const AppLogo(size: 42),
                  const SizedBox(height: 14),
                  for (final (i, (icon, selected, label)) in destinations.indexed)
                    _RailItem(
                      icon: i == index ? selected : icon,
                      label: label,
                      selected: i == index,
                      onTap: () => onSelect(i),
                    ),
                  const Spacer(),
                  if (state.isWindows) ...[
                    ModeSlider(state: state),
                    const SizedBox(height: 6),
                  ],
                  Divider(indent: 16, endIndent: 16, color: scheme.outlineVariant),
                  _QuickToggles(state: state),
                  const SizedBox(height: 6),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Material(
        color: selected ? scheme.primary.withValues(alpha: 0.14) : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: double.infinity,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                children: [
                  Icon(icon, size: 22, color: color),
                  const SizedBox(height: 3),
                  Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.fade,
                      softWrap: false,
                      style: TextStyle(
                          fontSize: 10.5,
                          color: color,
                          fontWeight: selected ? FontWeight.w600 : FontWeight.w500)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The header of the narrow (phone) layout.
class _TopBar extends StatelessWidget {
  const _TopBar({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 0),
      child: Row(
        children: [
          const AppLogo(size: 30),
          const SizedBox(width: 10),
          Expanded(
            child: Text('HeaNetwork',
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          ),
          if (state.isWindows) ModeSlider(state: state, showLabel: false),
          _QuickToggles(state: state, axis: Axis.horizontal),
        ],
      ),
    );
  }
}

/// The whole app as a small always-on-top card: connect and watch the
/// speed, nothing else.
class CompactView extends StatelessWidget {
  const CompactView({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final s = S.of(context);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const AppLogo(size: 24),
              const SizedBox(width: 8),
              Expanded(
                child: Text('HeaNetwork',
                    style:
                        theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
              ),
              ModeSlider(state: state, showLabel: false),
              IconButton(
                tooltip: s.fullView,
                onPressed: () => state.setCompactView(false),
                icon: const Icon(Icons.open_in_full_rounded, size: 18),
              ),
            ],
          ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ConnectPanel(state: state, dense: true),
          ),
          const Spacer(),
        ],
      ),
    );
  }
}

/// Strips above the page for things that need attention wherever you are:
/// unapplied settings and an available update.
class _Banners extends StatelessWidget {
  const _Banners();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final s = S.of(context);
    final scheme = Theme.of(context).colorScheme;
    final update = state.availableUpdate;

    Widget strip({
      required Color color,
      required Color onColor,
      required IconData icon,
      required String text,
      required String action,
      required VoidCallback? onAction,
      Widget? progress,
    }) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
        child: Material(
          color: color,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 2, 6, 2),
            child: Row(
              children: [
                Icon(icon, size: 18, color: onColor),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(text, style: TextStyle(color: onColor, fontSize: 13)),
                ),
                if (progress != null)
                  Padding(padding: const EdgeInsets.all(12), child: progress)
                else
                  TextButton(
                    onPressed: onAction,
                    style: TextButton.styleFrom(foregroundColor: onColor),
                    child: Text(action),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (state.pendingRestart && state.isConnected)
          strip(
            color: scheme.tertiaryContainer,
            onColor: scheme.onTertiaryContainer,
            icon: Icons.sync_rounded,
            text: s.pendingRestart,
            action: s.reconnect,
            onAction: state.reconnect,
          ),
        if (update != null)
          strip(
            color: scheme.primaryContainer,
            onColor: scheme.onPrimaryContainer,
            icon: Icons.system_update_alt_rounded,
            text: state.updateError == null
                ? s.updateAvailable(update.version)
                : '${s.updateFailed}: ${state.updateError}',
            action: s.navSettings,
            onAction: () => ShellTab.of(context).value = ShellTab.settings,
            progress: state.updateProgress == null
                ? null
                : SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      value: state.updateProgress == 0 ? null : state.updateProgress,
                    ),
                  ),
          ),
      ],
    );
  }
}
