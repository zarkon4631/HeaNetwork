import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/models/settings.dart';
import '../core/services/app_catalog.dart';
import '../l10n/strings.dart';
import '../state/app_state.dart';
import 'widgets.dart';

class RoutingPage extends StatelessWidget {
  const RoutingPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final s = S.of(context);
    final routing = state.routing;
    final proxyDefault = routing.defaultAction == RouteAction.proxy;
    final theme = Theme.of(context);

    Future<void> addApp() async {
      final picked = await Navigator.push<AppEntry>(
          context,
          MaterialPageRoute(
              fullscreenDialog: true, builder: (_) => const _AppPickerPage()));
      if (picked == null) return;
      final rule = AppRule(
        name: picked.name,
        processName: picked.processName,
        processPath: picked.processPath,
        packageName: picked.packageName,
        // A new rule is an exception, so it starts as the opposite of the default.
        action: proxyDefault ? RouteAction.direct : RouteAction.proxy,
      );
      if (routing.apps.any((a) => a.matchKey == rule.matchKey)) {
        if (context.mounted) showSnack(context, s.appAlreadyAdded);
        return;
      }
      state.updateRouting((r) => r.apps.add(rule));
    }

    Future<void> addSite() async {
      final text = await promptText(context,
          title: s.addSite, hint: s.siteExample, label: s.sites);
      if (text == null || text.isEmpty) return;
      state.updateRouting((r) => r.domains.add(DomainRule.guess(
          text, proxyDefault ? RouteAction.direct : RouteAction.proxy)));
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: Text(s.navRouting)),
      body: PageBody(
        children: [
          Section(
            title: s.routingDefault,
            children: [
              _DefaultChoice(
                selected: proxyDefault,
                icon: Icons.shield_rounded,
                title: s.routeAllVpn,
                subtitle: s.routeAllVpnHint,
                onTap: () =>
                    state.updateRouting((r) => r.defaultAction = RouteAction.proxy),
              ),
              _DefaultChoice(
                selected: !proxyDefault,
                icon: Icons.checklist_rounded,
                title: s.routeSelectedVpn,
                subtitle: s.routeSelectedVpnHint,
                onTap: () =>
                    state.updateRouting((r) => r.defaultAction = RouteAction.direct),
              ),
            ],
          ),
          Section(
            title: s.apps,
            subtitle: s.appsHint,
            trailing: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton.tonalIcon(
                onPressed: addApp,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: Text(s.add),
              ),
            ),
            children: [
              if (state.isWindows &&
                  state.settings.mode == ConnectionMode.systemProxy &&
                  routing.apps.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline_rounded,
                          size: 18, color: theme.colorScheme.tertiary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(s.appsNeedTun,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                      ),
                    ],
                  ),
                ),
              if (routing.apps.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Text(s.noAppRules,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ),
              for (final rule in routing.apps) _AppRuleTile(rule: rule),
            ],
          ),
          Section(
            title: s.sites,
            trailing: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton.tonalIcon(
                onPressed: addSite,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: Text(s.add),
              ),
            ),
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.flag_outlined),
                title: Text(s.ruDirect),
                subtitle: Text(s.ruDirectHint),
                value: routing.ruDirect,
                onChanged: (v) => state.updateRouting((r) => r.ruDirect = v),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.hide_source_rounded),
                title: Text(s.blockAds),
                subtitle: Text(s.blockAdsHint),
                value: routing.blockAds,
                onChanged: (v) => state.updateRouting((r) => r.blockAds = v),
              ),
              for (final rule in routing.domains) _DomainRuleTile(rule: rule),
            ],
          ),
        ],
      ),
    );
  }
}

class _DefaultChoice extends StatelessWidget {
  const _DefaultChoice({
    required this.selected,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final bool selected;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Material(
        color: selected ? scheme.primaryContainer.withValues(alpha: 0.5) : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
              color: selected ? scheme.primary : scheme.outlineVariant,
              width: selected ? 1.5 : 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Icon(icon, color: selected ? scheme.primary : scheme.onSurfaceVariant),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(subtitle,
                          style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: selected ? scheme.primary : scheme.outline,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A rule row: identity on the left, the three-way action on the right, or
/// underneath when the window is narrow.
class _RuleRow extends StatelessWidget {
  const _RuleRow({
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.action,
    required this.onAction,
    required this.onDelete,
    this.onLongPress,
  });

  final Widget leading;
  final String title;
  final String subtitle;
  final RouteAction action;
  final ValueChanged<RouteAction> onAction;
  final VoidCallback onDelete;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = S.of(context);
    final identity = Row(
      children: [
        leading,
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w500)),
              Text(subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant)),
            ],
          ),
        ),
      ],
    );
    final remove = IconButton(
      tooltip: s.delete,
      onPressed: onDelete,
      icon: const Icon(Icons.close_rounded, size: 20),
    );

    return InkWell(
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
        child: LayoutBuilder(builder: (context, c) {
          final narrow = c.maxWidth < 640;
          final selector = ActionSelector(
              value: action, onChanged: onAction, compact: c.maxWidth < 440);
          if (narrow) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [Expanded(child: identity), remove]),
                const SizedBox(height: 6),
                Padding(padding: const EdgeInsets.only(right: 12), child: selector),
              ],
            );
          }
          return Row(children: [Expanded(child: identity), selector, remove]);
        }),
      ),
    );
  }
}

