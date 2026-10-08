import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

const releaseRepo = 'zarkon4631/HeaNetwork';
const releasesPage = 'https://github.com/$releaseRepo/releases';

/// Compares dotted versions numerically (`1.10.0` > `1.9.3`). A leading `v`
/// and any `-suffix`/`+build` are ignored, except that a pre-release is
/// older than the same version without one.
int compareVersions(String a, String b) {
  (List<int>, bool) parse(String v) {
    var s = v.trim();
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
    s = s.split('+').first;
    final pre = s.contains('-');
    final nums = s
        .split('-')
        .first
        .split('.')
        .map((p) => int.tryParse(p) ?? 0)
        .toList();
    return (nums, pre);
  }

  final (na, preA) = parse(a);
  final (nb, preB) = parse(b);
  for (var i = 0; i < na.length || i < nb.length; i++) {
    final x = i < na.length ? na[i] : 0;
    final y = i < nb.length ? nb[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  if (preA == preB) return 0;
  return preA ? -1 : 1;
}

class ReleaseInfo {
  ReleaseInfo({
    required this.version,
    required this.notes,
    required this.pageUrl,
    this.assetName,
    this.assetUrl,
    this.assetSize,
    this.checksumsUrl,
  });

  final String version;
  final String notes;
  final String pageUrl;

  /// The installer for this device, when the release has one.
  final String? assetName;
  final Uri? assetUrl;
  final int? assetSize;
  final Uri? checksumsUrl;

  bool get canInstall => assetUrl != null;
}

class UpdateException implements Exception {
  UpdateException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Finds the entry for [fileName] in `sha256sum`-style text.
String? checksumFor(String sums, String fileName) {
  for (final line in const LineSplitter().convert(sums)) {
    final m = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+)$').firstMatch(line.trim());
    if (m != null && m.group(2)!.trim() == fileName) {
      return m.group(1)!.toLowerCase();
    }
  }
  return null;
}

/// Checks GitHub Releases for a newer version and downloads its installer.
class Updater {
  Updater({http.Client? client, this.repo = releaseRepo})
      : _client = client ?? http.Client();

  final http.Client _client;
  final String repo;

  /// Returns the latest release if it is newer than [currentVersion].
  /// [assetSuffix] selects the file for this platform, for example
  /// `windows-x64-setup.exe` or `android-arm64-v8a.apk`.
  Future<ReleaseInfo?> check(String currentVersion,
      {required List<String> assetSuffixes}) async {
    final res = await _client.get(
      Uri.parse('https://api.github.com/repos/$repo/releases/latest'),
      headers: {'Accept': 'application/vnd.github+json'},
    ).timeout(const Duration(seconds: 15));
    if (res.statusCode == 404) return null; // no releases yet
    if (res.statusCode != 200) {
      throw UpdateException('GitHub answered ${res.statusCode}');
    }
    final j = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final tag = j['tag_name'] as String? ?? '';
    if (tag.isEmpty || compareVersions(tag, currentVersion) <= 0) return null;

    final assets = (j['assets'] as List? ?? const []).cast<Map<String, dynamic>>();
    Map<String, dynamic>? asset;
    for (final suffix in assetSuffixes) {
      asset = assets
          .where((a) => '${a['name']}'.endsWith(suffix))
          .cast<Map<String, dynamic>?>()
          .firstWhere((_) => true, orElse: () => null);
      if (asset != null) break;
    }
    final sums = assets
        .where((a) => a['name'] == 'SHA256SUMS.txt')
        .cast<Map<String, dynamic>?>()
        .firstWhere((_) => true, orElse: () => null);

    return ReleaseInfo(
      version: tag.replaceFirst(RegExp('^[vV]'), ''),
      notes: j['body'] as String? ?? '',
      pageUrl: j['html_url'] as String? ?? releasesPage,
      assetName: asset?['name'] as String?,
      assetUrl: asset == null
          ? null
          : Uri.parse(asset['browser_download_url'] as String),
      assetSize: (asset?['size'] as num?)?.toInt(),
      checksumsUrl: sums == null
          ? null
          : Uri.parse(sums['browser_download_url'] as String),
    );
  }

  /// Downloads the installer into [dir] and verifies it against the
  /// release's `SHA256SUMS.txt`. A release without checksums, or with a
  /// mismatch, is refused.
  Future<File> download(ReleaseInfo release, Directory dir,
      {void Function(double progress)? onProgress}) async {
    final url = release.assetUrl;
    final name = release.assetName;
    if (url == null || name == null) {
      throw UpdateException('this release has no installer for this device');
    }
    final sumsUrl = release.checksumsUrl;
    if (sumsUrl == null) {
      throw UpdateException('the release does not publish checksums');
    }
    final sumsRes = await _client.get(sumsUrl).timeout(const Duration(seconds: 20));
    if (sumsRes.statusCode != 200) {
      throw UpdateException('cannot download checksums (${sumsRes.statusCode})');
    }
    final expected = checksumFor(utf8.decode(sumsRes.bodyBytes), name);
    if (expected == null) {
      throw UpdateException('no checksum listed for $name');
    }

    await dir.create(recursive: true);
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    final res = await _client.send(http.Request('GET', url));
    if (res.statusCode != 200) {
      throw UpdateException('download failed (${res.statusCode})');
    }
    final total = res.contentLength ?? release.assetSize ?? 0;
    final sink = file.openWrite();
    final digestSink = _DigestSink();
    final hasher = sha256.startChunkedConversion(digestSink);
    var received = 0;
    try {
      await for (final chunk in res.stream) {
        sink.add(chunk);
        hasher.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }
    } finally {
      await sink.close();
      hasher.close();
    }
    final actual = digestSink.value.toString();
    if (actual != expected) {
      await file.delete();
      throw UpdateException('checksum mismatch, the download was discarded');
    }
    return file;
  }

  void close() => _client.close();
}

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
