import 'dart:async';
import 'dart:convert';

import '../core/models/panel_routing.dart';
import '../core/models/profile.dart';
import '../core/parsers/import_parser.dart';
import '../core/services/core_controller.dart';
import '../core/services/public_ip.dart';
import '../core/services/subscription_service.dart';
import 'app_state_base.dart';

/// The user's servers and the subscriptions they came from: importing,
/// refreshing, keeping the selection sane.
mixin AppStateProfiles on AppStateBase {
  /// Imports whatever [text] holds: links, a config file, or a
  /// subscription URL (which is fetched right away).
  Future<ImportOutcome> importText(String text) async {
    if (PanelRouting.isLink(text)) {
      final profile = PanelRouting.parseLink(text);
      if (profile == null && !text.trim().startsWith('happ://routing/off')) {
        return ImportOutcome(errors: const ['routing link']);
      }
      updateRouting((r) {
        r.imported = profile;
        if (profile != null) r.usePanelRouting = true;
      });
      unawaited(fetchPanelRuleSets());
      return ImportOutcome(routing: profile ?? PanelRouting());
    }
    final parsed = parseImportText(text, xray: xrayAvailable);
    if (parsed.subscriptionUrl != null) {
      try {
        final sub = await addSubscription(parsed.subscriptionUrl!);
        return ImportOutcome(
            added: profilesOf(sub.id).length,
            subscription: sub,
            unsupported: sub.unsupported);
      } on Object catch (e) {
        return ImportOutcome(failure: e);
      }
    }
    if (parsed.profiles.isNotEmpty) {
      addProfiles(parsed.profiles);
      profilesChanged();
    }
    return ImportOutcome(
        added: parsed.profiles.length,
        errors: parsed.errors,
        unsupported: parsed.skipped);
  }

  void addProfile(ProxyProfile p) {
    addProfiles([p]);
    profilesChanged();
  }

  void renameProfile(ProxyProfile p, String name) {
    p.name = name;
    profilesChanged();
  }

  void replaceOutbound(ProxyProfile p, Map<String, dynamic> outbound) {
    p.outbound = outbound;
    if (status != CoreStatus.stopped) noteCoreChange();
    profilesChanged();
  }

  void deleteProfile(ProxyProfile p) {
    profiles.remove(p);
    _reselectAfterRemoval();
    profilesChanged();
  }

  /// Moves the selection off a server that is gone. A connection running
  /// through that server goes on until the reconnect this asks for.
  void _reselectAfterRemoval() {
    if (profiles.any((p) => p.id == settings.selectedProfileId)) return;
    settings.selectedProfileId = profiles.firstOrNull?.id;
    unawaited(store.saveSettings());
    if (status != CoreStatus.stopped) noteCoreChange();
  }

  /// One request to a subscription server. With device identification on it
  /// names the device and the address it is seen under, which a server
  /// behind a proxy, or one reached through the tunnel, cannot tell itself.
  Future<SubscriptionResult> _fetch(String url) async {
    final identify = settings.sendHwid;
    return fetchSubscription(
      url,
      client: httpClient,
      userAgent: 'HeaNetwork/$appVersion',
      xray: xrayAvailable,
      deviceHeaders: {
        if (identify) ...?device?.headers,
        if (identify) ...addressHeaders(await publicIp?.current()),
      },
    );
  }

  Future<Subscription> addSubscription(String url, {String? name}) async {
    final sub = Subscription(name: name ?? '', url: subscriptionAddress(url));
    final result = await _fetch(sub.url);
    if (sub.name.isEmpty) {
      sub.name = result.title ?? Uri.tryParse(sub.url)?.host ?? sub.url;
    }
    // The subscription must be in the list before it is applied: applying it
    // asks for the panel's rule-sets, which counts what is in the list.
    subscriptions.add(sub);
    _applySubscription(sub, result);
    unawaited(store.saveSubscriptions());
    profilesChanged();
    return sub;
  }

  Future<void> refreshSubscription(Subscription sub) async {
    final result = await _fetch(sub.url);
    if (!subscriptions.contains(sub)) {
      // Deleted while the request was out. Applying the answer would bring
      // the deleted subscription's servers back from the dead.
      return;
    }
    _applySubscription(sub, result);
    unawaited(store.saveSubscriptions());
    profilesChanged();
  }

  bool refreshingSubscriptions = false;

  /// Reloads every subscription. Returns one message per failure, prefixed
  /// with the subscription's name, or null when nothing was refreshed
  /// because a round is already under way.
  Future<List<SubscriptionException>?> refreshAllSubscriptions(
      {bool onlyDue = false}) async {
    if (refreshingSubscriptions) return null;
    final now = DateTime.now();
    final targets =
        subscriptions.where((s) => !onlyDue || s.isDue(now)).toList();
    if (targets.isEmpty) return const [];
    refreshingSubscriptions = true;
    notifyListeners();
    final failures = <SubscriptionException>[];
    try {
      for (final sub in targets) {
        try {
          await refreshSubscription(sub);
        } on SubscriptionException catch (e) {
          failures.add(SubscriptionException('${sub.name}: ${e.message}', code: e.code));
        } on Object catch (e) {
          failures.add(SubscriptionException('${sub.name}: $e'));
        }
      }
    } finally {
      refreshingSubscriptions = false;
      notifyListeners();
    }
    return failures;
  }

  /// Background refresh of subscriptions whose panel-requested interval has
  /// passed. Failures are ignored: the next tick tries again.
  @override
  Future<void> refreshDueSubscriptions() => refreshAllSubscriptions(onlyDue: true);

  static String _fingerprint(ProxyProfile p) => jsonEncode(p.outbound);

  void _applySubscription(Subscription sub, SubscriptionResult result) {
    final old = profilesOf(sub.id);
    final activeBefore = selectedProfile;
    final activeFingerprint =
        activeBefore == null ? null : _fingerprint(activeBefore);

    // A server that is still in the list keeps its identity, so the
    // selection, its measured delay and anything else keyed by id survive.
    final unmatched = List.of(old);
    final fresh = <ProxyProfile>[];
    for (final p in result.profiles) {
      final index = unmatched
          .indexWhere((o) => o.name == p.name && o.server == p.server && o.type == p.type);
      final before = index < 0 ? null : unmatched.removeAt(index);
      fresh.add(ProxyProfile(
        id: before?.id,
        name: p.name,
        type: p.type,
        outbound: p.outbound,
        link: p.link,
        description: p.description,
        subscriptionId: sub.id,
        latencyMs: before?.latencyMs,
      ));
    }

    final selectedGone = unmatched.any((o) => o.id == settings.selectedProfileId);
    profiles.removeWhere((p) => p.subscriptionId == sub.id);
    addProfiles(fresh);
    if (selectedGone) {
      settings.selectedProfileId = (fresh.firstOrNull ?? profiles.firstOrNull)?.id;
      unawaited(store.saveSettings());
    }

    sub
      ..updatedAt = DateTime.now()
      ..uploadBytes = result.upload
      ..downloadBytes = result.download
      ..totalBytes = result.total
      ..expireAt = result.expire
      ..updateIntervalHours = result.updateIntervalHours
      ..supportUrl = result.supportUrl
      ..webPageUrl = result.webPageUrl
      ..announce = result.announce
      ..unsupported = List.of(result.unsupported);

    // The panel's routing rules travel with the subscription: no header
    // means the administrator took them away.
    final routingBefore = jsonEncode(sub.routing?.toJson());
    sub.routing = result.routing;
    final routingChanged = jsonEncode(sub.routing?.toJson()) != routingBefore;
    if (routingChanged) {
      configRevision++;
      if (status != CoreStatus.stopped &&
          routing.usePanelRouting &&
          activeBefore?.subscriptionId == sub.id) {
        noteCoreChange();
      }
    }
    unawaited(fetchPanelRuleSets());

    // Only bother the user about reconnecting when the server in use
    // actually changed; a routine refresh must not nag.
    if (status != CoreStatus.stopped) {
      final activeAfter = selectedProfile;
      final changed = activeBefore?.subscriptionId == sub.id &&
          (activeAfter == null || _fingerprint(activeAfter) != activeFingerprint);
      if (changed) noteCoreChange();
    }
  }

  /// Folds or unfolds a group of the list: [sub], or the user's own servers
  /// when it is null.
  void toggleCollapsed(Subscription? sub) {
    if (sub == null) {
      settings.ownServersCollapsed = !settings.ownServersCollapsed;
      unawaited(store.saveSettings());
    } else {
      sub.collapsed = !sub.collapsed;
      unawaited(store.saveSubscriptions());
    }
    notifyListeners();
  }

  void renameSubscription(Subscription sub, String name) {
    sub.name = name;
    unawaited(store.saveSubscriptions());
    notifyListeners();
  }

  void deleteSubscription(Subscription sub) {
    profiles.removeWhere((p) => p.subscriptionId == sub.id);
    subscriptions.remove(sub);
    _reselectAfterRemoval();
    unawaited(store.saveSubscriptions());
    profilesChanged();
  }
}