class _AppRuleTile extends StatelessWidget {
  const _AppRuleTile({required this.rule});
  final AppRule rule;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final s = S.of(context);
    final target = rule.packageName ??
        (rule.matchByPath ? rule.processPath : rule.processName) ??
        '';

    Future<void> options() async {
      if (rule.processPath == null) return;
      final exact = await showDialog<bool>(
        context: context,
        builder: (context) {
          var value = rule.matchByPath;
          return StatefulBuilder(
            builder: (context, setState) => AlertDialog(
              title: Text(rule.name),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(rule.processPath!,
                        style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(s.matchByPath),
                      subtitle: Text(s.matchByPathHint),
                      value: value,
                      onChanged: (v) => setState(() => value = v),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context), child: Text(s.cancel)),
                FilledButton(
                    onPressed: () => Navigator.pop(context, value), child: Text(s.save)),
              ],
            ),
          );
        },
      );
      if (exact != null) state.updateRouting((_) => rule.matchByPath = exact);
    }

    return _RuleRow(
      leading: AppIconView(processPath: rule.processPath, packageName: rule.packageName),
      title: rule.name,
      subtitle: target,
      action: rule.action,
      onAction: (a) => state.updateRouting((_) => rule.action = a),
      onDelete: () => state.updateRouting((r) => r.apps.remove(rule)),
      onLongPress: rule.processPath == null ? null : options,
    );
  }
}

class _DomainRuleTile extends StatelessWidget {
  const _DomainRuleTile({required this.rule});
  final DomainRule rule;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final s = S.of(context);
    final (icon, kind) = switch (rule.kind) {
      DomainRuleKind.domainSuffix => (Icons.language_rounded, s.kindSuffix),
      DomainRuleKind.domain => (Icons.language_rounded, s.kindDomain),
      DomainRuleKind.domainKeyword => (Icons.text_fields_rounded, s.kindKeyword),
      DomainRuleKind.ipCidr => (Icons.lan_outlined, s.kindCidr),
    };
    return _RuleRow(
      leading: SizedBox.square(
          dimension: 32,
          child: Icon(icon, color: Theme.of(context).colorScheme.onSurfaceVariant)),
      title: rule.value,
      subtitle: kind,
      action: rule.action,
      onAction: (a) => state.updateRouting((_) => rule.action = a),
      onDelete: () => state.updateRouting((r) => r.domains.remove(rule)),
    );
  }
}

/// Full-screen chooser: running programs on Windows, installed apps on
/// Android, with search.
class _AppPickerPage extends StatefulWidget {
  const _AppPickerPage();

  @override
  State<_AppPickerPage> createState() => _AppPickerPageState();
}

class _AppPickerPageState extends State<_AppPickerPage> {
  late final Future<List<AppEntry>> _apps = AppCatalog.list();
  var _query = '';
  var _showSystem = false;

  Future<void> _browse() async {
    final file = await openFile(acceptedTypeGroups: const [
      XTypeGroup(label: 'exe', extensions: ['exe']),
    ]);
    if (file == null || !mounted) return;
    Navigator.pop(context, appEntryForExecutable(file.path));
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(s.pickApp),
        actions: [
          if (Platform.isWindows)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: TextButton.icon(
                onPressed: _browse,
                icon: const Icon(Icons.folder_open_rounded, size: 18),
                label: Text(s.browseExe),
              ),
            ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: TextField(
                  autofocus: Platform.isWindows,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search_rounded),
                    hintText: s.search,
                  ),
                  onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Text(
                            Platform.isWindows ? s.pickAppRunning : s.pickAppInstalled,
                            style: theme.textTheme.labelLarge
                                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                      ),
                    ),
                    Text(s.showSystemApps, style: theme.textTheme.bodySmall),
                    Switch(
                        value: _showSystem,
                        onChanged: (v) => setState(() => _showSystem = v)),
                  ],
                ),
              ),
              Expanded(
                child: FutureBuilder<List<AppEntry>>(
                  future: _apps,
                  builder: (context, snap) {
                    if (!snap.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final apps = snap.data!.where((a) {
                      if (a.system && !_showSystem) return false;
                      if (_query.isEmpty) return true;
                      return a.name.toLowerCase().contains(_query) ||
                          a.subtitle.toLowerCase().contains(_query);
                    }).toList();
                    return ListView.builder(
                      itemCount: apps.length,
                      itemBuilder: (context, i) {
                        final a = apps[i];
                        return ListTile(
                          leading: AppIconView(
                              processPath: a.processPath, packageName: a.packageName),
                          title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(a.subtitle,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          onTap: () => Navigator.pop(context, a),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
