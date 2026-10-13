/// How much of a session's traffic went through the VPN and how much went
/// out directly, plus how many connections are open now.
class RouteTraffic {
  const RouteTraffic({
    this.vpnUp = 0,
    this.vpnDown = 0,
    this.directUp = 0,
    this.directDown = 0,
    this.open = 0,
  });

  final int vpnUp;
  final int vpnDown;
  final int directUp;
  final int directDown;
  final int open;

  int get vpn => vpnUp + vpnDown;
  int get direct => directUp + directDown;

  /// Adds what the [connections] carried since they were last [seen], and
  /// updates [seen]. A connection goes "direct" when its chain ends at the
  /// direct outbound, otherwise through the VPN.
  RouteTraffic add(
    List<({String id, List<String> chains, int up, int down})> connections,
    Map<String, (int up, int down)> seen,
  ) {
    var vu = vpnUp, vd = vpnDown, du = directUp, dd = directDown;
    final alive = <String>{};
    for (final c in connections) {
      alive.add(c.id);
      final before = seen[c.id] ?? (0, 0);
      final up = c.up > before.$1 ? c.up - before.$1 : 0;
      final down = c.down > before.$2 ? c.down - before.$2 : 0;
      seen[c.id] = (c.up, c.down);
      if (c.chains.contains('direct')) {
        du += up;
        dd += down;
      } else {
        vu += up;
        vd += down;
      }
    }
    seen.removeWhere((id, _) => !alive.contains(id));
    return RouteTraffic(
        vpnUp: vu, vpnDown: vd, directUp: du, directDown: dd, open: connections.length);
  }
}
