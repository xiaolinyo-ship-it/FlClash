import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'codex_account_live.dart';

const codexSnapshotStaleAfter = Duration(hours: 1);

enum CodexAccountStatus { normal, exhausted, expired, dataAnomaly, readFailed }

enum CodexSnapshotReadFailure {
  fileUnavailable,
  invalidJson,
  invalidShape,
  unsupportedPlatform,
  unknown,
}

enum CodexSnapshotSource { live, codexBarSnapshot, cache }

class CodexQuotaWindow {
  final int? limitWindowSeconds;
  final double? usedPercent;
  final double? remainingPercent;
  final DateTime? resetAt;

  const CodexQuotaWindow({
    required this.limitWindowSeconds,
    required this.usedPercent,
    required this.remainingPercent,
    required this.resetAt,
  });

  bool get isConsistent {
    final used = usedPercent;
    final remaining = remainingPercent;
    if (used == null || remaining == null || resetAt == null) {
      return false;
    }
    if (used < 0 || used > 100 || remaining < 0 || remaining > 100) {
      return false;
    }
    return (used + remaining - 100).abs() <= 0.01;
  }

  bool get isExhausted =>
      isConsistent && (usedPercent! >= 100 || remainingPercent! <= 0);

  Map<String, dynamic> toCacheJson() => {
    'limitWindowSeconds': limitWindowSeconds,
    'usedPercent': usedPercent,
    'remainingPercent': remainingPercent,
    'resetAt': resetAt?.toUtc().toIso8601String(),
  };
}

class CodexAccountCardData {
  final String id;
  final String? providerAccountId;
  final String? email;
  final String displayName;
  final CodexQuotaWindow? fiveHour;
  final CodexQuotaWindow? weekly;
  final CodexQuotaWindow? monthly;
  final DateTime? updatedAt;
  final bool isCurrent;

  const CodexAccountCardData({
    required this.id,
    required this.providerAccountId,
    required this.email,
    required this.displayName,
    required this.fiveHour,
    required this.weekly,
    this.monthly,
    required this.updatedAt,
    this.isCurrent = false,
  });

  bool get hasDataAnomaly =>
      fiveHour == null ||
      weekly == null ||
      !fiveHour!.isConsistent ||
      !weekly!.isConsistent;

  Map<String, dynamic> toCacheJson() => {
    'id': id,
    'displayName': displayName,
    'fiveHour': fiveHour?.toCacheJson(),
    'weekly': weekly?.toCacheJson(),
    'monthly': monthly?.toCacheJson(),
    'updatedAt': updatedAt?.toUtc().toIso8601String(),
    'isCurrent': isCurrent,
  };

  factory CodexAccountCardData.fromCacheJson(Map<String, dynamic> json) {
    final id = _readString(json['id']);
    final displayName = _readString(json['displayName']);
    final fiveHour = _parseWindow(json['fiveHour']);
    final weekly = _parseWindow(json['weekly']);
    final monthly = _parseWindow(json['monthly']);
    if (id == null || displayName == null) {
      throw const FormatException('cached account entry is invalid');
    }
    return CodexAccountCardData(
      id: id,
      providerAccountId: null,
      email: null,
      displayName: displayName,
      fiveHour: fiveHour,
      weekly: weekly,
      monthly: monthly,
      updatedAt: _readDateTime(json['updatedAt']),
      isCurrent: json['isCurrent'] == true,
    );
  }

  CodexAccountStatus statusAt(DateTime now) {
    if (hasDataAnomaly) {
      return CodexAccountStatus.dataAnomaly;
    }
    if (fiveHour!.isExhausted || weekly!.isExhausted) {
      return CodexAccountStatus.exhausted;
    }
    final updated = updatedAt;
    if (updated == null || now.isAfter(updated.add(codexSnapshotStaleAfter))) {
      return CodexAccountStatus.expired;
    }
    return CodexAccountStatus.normal;
  }
}

