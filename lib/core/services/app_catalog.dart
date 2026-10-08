import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

import '../../platform/windows/win32.dart' as win32;

/// An application the user can write a routing rule for.
class AppEntry {
  const AppEntry({
    required this.name,
    this.processName,
    this.processPath,
    this.packageName,
    this.system = false,
  });

  final String name;
  final String? processName;
  final String? processPath;
  final String? packageName;

  /// Part of the OS rather than something the user installed.
  final bool system;

  String get subtitle => packageName ?? processName ?? '';
}

String _baseName(String path) => path.split(RegExp(r'[\\/]')).last;

List<AppEntry> _windowsApps() {
  final windir = (Platform.environment['WINDIR'] ?? r'C:\Windows').toLowerCase();
  final self = Platform.resolvedExecutable.toLowerCase();
  final out = <AppEntry>[];
  for (final path in win32.runningExecutables()) {
    final lower = path.toLowerCase();
    if (lower == self) continue;
    final exe = _baseName(path);
    final description = win32.fileDescription(path);
    out.add(AppEntry(
      name: description ?? exe.replaceFirst(RegExp(r'\.exe$', caseSensitive: false), ''),
      processName: exe,
      processPath: path,
      system: lower.startsWith('$windir\\'),
    ));
  }
  out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return out;
}

/// Describes an executable picked from disk rather than from the list.
AppEntry appEntryForExecutable(String path) {
  final exe = _baseName(path);
  String? description;
  if (Platform.isWindows) description = win32.fileDescription(path);
  return AppEntry(
    name: description ?? exe.replaceFirst(RegExp(r'\.exe$', caseSensitive: false), ''),
    processName: exe,
    processPath: path,
  );
}

/// Lists applications and loads their icons: running processes on Windows,
/// installed packages on Android.
class AppCatalog {
  static const _channel = MethodChannel('hea/apps');
  static final _icons = <String, Future<ui.Image?>>{};

  static Future<List<AppEntry>> list() async {
    if (Platform.isWindows) return Isolate.run(_windowsApps);
    if (Platform.isAndroid) {
      final raw = await _channel.invokeListMethod<Map<Object?, Object?>>('list');
      final out = [
        for (final m in raw ?? const <Map<Object?, Object?>>[])
          AppEntry(
            name: '${m['label'] ?? m['package']}',
            packageName: '${m['package']}',
            system: m['system'] == true,
          ),
      ];
      out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return out;
    }
    return const [];
  }

  /// The app's icon, or null. Results are cached for the app's lifetime.
  static Future<ui.Image?> icon({String? processPath, String? packageName}) {
    final key = packageName ?? processPath?.toLowerCase();
    if (key == null) return Future.value();
    return _icons.putIfAbsent(key, () => _load(processPath, packageName));
  }

  static Future<ui.Image?> _load(String? processPath, String? packageName) async {
    try {
      if (packageName != null && Platform.isAndroid) {
        final png = await _channel
            .invokeMethod<Uint8List>('icon', {'package': packageName});
        if (png == null) return null;
        final codec = await ui.instantiateImageCodec(png);
        return (await codec.getNextFrame()).image;
      }
      if (processPath != null && Platform.isWindows) {
        final px = win32.fileIcon(processPath);
        if (px == null) return null;
        final done = Completer<ui.Image>();
        ui.decodeImageFromPixels(
            px.bgra, px.width, px.height, ui.PixelFormat.bgra8888, done.complete);
        return await done.future;
      }
    } on Object {
      // An icon is decoration; a missing one is not an error.
    }
    return null;
  }
}
