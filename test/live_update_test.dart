// Checks the published release the way an installed app would: finds it
// through the GitHub API, downloads the installer for each platform and
// verifies it against SHA256SUMS.txt.
//
// Talks to the real GitHub and downloads ~100 MB, so it only runs on
// request, e.g. after cutting a release:
//   $env:HEA_LIVE=1; flutter test test/live_update_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:heanetwork/core/services/updater.dart';

void main() {
  final live = Platform.environment['HEA_LIVE'] == '1';

  test('the latest release is found, downloadable and matches its checksums', () async {
    final updater = Updater();
    final tmp = Directory.systemTemp.createTempSync('hea_live_');
    addTearDown(() {
      updater.close();
      tmp.deleteSync(recursive: true);
    });

    for (final suffix in ['windows-x64-setup.exe', 'android-arm64-v8a.apk']) {
      // An installed 0.0.1 must be offered whatever is current.
      final release = await updater.check('0.0.1', assetSuffixes: [suffix]);
      expect(release, isNotNull, reason: 'no published release found');
      expect(release!.assetName, endsWith(suffix));
      expect(release.checksumsUrl, isNotNull, reason: 'release lacks SHA256SUMS.txt');

      final file = await updater.download(release, tmp);
      expect(file.lengthSync(), release.assetSize);
      // ignore: avoid_print
      print('${release.version}: ${release.assetName} '
          '(${(file.lengthSync() / 1048576).toStringAsFixed(1)} MB) verified');

      // The same version, once installed, must not be offered again.
      expect(await updater.check(release.version, assetSuffixes: [suffix]), isNull);
    }
  }, skip: live ? null : 'set HEA_LIVE=1 to run against the real release',
      timeout: const Timeout(Duration(minutes: 10)));
}