class CodexAccountSnapshot {
  final List<CodexAccountCardData> accounts;
  final DateTime readAt;
  final CodexSnapshotSource source;
  final bool currentConfirmed;

  const CodexAccountSnapshot({
    required this.accounts,
    required this.readAt,
    this.source = CodexSnapshotSource.codexBarSnapshot,
    this.currentConfirmed = false,
  });

  Map<String, dynamic> toCacheJson() => {
    'version': 1,
    'readAt': readAt.toUtc().toIso8601String(),
    'accounts': accounts.map((account) => account.toCacheJson()).toList(),
    'currentConfirmed': currentConfirmed,
  };

  factory CodexAccountSnapshot.fromCacheJson(Map<String, dynamic> json) {
    final readAt = _readDateTime(json['readAt']);
    final accountsValue = json['accounts'];
    if (readAt == null || accountsValue is! List) {
      throw const FormatException('cached snapshot is invalid');
    }
    final accounts = accountsValue.map((value) {
      if (value is! Map) {
        throw const FormatException('cached account entry is invalid');
      }
      return CodexAccountCardData.fromCacheJson(
        Map<String, dynamic>.from(value),
      );
    }).toList();
    accounts.sort((left, right) => left.id.compareTo(right.id));
    return CodexAccountSnapshot(
      accounts: accounts,
      readAt: readAt,
      source: CodexSnapshotSource.cache,
      currentConfirmed: json['currentConfirmed'] == true,
    );
  }

  factory CodexAccountSnapshot.fromJson(
    Map<String, dynamic> json, {
    required DateTime readAt,
  }) {
    final snapshotsValue = json['snapshots'];
    if (snapshotsValue is! Map) {
      throw const FormatException('snapshots must be an object');
    }

    final accounts = <CodexAccountCardData>[];
    for (final entry in snapshotsValue.entries) {
      if (entry.key is! String || entry.value is! Map) {
        throw const FormatException('snapshot entry is invalid');
      }
      final id = entry.key as String;
      final value = Map<String, dynamic>.from(entry.value as Map);
      final windows = [
        _parseWindow(value['primaryWindow']),
        _parseWindow(value['secondaryWindow']),
        _parseWindow(value['monthlyWindow']),
      ].whereType<CodexQuotaWindow>().toList();
      final email = _readString(value['email']);
      accounts.add(
        CodexAccountCardData(
          id: id,
          providerAccountId: _readString(value['providerAccountId']),
          email: email,
          displayName: _displayName(id, email),
          fiveHour: _findWindow(windows, 18000),
          weekly: _findWindow(windows, 604800),
          monthly: _findWindow(windows, 2592000),
          updatedAt: _readDateTime(value['updatedAt']),
        ),
      );
    }
    accounts.sort((left, right) => left.id.compareTo(right.id));
    return CodexAccountSnapshot(accounts: accounts, readAt: readAt);
  }

  static CodexQuotaWindow? _findWindow(
    List<CodexQuotaWindow> windows,
    int durationSeconds,
  ) {
    for (final window in windows) {
      if (window.limitWindowSeconds == durationSeconds) {
        return window;
      }
    }
    return null;
  }
}

class CodexSnapshotReadResult {
  final CodexAccountSnapshot? snapshot;
  final CodexSnapshotReadFailure? failure;
  final bool fromCache;
  final int missingAccountCount;
  final List<String> missingAccountIds;
  final CodexSnapshotSource source;

  const CodexSnapshotReadResult({
    required this.snapshot,
    required this.failure,
    this.fromCache = false,
    this.missingAccountCount = 0,
    this.missingAccountIds = const [],
    this.source = CodexSnapshotSource.codexBarSnapshot,
  });
}

class CodexAccountSnapshotReader {
  final Future<String> Function()? readText;
  final String? snapshotPath;
  final String? cachePath;
  final DateTime Function() _clock;
  final Future<CodexSnapshotReadResult> Function()? liveReader;

