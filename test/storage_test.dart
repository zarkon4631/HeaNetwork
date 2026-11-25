// What is on disk is not always what this version of the app wrote: a file
// from another version, or one edited by hand, must not keep the app from
// starting.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:heanetwork/core/models/profile.dart';
import 'package:heanetwork/core/models/settings.dart';
import 'package:heanetwork/core/services/storage.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('hea_store_'));
  tearDown(() => dir.deleteSync(recursive: true));

  void put(String name, Object json) =>
      File('${dir.path}/$name').writeAsStringSync(jsonEncode(json));

  Future<AppStore> load() async {
    final store = AppStore(dir);
    await store.load();
    return store;
  }

  test('one unreadable server does not cost the others', () async {
    put('profiles.json', [
      {
        'id': 'a',
        'name': 'fine',
        'type': 'vless',
        'outbound': {'type': 'vless', 'server': 'h.example', 'server_port': 443},
      },
      {'id': 'b', 'name': 7, 'type': 'vless', 'outbound': 'not an object'},
      'not even an object',
    ]);
    put('subscriptions.json', [
      {'id': 's', 'name': 'fine', 'url': 'https://p.example/sub'},
      {'id': 't', 'name': 'odd', 'url': 'https://p.example/sub', 'totalBytes': 'a lot'},
    ]);
    final store = await load();
    expect(store.profiles.map((p) => p.id), ['a']);
    expect(store.subscriptions.map((s) => s.id), ['s']);
  });

  group('blocking ads', () {
    Map<String, Object?> server(String id) => {
          'id': id,
          'name': id,
          'type': 'vless',
          'outbound': {'type': 'vless', 'server': 'h.example', 'server_port': 443},
        };

    test('a switch that was on for every server becomes every server\'s own', () async {
      put('profiles.json', [server('a'), {...server('b'), 'favorite': true}]);
      put('routing.json', {'ruDirect': true, 'blockAds': true});
      final store = await load();
      expect(store.profiles.map((p) => p.blockAds), [true, true]);
      expect(store.profiles.last.favorite, isTrue);

      // And it is the servers' now: the old switch is gone from the file, so
      // the next start does not turn blocking back on where it was turned off.
      await store.flush();
      final routing =
          jsonDecode(File('${dir.path}/routing.json').readAsStringSync()) as Map;
      expect(routing.containsKey('blockAds'), isFalse);

      store.profiles.first.blockAds = false;
      await store.saveProfiles();
      final again = await load();
      expect(again.profiles.map((p) => p.blockAds), [false, true]);
    });

    test('a switch that was off leaves every server as it was', () async {
      put('profiles.json', [server('a'), {...server('b'), 'blockAds': true}]);
      put('routing.json', {'ruDirect': true, 'blockAds': false});
      final store = await load();
      expect(store.profiles.map((p) => p.blockAds), [false, true]);
    });

    test('the choice survives being stored', () async {
      put('profiles.json', []);
      final store = await load();
      store.profiles.addAll([
        ProxyProfile.fromJson(server('a'))
          ..blockAds = true
          ..favorite = true,
        ProxyProfile.fromJson(server('b')),
      ]);
      await store.saveProfiles();
      final again = await load();
      final saved = jsonDecode(File('${dir.path}/profiles.json').readAsStringSync()) as List;
      // What is off is not written at all.
      expect((saved[0] as Map).keys, containsAll(['blockAds', 'favorite']));
      expect((saved[1] as Map).keys, isNot(contains('blockAds')));
      expect(again.profiles.map((p) => (p.blockAds, p.favorite)),
          [(true, true), (false, false)]);
    });
  });

  test('settings of the wrong shape give way to the defaults and are kept aside',
      () async {
    put('settings.json', {'mixedPort': 'eighty', 'autoConnect': 'yes'});
    put('routing.json', {'apps': 'none', 'domains': 5});
    final store = await load();
    expect(store.settings.mixedPort, 2080);
    expect(store.settings.autoConnect, isFalse);
    expect(store.routing.apps, isEmpty);
    expect(File('${dir.path}/settings.json.corrupt').existsSync(), isTrue);
    expect(File('${dir.path}/routing.json.corrupt').existsSync(), isTrue);
  });

  test('a value the app has no choice for becomes the default', () async {
    put('settings.json', {
      'tunStack': 'lwip',
      'locale': 'de',
      'themeMode': 'sepia',
      'logLevel': 'trace',
      'mixedPort': 70000,
      'autoConnect': true,
    });
    final s = (await load()).settings;
    expect(s.tunStack, 'mixed');
    expect(s.locale, 'system');
    expect(s.themeMode, 'system');
    expect(s.logLevel, 'info');
    expect(s.mixedPort, 2080);
    expect(s.autoConnect, isTrue, reason: 'the rest of the file is kept');
  });

  test('what the app offers is what it accepts', () {
    for (final stack in tunStacks) {
      expect(AppSettings.fromJson({'tunStack': stack}).tunStack, stack);
    }
    for (final level in logLevels) {
      expect(AppSettings.fromJson({'logLevel': level}).logLevel, level);
    }
  });

  test('a save that cannot encode its file does not poison the queue', () async {
    final store = await load();
    store.routing.domains.add(_UnencodableRule());
    await store.saveRouting();
    expect(store.lastWriteError, isNotNull);
    // Later saves still happen, and flush() completes instead of throwing
    // for every caller that ever follows.
    store.settings.locale = 'ru';
    await store.saveSettings();
    await store.flush();
    expect(
        jsonDecode(File('${dir.path}/settings.json').readAsStringSync())['locale'],
        'ru');
  });
}

class _UnencodableRule extends DomainRule {
  _UnencodableRule() : super(kind: DomainRuleKind.domainKeyword, value: 'junk');
  @override
  Map<String, dynamic> toJson() => throw StateError('cannot be encoded');
}
