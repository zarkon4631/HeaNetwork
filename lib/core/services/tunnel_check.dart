import 'dart:io';

import '../config/config_builder.dart' show tunPeer4;

/// Finds out whether the running tunnel takes TCP connections at all, by
/// making one to the address the core keeps for itself inside the tunnel
/// ([tunPeer4]). The core answers there on its own, so the answer does not
/// depend on the VPN server or on the internet being reachable.
///
/// It matters because of how the tunnel's default network stack works on
/// Windows: every TCP connection is handed to the system as an incoming one
/// to the core. A firewall that blocks incoming connections then lets none
/// through, and the app shows "connected" while nothing works.
///
/// The port is not 53 on purpose: firewalls that take over DNS answer that
/// themselves, and the connection would never reach the tunnel.
///
/// Keeps trying for [patience], as the adapter may still be coming up right
/// after the core has started.
Future<bool> tunnelAcceptsTcp({
  Duration patience = const Duration(seconds: 4),
  Duration attempt = const Duration(milliseconds: 1500),
}) async {
  final deadline = DateTime.now().add(patience);
  while (true) {
    try {
      final socket = await Socket.connect(tunPeer4, 443, timeout: attempt);
      socket.destroy();
      return true;
    } on Object {
      if (!DateTime.now().isBefore(deadline)) return false;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }
}
