import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

const codexSnapshotStaleAfter = Duration(hours: 1);

enum CodexAccountStatus {
  normal,
  exhausted,
  expired,
  dataAnomaly,
  readFailed,
}

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

  bool get isExhausted {
    if (!isConsistent) {
      return false;
    }
    return usedPercent! >= 100 || remainingPercent! <= 0;
  }
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

  bool get hasDataAnomaly {
    return fiveHour == null ||
        weekly == null ||
        !fiveHour!.isConsistent ||
        !weekly!.isConsistent;
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
      accounts.add(
        CodexAccountCardData(
          id: id,
          providerAccountId: _readString(value['providerAccountId']),
          email: _readString(value['email']),
          displayName: _displayName(
            id,
            _readString(value['email']),
          ),
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

  const CodexSnapshotReadResult({required this.snapshot, required this.failure});
}

class CodexAccountSnapshotReader {
  final Future<String> Function()? readText;
  final String? snapshotPath;
  final DateTime Function() _clock;

  CodexAccountSnapshotReader({
    this.readText,
    this.snapshotPath,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  Future<CodexSnapshotReadResult> read() async {
    final readAt = _clock();
    try {
      final raw = await _readRaw();
      dynamic decoded;
      try {
        decoded = jsonDecode(raw);
      } on FormatException {
        return const CodexSnapshotReadResult(
          snapshot: null,
          failure: CodexSnapshotReadFailure.invalidJson,
        );
      }
      if (decoded is! Map) {
        return const CodexSnapshotReadResult(
          snapshot: null,
          failure: CodexSnapshotReadFailure.invalidShape,
        );
      }
      late final CodexAccountSnapshot snapshot;
      try {
        snapshot = CodexAccountSnapshot.fromJson(
          Map<String, dynamic>.from(decoded),
          readAt: readAt,
        );
      } on FormatException {
        return const CodexSnapshotReadResult(
          snapshot: null,
          failure: CodexSnapshotReadFailure.invalidShape,
        );
      }
      return CodexSnapshotReadResult(snapshot: snapshot, failure: null);
    } on FileSystemException {
      return const CodexSnapshotReadResult(
        snapshot: null,
        failure: CodexSnapshotReadFailure.fileUnavailable,
      );
    } on UnsupportedError {
      return const CodexSnapshotReadResult(
        snapshot: null,
        failure: CodexSnapshotReadFailure.unsupportedPlatform,
      );
    } catch (_) {
      return const CodexSnapshotReadResult(
        snapshot: null,
        failure: CodexSnapshotReadFailure.unknown,
      );
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
    final resolvedPath = snapshotPath ??
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

int? _readInt(dynamic value) {
  return value is num ? value.toInt() : null;
}

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
