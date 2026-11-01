import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../core/services/updater.dart';
import '../platform/windows/win32.dart' as win32;
import 'app_state_base.dart';

/// Finding, downloading and installing updates from GitHub releases.
mixin AppStateUpdates on AppStateBase {
  ReleaseInfo? availableUpdate;
  bool checkingUpdate = false;
  double? updateProgress;
  String? updateError;

  /// The last check reached GitHub, so "no update" really means up to date.
  bool lastUpdateCheckOk = false;

  static const _installChannel = MethodChannel('hea/core');

  Future<List<String>> _assetSuffixes() async {
    if (isWindows) {
      // Only a copy that the installer put there can be updated by running
      // the installer again; a portable copy just links to the release page.
      final sep = Platform.pathSeparator;
      final uninstaller =
          '${File(Platform.resolvedExecutable).parent.path}${sep}unins000.exe';
      return File(uninstaller).existsSync()
          ? const ['windows-x64-setup.exe']
          : const [];
    }
    try {
      final abi = await _installChannel.invokeMethod<String>('abi');
      return [if (abi != null) 'android-$abi.apk', 'android-universal.apk'];
    } on Object {
      return const ['android-universal.apk'];
    }
  }

  /// Looks for a newer release. With [silent] set, failures are swallowed
  /// (the periodic background check must not nag about being offline).
  @override
  Future<void> checkForUpdate({bool silent = false}) async {
    if (checkingUpdate) return;
    checkingUpdate = true;
    updateError = null;
    notifyListeners();
    try {
      availableUpdate = await updater.check(appVersion,
          assetSuffixes: await _assetSuffixes());
      lastUpdateCheckOk = true;
    } on Object catch (e) {
      lastUpdateCheckOk = false;
      if (!silent) updateError = '$e';
    } finally {
      checkingUpdate = false;
      notifyListeners();
    }
  }

  /// Downloads the update, verifies it and hands it to the OS installer.
  /// On Windows the app exits so the installer can replace its files.
  Future<void> installUpdate() async {
    final release = availableUpdate;
    if (release == null || !release.canInstall || updateProgress != null) return;
    updateError = null;
    updateProgress = 0;
    notifyListeners();
    try {
      final file = await updater.download(release, paths.downloads,
          onProgress: (p) {
            updateProgress = p;
            notifyListeners();
          });
      if (isWindows) {
        await disconnect();
        await store.flush();
        if (!win32.shellExecute(file.path, args: '/SILENT /RELAUNCH=1')) {
          throw UpdateException('could not start the installer');
        }
        exit(0);
      } else {
        await _installChannel.invokeMethod<void>('installApk', {'path': file.path});
      }
    } on Object catch (e) {
      updateError = '$e';
    } finally {
      updateProgress = null;
      notifyListeners();
    }
  }
}
