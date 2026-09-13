import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/features/codex/codex_account_switcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'reads registered account slots without depending on file order',
    () async {
      final switcher = CodexAccountSwitcher(
        readRegistryText: () async => jsonEncode({
          'accounts': [
            {'id': 'slot-b', 'home': r'C:\codex\b'},
            {'id': 'slot-a', 'home': r'C:\codex\a'},
          ],
        }),
        isWindows: () => true,
      );

      final slots = await switcher.readSlots();

      expect(slots.map((slot) => slot.id), ['slot-b', 'slot-a']);
      expect(slots.map((slot) => slot.home), [r'C:\codex\b', r'C:\codex\a']);
    },
  );

  test(
    'switches one slot, backs up ambient auth, and schedules restart',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'flclash-codex-switch-',
      );
      addTearDown(() => root.delete(recursive: true));
      final target = Directory('${root.path}${Platform.pathSeparator}target');
      final ambient = Directory('${root.path}${Platform.pathSeparator}ambient');
      await target.create();
      await ambient.create();
      await File(
        '${target.path}${Platform.pathSeparator}auth.json',
      ).writeAsString('target-fixture');
      await File(
        '${ambient.path}${Platform.pathSeparator}auth.json',
      ).writeAsString('ambient-fixture');
      var restartCount = 0;

      final switcher = CodexAccountSwitcher(
        ambientHomePath: ambient.path,
        backupDirectoryPath: '${root.path}${Platform.pathSeparator}backups',
        readRegistryText: () async => jsonEncode({
          'accounts': [
            {'id': 'target-slot', 'home': target.path},
          ],
        }),
        restartDesktop: () async => restartCount++,
        isWindows: () => true,
      );

      final result = await switcher.switchTo('target-slot');

      expect(result.switched, isTrue);
      expect(result.restartScheduled, isTrue);
      expect(restartCount, 1);
      expect(
        await File(
          '${ambient.path}${Platform.pathSeparator}auth.json',
        ).readAsString(),
        'target-fixture',
      );
      expect(result.backupPath, isNotNull);
      expect(await File(result.backupPath!).readAsString(), 'ambient-fixture');
    },
  );

  test('refuses a slot with no auth file and does not restart', () async {
    final root = await Directory.systemTemp.createTemp('flclash-codex-switch-');
    addTearDown(() => root.delete(recursive: true));
    var restartCount = 0;
    final switcher = CodexAccountSwitcher(
      ambientHomePath: root.path,
      readRegistryText: () async => jsonEncode({
        'accounts': [
          {'id': 'missing-slot', 'home': root.path},
        ],
      }),
      restartDesktop: () async => restartCount++,
      isWindows: () => true,
    );

    final result = await switcher.switchTo('missing-slot');

    expect(result.switched, isFalse);
    expect(result.restartScheduled, isFalse);
    expect(restartCount, 0);
    expect(result.failure, contains('认证文件'));
  });
}
