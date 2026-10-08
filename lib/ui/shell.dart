import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'home_page.dart';
import 'routing_page.dart';
import 'servers_page.dart';
import 'settings_page.dart';
import 'theme.dart';

/// The selected top-level tab, reachable from any page so that e.g. the
/// home screen can jump to the server list.
class ShellTab extends InheritedNotifier<ValueNotifier<int>> {
  const ShellTab({super.key, required ValueNotifier<int> tab, required super.child})
      : super(notifier: tab);

  static const home = 0;
  static const servers = 1;
  static const routing = 2;
  static const settings = 3;

  static ValueNotifier<int> of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellTab>()!.notifier!;
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
    return ShellTab(
      tab: _tab,
      child: ValueListenableBuilder<int>(
        valueListenable: _tab,
        builder: (context, index, _) => _build(context, index),
      ),
    );
  }

  Widget _build(BuildContext context, int index) {
    final s = S.of(context);
    final destinations = [
      (Icons.home_outlined, Icons.home_rounded, s.navHome),
      (Icons.dns_outlined, Icons.dns_rounded, s.navServers),
      (Icons.alt_route_outlined, Icons.alt_route_rounded, s.navRouting),
      (Icons.settings_outlined, Icons.settings_rounded, s.navSettings),
    ];
    final pages = IndexedStack(
      index: index,
      children: const [HomePage(), ServersPage(), RoutingPage(), SettingsPage()],
    );
    final body = Column(
      children: [
        const _Banners(),
        Expanded(child: pages),
      ],
    );

    return LayoutBuilder(builder: (context, constraints) {
      if (constraints.maxWidth >= 720) {
        return Scaffold(
          body: SafeArea(
            child: Row(
              children: [
                NavigationRail(
                  selectedIndex: index,
                  onDestinationSelected: (i) => _tab.value = i,
                  labelType: NavigationRailLabelType.all,
                  leading: const Padding(
                    padding: EdgeInsets.only(top: 8, bottom: 12),
                    child: _Logo(),
                  ),
                  destinations: [
                    for (final (icon, selected, label) in destinations)
                      NavigationRailDestination(
                        icon: Icon(icon),
                        selectedIcon: Icon(selected),
                        label: Text(label),
                      ),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: body),
              ],
            ),
          ),
        );
      }
      return Scaffold(
        body: SafeArea(child: body),
        bottomNavigationBar: NavigationBar(
          selectedIndex: index,
          onDestinationSelected: (i) => _tab.value = i,
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

class _Logo extends StatelessWidget {
  const _Logo();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(11),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [brandBlue, brandTeal],
        ),
      ),
      alignment: Alignment.center,
      child: Text('H',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: Colors.white, fontWeight: FontWeight.w800, height: 1)),
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
      return Material(
        color: color,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
          child: Row(
            children: [
              Icon(icon, size: 18, color: onColor),
              const SizedBox(width: 10),
              Expanded(
                child: Text(text, style: TextStyle(color: onColor, fontSize: 13.5)),
              ),
              if (progress != null)
                Padding(padding: const EdgeInsets.only(right: 12), child: progress)
              else
                TextButton(
                  onPressed: onAction,
                  style: TextButton.styleFrom(foregroundColor: onColor),
                  child: Text(action),
                ),
            ],
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