  CodexAccountSnapshotReader({
    this.readText,
    this.snapshotPath,
    this.cachePath,
    this.liveReader,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  Future<CodexSnapshotReadResult> read() async {
    final readAt = _clock();
    if (liveReader != null ||
        (readText == null && snapshotPath == null && Platform.isWindows)) {
      try {
        final liveProbe = liveReader != null
            ? await liveReader!()
            : await CodexAccountLiveReader(clock: _clock).read();
        if (liveProbe.snapshot != null) {
          final completed = await _completeLiveResult(liveProbe);
          await _writeCache(completed.snapshot!);
          return completed;
        }
      } catch (_) {
        // The snapshot and cache paths below keep the dashboard available.
      }
    }
    CodexSnapshotReadResult liveResult;
    try {
      final raw = await _readRaw();
      dynamic decoded;
      try {
        decoded = jsonDecode(raw);
      } on FormatException {
        liveResult = const CodexSnapshotReadResult(
          snapshot: null,
          failure: CodexSnapshotReadFailure.invalidJson,
        );
        return await _withCacheFallback(liveResult);
      }
      if (decoded is! Map) {
        liveResult = const CodexSnapshotReadResult(
          snapshot: null,
          failure: CodexSnapshotReadFailure.invalidShape,
        );
        return await _withCacheFallback(liveResult);
      }
      try {
        final snapshot = CodexAccountSnapshot.fromJson(
          Map<String, dynamic>.from(decoded),
          readAt: readAt,
        );
        await _writeCache(snapshot);
        return CodexSnapshotReadResult(
          snapshot: CodexAccountSnapshot(
            accounts: snapshot.accounts,
            readAt: snapshot.readAt,
            source: CodexSnapshotSource.codexBarSnapshot,
            currentConfirmed: snapshot.currentConfirmed,
          ),
          failure: null,
        );
      } on FormatException {
        liveResult = const CodexSnapshotReadResult(
          snapshot: null,
          failure: CodexSnapshotReadFailure.invalidShape,
        );
        return await _withCacheFallback(liveResult);
      }
    } on FileSystemException {
      liveResult = const CodexSnapshotReadResult(
        snapshot: null,
        failure: CodexSnapshotReadFailure.fileUnavailable,
      );
      return await _withCacheFallback(liveResult);
    } on UnsupportedError {
      liveResult = const CodexSnapshotReadResult(
        snapshot: null,
        failure: CodexSnapshotReadFailure.unsupportedPlatform,
      );
      return await _withCacheFallback(liveResult);
    } catch (_) {
      liveResult = const CodexSnapshotReadResult(
        snapshot: null,
        failure: CodexSnapshotReadFailure.unknown,
      );
      return await _withCacheFallback(liveResult);
    }
  }

  /// Keeps registered account slots visible when a login switch temporarily
  /// changes the provider identity stored in one Codex home. Such a card is
  /// explicitly marked as missing live data by the dashboard; it is never
  /// presented as a fresh reading.
  Future<CodexSnapshotReadResult> _completeLiveResult(
    CodexSnapshotReadResult liveResult,
  ) async {
    final liveSnapshot = liveResult.snapshot!;
    final liveAccounts = liveSnapshot.accounts;
    final providerCounts = <String, int>{};
    for (final account in liveAccounts) {
      final providerId = account.providerAccountId?.toLowerCase();
      if (providerId != null) {
        providerCounts[providerId] = (providerCounts[providerId] ?? 0) + 1;
      }
    }
    final hasProviderCollision = providerCounts.values.any(
      (count) => count > 1,
    );
    final hasIdentityChange = liveAccounts.any((account) {
      final providerId = account.providerAccountId?.toLowerCase();
      return providerId != null && providerId != account.id.toLowerCase();
    });
    final needsRecovery =
        liveResult.missingAccountCount > 0 ||
        hasProviderCollision ||
        hasIdentityChange;

    CodexAccountSnapshot? historical;
    if (needsRecovery) {
      historical = await _readHistoricalSnapshot();
    }
    final historicalByProvider = <String, CodexAccountCardData>{};
    if (historical != null) {
      for (final account in historical.accounts) {
        final providerId = account.providerAccountId?.toLowerCase();
        if (providerId != null) {
          historicalByProvider[providerId] = account;
        }
      }
    }

    final accountsById = <String, CodexAccountCardData>{};
    final missingAccountIds = <String>{...liveResult.missingAccountIds};
    var usedHistoricalData = false;
    for (final account in liveAccounts) {
      final providerId = account.providerAccountId?.toLowerCase();
      final identityChanged =
          providerId != null && providerId != account.id.toLowerCase();
      final historicalAccount = historicalByProvider[account.id.toLowerCase()];
      if (identityChanged && historicalAccount != null) {
        accountsById[account.id] = _copyAccount(
          historicalAccount,
          id: account.id,
          isCurrent: false,
        );
        missingAccountIds.add(account.id);
        usedHistoricalData = true;
      } else {
        accountsById[account.id] = account;
      }
    }

    // Restore a slot that had no usable live quota response from the last
    // CodexBar snapshot. Cache is considered after the producer snapshot so
    // an available historical account identity can recover an old cache that
    // was previously overwritten by a partial live read.
    if (needsRecovery && historical != null) {
      for (final account in historical.accounts) {
        final providerId = account.providerAccountId;
        if (providerId == null || accountsById.containsKey(providerId)) {
          continue;
        }
        accountsById[providerId] = _copyAccount(
          account,
          id: providerId,
          isCurrent: false,
        );
        missingAccountIds.add(providerId);
        usedHistoricalData = true;
      }
    }

    if (needsRecovery) {
      final cached = await _readCache();
      if (cached != null) {
        for (final account in cached.accounts) {
          if (accountsById.containsKey(account.id)) {
            continue;
          }
          accountsById[account.id] = account;
          missingAccountIds.add(account.id);
        }
      }
    }

    final accounts = accountsById.values.toList()
      ..sort((left, right) => left.id.compareTo(right.id));
    final missingCount =
        liveResult.missingAccountCount > missingAccountIds.length
        ? liveResult.missingAccountCount
        : missingAccountIds.length;
    return CodexSnapshotReadResult(
      snapshot: CodexAccountSnapshot(
        accounts: accounts,
        readAt: liveSnapshot.readAt,
        source: liveSnapshot.source,
        currentConfirmed: liveSnapshot.currentConfirmed && !usedHistoricalData,
      ),
      failure: liveResult.failure,
      fromCache: liveResult.fromCache || usedHistoricalData,
      missingAccountCount: missingCount,
      missingAccountIds: missingAccountIds.toList()..sort(),
      source: liveResult.source,
    );
  }

  Future<CodexAccountSnapshot?> _readHistoricalSnapshot() async {
    try {
      final raw = await _readRaw();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return null;
      }
      return CodexAccountSnapshot.fromJson(
        Map<String, dynamic>.from(decoded),
        readAt: _clock(),
      );
    } catch (_) {
      // A missing, busy, or malformed CodexBar file must not affect FlClash.
      return null;
    }
  }

  Future<CodexSnapshotReadResult> _withCacheFallback(
    CodexSnapshotReadResult liveResult,
  ) async {
    final cached = await _readCache();
    if (cached == null) {
      return liveResult;
    }
    return CodexSnapshotReadResult(
      snapshot: cached,
      failure: liveResult.failure,
      fromCache: true,
      missingAccountCount: liveResult.missingAccountCount,
      missingAccountIds: liveResult.missingAccountIds,
    );
  }

  String? get _resolvedCachePath {
    if (cachePath != null) {
      return cachePath;
    }
    final smokeDataDir = const bool.fromEnvironment('FLCLASH_CODEX_GUI_SMOKE')
        ? Platform.environment['FLCLASH_CODEX_GUI_SMOKE_DATA_DIR']
        : null;
    final appData = smokeDataDir?.isNotEmpty == true
        ? smokeDataDir
        : Platform.environment['APPDATA'];
    if (!Platform.isWindows || appData == null || appData.isEmpty) {
      return null;
    }
    return path.join(appData, 'FlClash', 'codex-accounts-cache.json');
  }

  Future<void> _writeCache(CodexAccountSnapshot snapshot) async {
    final resolvedPath = _resolvedCachePath;
    if (resolvedPath == null) {
      return;
    }
    try {
      final file = File(resolvedPath);
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(snapshot.toCacheJson()), flush: true);
    } catch (_) {
      // Cache persistence is best effort and must not affect live display.
    }
  }

