import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:heanetwork/core/services/backup.dart';
import 'package:heanetwork/core/services/storage.dart';
import 'package:heanetwork/state/app_state_base.dart';

import 'support.dart';

void main() {
  test('a password-sealed copy opens with the same password', () async {
    const plain = '{"app":"heanetwork","version":1,"profiles":[]}';

    final sealed = await encodeBackup(plain, 'пароль');

    expect(isBackupEncrypted(sealed), isTrue);
    expect(sealed, isNot(contains(plain)));
    expect(await decodeBackup(sealed, password: 'пароль'), {
      'app': 'heanetwork',
      'version': 1,
      'profiles': <Object?>[],
    });
  });

  test(
    'a sealed copy is not opened by another password or without one',
    () async {
      final sealed = await encodeBackup('{"app":"heanetwork"}', 'right');

      expect(await decodeBackup(sealed, password: 'wrong'), isNull);
      expect(await decodeBackup(sealed), isNull);
      expect(await decodeBackup(sealed, password: ''), isNull);
    },
  );

  test('changing a sealed copy makes it fail authentication', () async {
    final sealed = await encodeBackup('{"app":"heanetwork"}', 'password');
    final at = sealed.length - 30;
    final changed = sealed.replaceRange(
      at,
      at + 1,
      sealed[at] == 'A' ? 'B' : 'A',
    );

    expect(await decodeBackup(changed, password: 'password'), isNull);
  });

  test('an unsealed copy stays plain JSON and needs no password', () async {
    expect(
      await encodeBackup('{"app":"heanetwork"}', ''),
      '{"app":"heanetwork"}',
    );
    expect(await decodeBackup(' {"app":"heanetwork","version":1} '), {
      'app': 'heanetwork',
      'version': 1,
    });
    expect(isBackupEncrypted('{"app":"heanetwork"}'), isFalse);
    expect(await decodeBackup('not a backup'), isNull);
  });

  test('restoring replaces and saves the whole app, a bad password changes nothing', () async {
    final state = makeState();
    final selected = state.selectedProfile!.id;
    final sealed = await encodeBackup(
      jsonEncode(state.store.toBackup()),
      'secret',
    );
    state.store
      ..profiles.clear()
      ..subscriptions.clear()
      ..settings.locale = 'en'
      ..settings.selectedProfileId = null;

    expect(
      await state.restoreBackup(sealed, password: 'wrong'),
      BackupRestore.badPassword,
    );
    expect(state.store.profiles, isEmpty);
    expect(state.store.settings.locale, 'en');

    expect(
      await state.restoreBackup(sealed, password: 'secret'),
      BackupRestore.ok,
    );
    expect(state.profiles, hasLength(7));
    expect(state.subscriptions, hasLength(1));
    expect(state.selectedProfile?.id, selected);
    expect(state.settings.locale, 'system');
    expect(state.routing.ruDirect, isTrue);

    final loaded = AppStore(state.store.dir);
    await loaded.load();
    expect(loaded.profiles, hasLength(7));
    expect(loaded.subscriptions, hasLength(1));
    expect(loaded.settings.selectedProfileId, selected);
  });

  test('an incomplete copy cannot erase the current servers', () async {
    final state = makeState();
    final incomplete = jsonEncode({
      'app': 'heanetwork',
      'version': 1,
      'settings': state.settings.toJson(),
      'routing': state.routing.toJson(),
    });

    expect(await state.restoreBackup(incomplete), BackupRestore.notABackup);
    expect(state.profiles, hasLength(7));
    expect(state.subscriptions, hasLength(1));
  });
}
