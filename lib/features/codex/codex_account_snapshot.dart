import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

const codexSnapshotStaleAfter = Duration(hours: 1);

enum CodexAccountStatus { normal, exhausted, expired, dataAnomaly, readFailed }

enum CodexSnapshotReadFailure {
  fileUnavailable,
  invalidJson,
  invalidShape,
  unsupportedPlatform,
  unknown,
}

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
  final DateTime? updatedAt;

  const CodexAccountCardData({
    required this.id,
    required this.providerAccountId,
    required this.email,
    required this.displayName,
    required this.fiveHour,
    required this.weekly,
    required this.updatedAt,
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
    'updatedAt': updatedAt?.toUtc().toIso8601String(),
  };

  factory CodexAccountCardData.fromCacheJson(Map<String, dynamic> json) {
    final id = _readString(json['id']);
    final displayName = _readString(json['displayName']);
    final fiveHour = _parseWindow(json['fiveHour']);
    final weekly = _parseWindow(json['weekly']);
    if (id == null || displayName == null || fiveHour == null || weekly == null) {
      throw const FormatException('cached account entry is invalid');
    }
    return CodexAccountCardData(
      id: id,
      providerAccountId: null,
      email: null,
      displayName: displayName,
      fiveHour: fiveHour,
      weekly: weekly,
      updatedAt: _readDateTime(json['updatedAt']),
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

  const CodexAccountSnapshot({required this.accounts, required this.readAt});

  Map<String, dynamic> toCacheJson() => {
    'version': 1,
    'readAt': readAt.toUtc().toIso8601String(),
    'accounts': accounts.map((account) => account.toCacheJson()).toList(),
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
    return CodexAccountSnapshot(accounts: accounts, readAt: readAt);
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

  const CodexSnapshotReadResult({
    required this.snapshot,
    required this.failure,
    this.fromCache = false,
  });
}

class CodexAccountSnapshotReader {
  final Future<String> Function()? readText;
  final String? snapshotPath;
  final String? cachePath;
  final DateTime Function() _clock;

  CodexAccountSnapshotReader({
    this.readText,
    this.snapshotPath,
    this.cachePath,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  Future<CodexSnapshotReadResult> read() async {
    final readAt = _clock();
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
        return CodexSnapshotReadResult(snapshot: snapshot, failure: null);
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
    );
  }

  String? get _resolvedCachePath {
    if (cachePath != null) {
      return cachePath;
    }
    final appData = Platform.environment['APPDATA'];
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
  return CodexQuotaWindow(
    limitWindowSeconds: _readInt(window['limitWindowSeconds']),
    usedPercent: _readDouble(window['usedPercent']),
    remainingPercent: _readDouble(window['remainingPercent']),
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
