import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/features/codex/codex_account_snapshot.dart';
import 'package:fl_clash/features/codex/codex_account_live.dart';
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
  String? providerAccountId,
  String updatedAt = '2026-09-12T11:30:00.000Z',
}) {
  return {
    'email': email,
    if (providerAccountId != null) 'providerAccountId': providerAccountId,
    'plan': 'plus',
    'primaryWindow': primary,
    'secondaryWindow': secondary,
    'updatedAt': updatedAt,
  };
}

CodexAccountCardData _liveAccount({
  required String id,
  required String providerAccountId,
  required String email,
}) {
  return CodexAccountCardData(
    id: id,
    providerAccountId: providerAccountId,
    email: email,
    displayName: email,
    fiveHour: const CodexQuotaWindow(
      limitWindowSeconds: 18000,
      usedPercent: 20,
      remainingPercent: 80,
      resetAt: null,
    ),
    weekly: const CodexQuotaWindow(
      limitWindowSeconds: 604800,
      usedPercent: 30,
      remainingPercent: 70,
      resetAt: null,
    ),
    updatedAt: DateTime(2026, 9, 13, 10),
    isCurrent: id == 'slot-c',
  );
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
    expect(
      snapshot.accounts[2].statusAt(DateTime(2026, 9, 12, 17)),
      CodexAccountStatus.dataAnomaly,
    );
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

  test('flags contradictory legacy used and remaining percentages', () {
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
    expect(account.hasDataAnomaly, isTrue);
    expect(
      account.statusAt(DateTime(2026, 9, 12, 12)),
      CodexAccountStatus.dataAnomaly,
    );
    expect(account.weekly?.usedPercent, 100);
    expect(account.weekly?.remainingPercent, 23);
  });

  test('derives remaining percentage only when the snapshot omits it', () {
    final snapshot = CodexAccountSnapshot.fromJson({
      'snapshots': {
        'account': {
          'email': 'account@example.com',
          'primaryWindow': {
            'limitWindowSeconds': 18000,
            'usedPercent': 40,
            'resetAt': '2026-09-12T12:00:00.000Z',
          },
          'secondaryWindow': {
            'limitWindowSeconds': 604800,
            'usedPercent': 25,
            'resetAt': '2026-09-19T12:00:00.000Z',
          },
          'updatedAt': '2026-09-12T11:30:00.000Z',
        },
      },
    }, readAt: DateTime(2026, 9, 12, 12));

    final account = snapshot.accounts.single;
    expect(account.hasDataAnomaly, isFalse);
    expect(account.fiveHour?.remainingPercent, 60);
    expect(account.weekly?.remainingPercent, 75);
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

  test('maps live five-hour, weekly, and monthly windows by duration', () {
    final windows = CodexAccountLiveReader.parseUsageWindows({
      'rate_limit': {
        'primary_window': {
          'used_percent': 26,
          'limit_window_seconds': 18000,
          'reset_at': 1789215360,
        },
        'secondary_window': {
          'used_percent': 4,
          'limit_window_seconds': 604800,
          'reset_at': 1789811760,
        },
        'monthly_window': {
          'used_percent': 12,
          'limit_window_seconds': 2592000,
          'reset_at': 1791898560,
        },
      },
    });

    expect(windows[18000]?.remainingPercent, 74);
    expect(windows[604800]?.remainingPercent, 96);
    expect(windows[2592000]?.remainingPercent, 88);

    final arrayWindows = CodexAccountLiveReader.parseUsageWindows({
      'rate_limits': [
        {'used_percent': 10, 'limit_window_seconds': 18000},
        {'used_percent': 20, 'limit_window_seconds': 604800},
        {'used_percent': 30, 'limit_window_seconds': 2592000},
      ],
    });
    expect(arrayWindows[2592000]?.remainingPercent, 70);
  });

  test('maps a monthly window nested in additional rate limits', () {
    final windows = CodexAccountLiveReader.parseUsageWindows({
      'rate_limit': {
        'primary_window': {'used_percent': 15, 'limit_window_seconds': 18000},
        'secondary_window': {'used_percent': 5, 'limit_window_seconds': 604800},
      },
      'additional_rate_limits': [
        {
          'limit_name': 'Monthly quota',
          'rate_limit': {
            'primary_window': {
              'used_percent': '22',
              'limit_window_seconds': 2592000,
            },
          },
        },
      ],
    });

    expect(windows[18000]?.usedPercent, 15);
    expect(windows[604800]?.usedPercent, 5);
    expect(windows[2592000]?.remainingPercent, 78);
  });

  test('maps the official individual monthly credit limit', () {
    final windows = CodexAccountLiveReader.parseUsageWindows({
      'rate_limit': {
        'primary_window': {'used_percent': 15, 'limit_window_seconds': 18000},
        'secondary_window': {'used_percent': 5, 'limit_window_seconds': 604800},
      },
      'individualLimit': {
        'limit': 100,
        'used': 22,
        'remainingPercent': 78,
        'resetsAt': 1791898560,
      },
    });

    expect(windows[2592000]?.usedPercent, 22);
    expect(windows[2592000]?.remainingPercent, 78);
    expect(windows[2592000]?.isConsistent, isTrue);
  });

  test('maps the Codex app-server rate-limit response', () {
    final windows = CodexAccountLiveReader.parseUsageWindows({
      'rateLimits': {
        'primary': {
          'usedPercent': 18,
          'windowDurationMins': 300,
          'resetsAt': 1791898560,
        },
        'secondary': {
          'usedPercent': 7,
          'windowDurationMins': 10080,
          'resetsAt': 1792503360,
        },
        'individualLimit': {
          'limit': '1000',
          'used': '240',
          'remainingPercent': 76,
          'resetsAt': 1794576960,
        },
      },
    });

    expect(windows[18000]?.usedPercent, 18);
    expect(windows[604800]?.usedPercent, 7);
    expect(windows[2592000]?.usedPercent, 24);
    expect(windows[2592000]?.remainingPercent, 76);
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
    expect(
      fallbackResult.snapshot?.accounts.single.displayName,
      'st***@example.com',
    );
  });

  test('keeps all stable slots after a login switch and restores the missing slot',
      () async {
    final temp = await Directory.systemTemp.createTemp(
      'flclash-codex-slot-recovery-',
    );
    final cachePath = '${temp.path}/codex-accounts-cache.json';
    addTearDown(() => temp.delete(recursive: true));

    final historical = jsonEncode({
      'snapshots': {
        'snapshot-a': _account(
          email: 'alpha@example.com',
          providerAccountId: 'slot-a',
          primary: _window(18000, 10, 90),
          secondary: _window(604800, 20, 80),
        ),
        'snapshot-b': _account(
          email: 'beta@example.com',
          providerAccountId: 'slot-b',
          primary: _window(18000, 20, 80),
          secondary: _window(604800, 30, 70),
        ),
        'snapshot-c': _account(
          email: 'gamma@example.com',
          providerAccountId: 'slot-c',
          primary: _window(18000, 30, 70),
          secondary: _window(604800, 40, 60),
        ),
      },
    });
    final liveSnapshot = CodexAccountSnapshot(
      accounts: [
        _liveAccount(
          id: 'slot-a',
          providerAccountId: 'slot-a',
          email: 'alpha@example.com',
        ),
        _liveAccount(
          id: 'slot-b',
          providerAccountId: 'slot-b',
          email: 'beta@example.com',
        ),
        // The third registered home now contains slot-b after switching.
        _liveAccount(
          id: 'slot-c',
          providerAccountId: 'slot-b',
          email: 'beta@example.com',
        ),
      ],
      readAt: DateTime(2026, 9, 13, 10),
      source: CodexSnapshotSource.live,
      currentConfirmed: true,
    );

    final result = await CodexAccountSnapshotReader(
      cachePath: cachePath,
      readText: () async => historical,
      liveReader: () async => CodexSnapshotReadResult(
        snapshot: liveSnapshot,
        failure: null,
        source: CodexSnapshotSource.live,
      ),
    ).read();

    expect(result.snapshot?.accounts.map((account) => account.id), [
      'slot-a',
      'slot-b',
      'slot-c',
    ]);
    final recovered = result.snapshot!.accounts.singleWhere(
      (account) => account.id == 'slot-c',
    );
    expect(recovered.displayName, 'ga***@example.com');
    expect(recovered.weekly?.usedPercent, 40);
    expect(result.missingAccountIds, ['slot-c']);
    expect(result.missingAccountCount, 1);
    expect(result.snapshot?.currentConfirmed, isFalse);

    final cached = jsonDecode(await File(cachePath).readAsString()) as Map;
    expect((cached['accounts'] as List).length, 3);
  });
}