  Future<CodexAccountSnapshot?> _readCache() async {
    final resolvedPath = _resolvedCachePath;
    if (resolvedPath == null) {
      return null;
    }
    try {
      final file = File(resolvedPath);
      if (!await file.exists()) {
        return null;
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        return null;
      }
      return CodexAccountSnapshot.fromCacheJson(
        Map<String, dynamic>.from(decoded),
      );
    } catch (_) {
      return null;
    }
  }

  Future<String> _readRaw() async {
    final customReader = readText;
    if (customReader != null) {
      return customReader();
    }
    if (!Platform.isWindows && snapshotPath == null) {
      throw UnsupportedError('CodexBar snapshot is Windows-only');
    }
    final appData = Platform.environment['APPDATA'];
    if (snapshotPath == null && (appData == null || appData.isEmpty)) {
      throw const FileSystemException('APPDATA is unavailable');
    }
    final resolvedPath =
        snapshotPath ??
        path.join(appData!, 'CodexBar', 'codex-accounts', 'snapshots.json');
    return File(resolvedPath).readAsString();
  }
}

CodexQuotaWindow? _parseWindow(dynamic value) {
  if (value is! Map) {
    return null;
  }
  final window = Map<String, dynamic>.from(value);
  final usedPercent = _readDouble(window['usedPercent']);
  final storedRemainingPercent = _readDouble(window['remainingPercent']);
  return CodexQuotaWindow(
    limitWindowSeconds: _readInt(window['limitWindowSeconds']),
    usedPercent: usedPercent,
    // If both values are present, preserve them so CodexQuotaWindow can flag
    // contradictory legacy snapshots (for example 100 used / 23 remaining).
    // Only synthesize the complement when the producer omitted remainingPercent.
    remainingPercent:
        storedRemainingPercent ??
        (usedPercent == null
            ? null
            : (100 - usedPercent).clamp(0, 100).toDouble()),
    resetAt: _readDateTime(window['resetAt']),
  );
}

