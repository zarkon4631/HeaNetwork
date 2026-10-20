import 'dart:io';

/// Where the app keeps its files and finds its bundled pieces.
class AppPaths {
  AppPaths({required this.support, this.corePath, this.xrayPath});

  final Directory support;

  /// Core executable (Windows only).
  final String? corePath;

  /// Xray-core executable next to it, for what the core cannot reach
  /// (Windows only; null when it is not there).
  final String? xrayPath;

  Directory get data => Directory('${support.path}${Platform.pathSeparator}data');
  Directory get run => Directory('${support.path}${Platform.pathSeparator}run');
  Directory get ruleSets =>
      Directory('${support.path}${Platform.pathSeparator}rulesets');
  Directory get downloads =>
      Directory('${support.path}${Platform.pathSeparator}downloads');
  File get proxyBackup =>
      File('${run.path}${Platform.pathSeparator}system-proxy.json');
  File get coreLog => File('${run.path}${Platform.pathSeparator}core.log');
}
