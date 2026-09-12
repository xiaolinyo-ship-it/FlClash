import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/features/codex/codex_account_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _window(int seconds, double used, double remaining) {
  return {
    'limitWindowSeconds': seconds,
    'usedPercent': used,
    'remainingPercent': remaining,
    'resetAt': '2026-09-12T12:00:00.000Z',
  };
}

Map<String, dynamic> _account({
  required String email,
  required dynamic primary,
  required dynamic secondary,
  String updatedAt = '2026-09-12T11:30:00.000Z',
}) {
  return {
    'email': email,
    'plan': 'plus',
    'primaryWindow': primary,
    'secondaryWindow': secondary,
    'updatedAt': updatedAt,
  };
}

void main() {
  test('parses the sanitized three-account fixture end to end', () async {
    final raw = await File(
      'test/fixtures/codex/snapshots_three_accounts.json',
    ).readAsString();
    final snapshot = CodexAccountSnapshot.fromJson(
      Map<String, dynamic>.from(jsonDecode(raw) as Map),
      readAt: DateTime(2026, 9, 12, 17),
    );

    expect(snapshot.accounts.map((account) => account.id), [
      '10000000-0000-4000-8000-000000000001',
      '20000000-0000-4000-8000-000000000002',
      '30000000-0000-4000-8000-000000000003',
    ]);
    expect(snapshot.accounts[0].fiveHour?.usedPercent, 25);
    expect(snapshot.accounts[0].weekly?.remainingPercent, 60);
    expect(snapshot.accounts[1].fiveHour?.isExhausted, isTrue);
    expect(snapshot.accounts[1].weekly?.isExhausted, isFalse);
    expect(snapshot.accounts[2].hasDataAnomaly, isTrue);
  });

  test('sorts accounts by stable id and maps windows by duration', () {
    final snapshot = CodexAccountSnapshot.fromJson({
      'snapshots': {
        'b-account': _account(
          email: 'beta@example.com',
          primary: _window(604800, 20, 80),
          secondary: _window(18000, 40, 60),
        ),
        'a-account': _account(
          email: 'alpha@example.com',
          primary: _window(18000, 10, 90),
          secondary: _window(604800, 30, 70),
        ),
      },
    }, readAt: DateTime(2026, 9, 12, 12));

    expect(snapshot.accounts.map((account) => account.id), [
      'a-account',
      'b-account',
    ]);
    expect(snapshot.accounts.first.fiveHour?.usedPercent, 10);
    expect(snapshot.accounts.first.weekly?.usedPercent, 30);
    expect(snapshot.accounts.first.displayName, 'al***@example.com');
  });

  test('normalizes legacy remaining percentage using the CLI meaning', () {
    final snapshot = CodexAccountSnapshot.fromJson({
      'snapshots': {
        'account': _account(
          email: 'account@example.com',
          primary: _window(18000, 100, 0),
          secondary: _window(604800, 100, 23),
        ),
      },
    }, readAt: DateTime(2026, 9, 12, 12));

    final account = snapshot.accounts.single;
    expect(account.hasDataAnomaly, isFalse);
    expect(account.statusAt(DateTime(2026, 9, 12, 12)), CodexAccountStatus.exhausted);
    expect(account.weekly?.usedPercent, 100);
    expect(account.weekly?.remainingPercent, 0);
  });

  test('keeps five-hour exhaustion independent from weekly quota', () {
    final snapshot = CodexAccountSnapshot.fromJson({
      'snapshots': {
        'account': _account(
          email: 'account@example.com',
          primary: _window(18000, 100, 0),
          secondary: _window(604800, 98, 2),
        ),
      },
    }, readAt: DateTime(2026, 9, 12, 12));

    final account = snapshot.accounts.single;
    expect(
      account.statusAt(DateTime(2026, 9, 12, 12)),
      isNot(CodexAccountStatus.dataAnomaly),
    );
    expect(account.fiveHour?.isExhausted, isTrue);
    expect(account.weekly?.isExhausted, isFalse);
    expect(
      account.statusAt(DateTime(2026, 9, 12, 12)),
      CodexAccountStatus.exhausted,
    );
  });

  test('marks old successful data as expired', () {
    final snapshot = CodexAccountSnapshot.fromJson({
      'snapshots': {
        'account': _account(
          email: 'account@example.com',
          primary: _window(18000, 20, 80),
          secondary: _window(604800, 30, 70),
          updatedAt: '2026-09-12T09:00:00.000Z',
        ),
      },
    }, readAt: DateTime(2026, 9, 12, 12));

    expect(
      snapshot.accounts.single.statusAt(DateTime(2026, 9, 12, 12)),
      CodexAccountStatus.expired,
    );
  });

  test('classifies invalid JSON and invalid shape separately', () async {
    final invalidJson = await CodexAccountSnapshotReader(
      readText: () async => '{',
    ).read();
    final invalidShape = await CodexAccountSnapshotReader(
      readText: () async => '{"snapshots": []}',
    ).read();

    expect(invalidJson.failure, CodexSnapshotReadFailure.invalidJson);
    expect(invalidShape.failure, CodexSnapshotReadFailure.invalidShape);
  });

  test('persists sanitized account data and falls back to it', () async {
    final temp = await Directory.systemTemp.createTemp('flclash-codex-cache-');
    final cachePath = '${temp.path}/codex-accounts-cache.json';
    addTearDown(() => temp.delete(recursive: true));

    final live = CodexAccountSnapshotReader(
      cachePath: cachePath,
      readText: () async => jsonEncode({
        'snapshots': {
          'stable-account': _account(
            email: 'stable@example.com',
            primary: _window(18000, 20, 80),
            secondary: _window(604800, 30, 70),
          ),
        },
      }),
    );
    final liveResult = await live.read();
    expect(liveResult.failure, isNull);
    expect(liveResult.fromCache, isFalse);

    final cacheText = await File(cachePath).readAsString();
    expect(cacheText, isNot(contains('stable@example.com')));

    final fallback = CodexAccountSnapshotReader(
      cachePath: cachePath,
      readText: () async => '{',
    );
    final fallbackResult = await fallback.read();
    expect(fallbackResult.failure, CodexSnapshotReadFailure.invalidJson);
    expect(fallbackResult.fromCache, isTrue);
    expect(fallbackResult.snapshot?.accounts.single.displayName,
        'st***@example.com');
  });
}