String? _readString(dynamic value) {
  if (value is! String || value.trim().isEmpty) {
    return null;
  }
  return value.trim();
}

int? _readInt(dynamic value) => value is num ? value.toInt() : null;

double? _readDouble(dynamic value) {
  final number = value is num ? value.toDouble() : null;
  return number != null && number.isFinite ? number : null;
}

DateTime? _readDateTime(dynamic value) {
  final raw = _readString(value);
  return raw == null ? null : DateTime.tryParse(raw)?.toLocal();
}

String _displayName(String id, String? email) {
  if (email == null) {
    final length = id.length > 8 ? 8 : id.length;
    return '账户 ${id.substring(0, length)}';
  }
  final at = email.lastIndexOf('@');
  if (at <= 0 || at == email.length - 1) {
    return email;
  }
  final local = email.substring(0, at);
  final prefix = local.substring(0, local.length.clamp(0, 2));
  return '$prefix***${email.substring(at)}';
}

CodexAccountCardData _copyAccount(
  CodexAccountCardData account, {
  required String id,
  required bool isCurrent,
}) {
  return CodexAccountCardData(
    id: id,
    providerAccountId: account.providerAccountId,
    email: account.email,
    displayName: account.displayName,
    fiveHour: account.fiveHour,
    weekly: account.weekly,
    monthly: account.monthly,
    updatedAt: account.updatedAt,
    isCurrent: isCurrent,
  );
}
