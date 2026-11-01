import 'dart:async';

import '../core/models/panel_routing.dart';
import '../core/models/settings.dart';
import 'app_state_base.dart';

/// The routing profile that comes with the subscription or a link, the
/// site lists it names, and the user's switches around it.
mixin AppStateRouting on AppStateBase {
  /// The routing profile in force: the one the selected server's
  /// subscription came with, else one imported from a link; null when the
  /// user switched this off or there is none.
  @override
  PanelRouting? get panelRouting {
    if (!routing.usePanelRouting) return null;
    return availablePanelRouting;
  }

  /// The same, whether or not it is switched on.
  PanelRouting? get availablePanelRouting {
    final subId = selectedProfile?.subscriptionId;
    final fromSub =
        subscriptions.where((s) => s.id == subId).firstOrNull?.routing;
    return fromSub ?? routing.imported;
  }

  /// True when [availablePanelRouting] came with the subscription rather
  /// than from a link the user added.
  bool get panelRoutingFromSubscription {
    final subId = selectedProfile?.subscriptionId;
    return subscriptions.where((s) => s.id == subId).firstOrNull?.routing != null;
  }

  /// Lists a routing profile names that are not on this device yet.
  Set<String> get missingPanelRuleSets =>
      (availablePanelRouting?.ruleSetTags ?? const <String>{}).difference(ruleSets);

  /// Unfolds or folds the list of executables of a group rule. Only how the
  /// page looks: nothing about the connection changes.
  void toggleAppExpanded(AppRule rule) {
    rule.expanded = !rule.expanded;
    unawaited(store.saveRouting());
    notifyListeners();
  }

  void setUsePanelRouting(bool value) =>
      updateRouting((r) => r.usePanelRouting = value);

  /// Forgets a routing profile that was imported from a link.
  void removeImportedRouting() => updateRouting((r) => r.imported = null);
}
