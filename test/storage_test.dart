// What is on disk is not always what this version of the app wrote: a file
// from another version, or one edited by hand, must not keep the app from
// starting.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
