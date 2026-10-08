import 'dart:convert';
import 'dart:io';

import 'win32.dart';

const _internetSettings =
    r'Software\Microsoft\Windows\CurrentVersion\Internet Settings';

/// Addresses that must never go through the proxy.
const _bypass = 'localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;'
    '172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;'
    '172.28.*;172.29.*;172.30.*;172.31.*;192.168.*;<local>';

/// Points the Windows system proxy at the local mixed inbound and puts the
/// user's previous settings back afterwards.
///
/// The previous settings live in [backupFile] for as long as the proxy is
/// ours, so a crash can be undone on the next launch ([restore]).
class SystemProxy {
  SystemProxy(this.backupFile, {this.keyPath = _internetSettings, this.notify = true});

  final File backupFile;
  final String keyPath;
  final bool notify;

  RegistryValue get _enable => RegistryValue(keyPath, 'ProxyEnable');
  RegistryValue get _server => RegistryValue(keyPath, 'ProxyServer');
  RegistryValue get _override => RegistryValue(keyPath, 'ProxyOverride');

  bool get isOurs => backupFile.existsSync();

  void enable(int port) {
    if (!isOurs) {
      backupFile.parent.createSync(recursive: true);
      backupFile.writeAsStringSync(jsonEncode({
        'enable': _enable.readInt(),
        'server': _server.readString(),
        'override': _override.readString(),
      }));
    }
    _server.writeString('127.0.0.1:$port');
    _override.writeString(_bypass);
    _enable.writeInt(1);
    if (notify) notifyProxySettingsChanged();
  }

  /// Restores what was there before [enable]. No-op if the proxy is not ours.
  void restore() {
    if (!isOurs) return;
    Map<String, dynamic> saved = const {};
    try {
      saved = Map<String, dynamic>.from(
          jsonDecode(backupFile.readAsStringSync()) as Map);
    } on Object {
      // Unreadable backup: fall through to "proxy off".
    }
    void put(RegistryValue v, Object? old) {
      if (old is String) {
        v.writeString(old);
      } else {
        v.delete();
      }
    }

    _enable.writeInt((saved['enable'] as num?)?.toInt() ?? 0);
    put(_server, saved['server']);
    put(_override, saved['override']);
    backupFile.deleteSync();
    if (notify) notifyProxySettingsChanged();
  }
}

/// "Start with Windows" through the per-user Run key.
class Autostart {
  const Autostart({this.keyPath = r'Software\Microsoft\Windows\CurrentVersion\Run'});

  final String keyPath;
  static const flag = '--autostart';

  RegistryValue get _value => RegistryValue(keyPath, 'HeaNetwork');

  bool get isEnabled => _value.readString() != null;

  void set(bool enabled, {String? executable}) {
    if (enabled) {
      _value.writeString('"${executable ?? Platform.resolvedExecutable}" $flag');
    } else {
      _value.delete();
    }
  }
}
