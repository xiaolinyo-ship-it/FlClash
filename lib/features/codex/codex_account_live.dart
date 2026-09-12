import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as path;

import 'codex_account_snapshot.dart';

const _codexRefreshEndpoint = 'https://auth.openai.com/oauth/token';
const _codexRefreshClientId = 'app_EMoamEEZ73f0CkXaXp7hrann';
const _codexUsageBase = 'https://chatgpt.com/backend-api';

/// Reads existing Codex homes directly. It does not read accounts.json and it
/// never exposes credentials to the UI or to cache files.
class CodexAccountLiveReader {
  final Dio _client;
  final String? supportPath;
  final String? ambientHomePath;
  final String? registryPath;
  final DateTime Function() _clock;

  CodexAccountLiveReader({
    Dio? client,
    this.supportPath,
    this.ambientHomePath,
    this.registryPath,
    DateTime Function()? clock,
  }) : _client = client ?? Dio(),
       _clock = clock ?? DateTime.now;

  Future<CodexSnapshotReadResult> read() async {
    if (!Platform.isWindows && supportPath == null && ambientHomePath == null) {
      return const CodexSnapshotReadResult(
        snapshot: null,
        failure: CodexSnapshotReadFailure.unsupportedPlatform,
      );
    }

    final registeredHomes = await _readRegistry();
    final homes = await _discoverHomes(registeredHomes);
    if (homes.isEmpty) {
      return const CodexSnapshotReadResult(
        snapshot: null,
        failure: CodexSnapshotReadFailure.fileUnavailable,
      );
    }

    var records = <_CodexAuthRecord>[];
    final byIdentity = <String, _CodexAuthRecord>{};
    for (final home in homes) {
      final record = await _readAuth(home);
      if (record == null || record.accessToken == null) {
        continue;
      }
      final key = record.providerAccountId ?? record.email ?? home.path;
      final previous = byIdentity[key.toLowerCase()];
      if (previous == null || (!previous.isAmbient && record.isAmbient)) {
        byIdentity[key.toLowerCase()] = record;
      }
    }
    records.addAll(byIdentity.values);
    if (registeredHomes != null && records.length < registeredHomes.length) {
      return const CodexSnapshotReadResult(
        snapshot: null,
        failure: CodexSnapshotReadFailure.fileUnavailable,
      );
    }
    if (registeredHomes == null) {
      final allowlist = await _readSnapshotAllowlist();
      if (allowlist.isNotEmpty) {
        final matched = records
            .where(
              (record) => allowlist.any(
                (identity) => identity.contains(record.identityKey),
              ),
            )
            .toList();
        if (matched.length < allowlist.length) {
          return const CodexSnapshotReadResult(
            snapshot: null,
            failure: CodexSnapshotReadFailure.invalidShape,
          );
        }
        records = matched;
      }
    }
    records.sort((left, right) => left.stableId.compareTo(right.stableId));
    if (records.isEmpty) {
      return const CodexSnapshotReadResult(
        snapshot: null,
        failure: CodexSnapshotReadFailure.invalidShape,
      );
    }

    final accounts = <CodexAccountCardData>[];
    for (final record in records) {
      final account = await _readAccount(record);
      if (account == null) {
        return const CodexSnapshotReadResult(
          snapshot: null,
          failure: CodexSnapshotReadFailure.unknown,
        );
      }
      accounts.add(account);
    }

    final current = accounts.where((account) => account.isCurrent).toList();
    await _writeRegistry(records);
    return CodexSnapshotReadResult(
      snapshot: CodexAccountSnapshot(
        accounts: accounts,
        readAt: _clock(),
        source: CodexSnapshotSource.live,
        currentConfirmed: current.length == 1,
      ),
      failure: null,
      source: CodexSnapshotSource.live,
    );
  }

  Future<List<Directory>> _discoverHomes(List<String>? registeredHomes) async {
    final result = <Directory>[];
    final seen = <String>{};
    final add = (String? rawPath) {
      if (rawPath == null || rawPath.trim().isEmpty) {
        return;
      }
      final normalized = path.normalize(rawPath);
      final key = normalized.toLowerCase();
      if (seen.add(key)) {
        result.add(Directory(normalized));
      }
    };

    if (registeredHomes != null) {
      for (final home in registeredHomes) {
        add(home);
      }
    } else {
      add(ambientHomePath ?? _defaultAmbientHome());
    }
    final support = supportPath ?? _defaultSupportPath();
    if (support != null) {
      final managed = Directory(path.join(support, 'managed-homes'));
      try {
        await for (final entry in managed.list(followLinks: false)) {
          if (entry is Directory &&
              (registeredHomes == null ||
                  registeredHomes.any((home) => _samePath(home, entry.path)))) {
            add(entry.path);
          }
        }
      } on FileSystemException {
        // Missing managed homes are handled by the caller as a read failure.
      }
    }
    return result;
  }

  Future<List<String>?> _readRegistry() async {
    final file = _registryFile;
    if (file == null || !await file.exists()) {
      return null;
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['accounts'] is! List) {
        return null;
      }
      final homes = <String>[];
      for (final item in decoded['accounts'] as List) {
        if (item is Map) {
          final home = _string(item['home']);
          if (home != null) {
            homes.add(home);
          }
        }
      }
      return homes.isEmpty ? null : homes;
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  Future<List<Set<String>>> _readSnapshotAllowlist() async {
    final support = supportPath ?? _defaultSupportPath();
    if (support == null) {
      return [];
    }
    try {
      final decoded = jsonDecode(
        await File(path.join(support, 'snapshots.json')).readAsString(),
      );
      final snapshots = decoded is Map ? decoded['snapshots'] : null;
      if (snapshots is! Map) {
        return [];
      }
      final identities = <Set<String>>[];
      for (final entry in snapshots.entries) {
        final accountIdentities = <String>{};
        final id = _string(entry.key);
        if (id != null) {
          accountIdentities.add(id.toLowerCase());
        }
        if (entry.value is Map) {
          final email = _string((entry.value as Map)['email']);
          if (email != null) {
            accountIdentities.add(email.toLowerCase());
          }
        }
        if (accountIdentities.isNotEmpty) {
          identities.add(accountIdentities);
        }
      }
      return identities;
    } on FormatException {
      return [];
    } on FileSystemException {
      return [];
    }
  }

  Future<void> _writeRegistry(List<_CodexAuthRecord> records) async {
    final file = _registryFile;
    if (file == null) {
      return;
    }
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({
          'version': 1,
          'accounts': records
              .map((record) => {
                    'id': record.stableId,
                    'home': record.home.path,
                  })
              .toList(),
        }),
        flush: true,
      );
    } on FileSystemException {
      // Registry persistence is best effort; it contains no credentials.
    }
  }

  File? get _registryFile {
    if (registryPath != null && registryPath!.isNotEmpty) {
      return File(registryPath!);
    }
    final appData = Platform.environment['APPDATA'];
    if (appData == null || appData.isEmpty) {
      return null;
    }
    return File(path.join(appData, 'FlClash', 'codex-accounts-registry.json'));
  }

  Future<_CodexAuthRecord?> _readAuth(Directory home) async {
    final file = File(path.join(home.path, 'auth.json'));
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) {
        return null;
      }
      final document = Map<String, dynamic>.from(decoded);
      final tokens = document['tokens'];
      final tokenMap = tokens is Map
          ? Map<String, dynamic>.from(tokens)
          : const <String, dynamic>{};
      final accessToken = _string(tokenMap['access_token']);
      final refreshToken = _string(tokenMap['refresh_token']);
      final idToken = _string(tokenMap['id_token']);
      final providerAccountId =
          _string(tokenMap['account_id']) ?? _jwtString(idToken, [
            'https://api.openai.com/auth.chatgpt_account_id',
            'chatgpt_account_id',
          ]);
      final email = _string(document['email']) ??
          _jwtString(idToken, ['email']) ??
          _jwtString(idToken, ['https://api.openai.com/profile.email']);
      return _CodexAuthRecord(
        home: home,
        document: document,
        accessToken: accessToken,
        refreshToken: refreshToken,
        idToken: idToken,
        email: email,
        providerAccountId: providerAccountId,
        isAmbient: _samePath(home.path, ambientHomePath ?? _defaultAmbientHome()),
      );
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  Future<CodexAccountCardData?> _readAccount(_CodexAuthRecord record) async {
    final response = await _requestUsage(record);
    if (response == null) {
      return null;
    }
    final windows = _extractWindows(response);
    final fiveHour = _windowFor(windows, 18000);
    final weekly = _windowFor(windows, 604800);
    if (fiveHour == null || weekly == null) {
      return null;
    }
    final accountId = record.stableId;
    return CodexAccountCardData(
      id: accountId,
      providerAccountId: record.providerAccountId,
      email: record.email,
      displayName: _displayName(accountId, record.email),
      fiveHour: fiveHour,
      weekly: weekly,
      monthly: _windowFor(windows, 2592000),
      updatedAt: _clock(),
      isCurrent: record.isAmbient,
    );
  }

  Future<Map<String, dynamic>?> _requestUsage(_CodexAuthRecord record) async {
    var current = record;
    var response = await _getUsage(current);
    if (_isUnauthorized(response) && current.refreshToken != null) {
      final refreshed = await _refresh(current);
      if (refreshed == null) {
        return null;
      }
      current = refreshed;
      response = await _getUsage(current);
    }
    if (response == null || response.statusCode != 200 || response.data is! Map) {
      return null;
    }
    return Map<String, dynamic>.from(response.data as Map);
  }

  Future<Response<dynamic>?> _getUsage(_CodexAuthRecord record) async {
    final token = record.accessToken;
    if (token == null) {
      return null;
    }
    try {
      return await _client.get<dynamic>(
        _usageUrl(record.home),
        options: Options(
          validateStatus: (_) => true,
          headers: {
            'Authorization': 'Bearer $token',
            'User-Agent': 'codex-cli',
            'Accept': 'application/json',
            'Cache-Control': 'no-cache, no-store, max-age=0',
            'Pragma': 'no-cache',
            if (record.providerAccountId != null)
              'ChatGPT-Account-Id': record.providerAccountId!,
          },
        ),
      );
    } on DioException {
      return null;
    }
  }

  Future<_CodexAuthRecord?> _refresh(_CodexAuthRecord record) async {
    final refreshToken = record.refreshToken;
    if (refreshToken == null) {
      return null;
    }
    try {
      final response = await _client.post<dynamic>(
        _codexRefreshEndpoint,
        data: {
          'client_id': _codexRefreshClientId,
          'grant_type': 'refresh_token',
          'refresh_token': refreshToken,
          'scope': 'openid profile email',
        },
        options: Options(validateStatus: (_) => true),
      );
      if (response.statusCode != 200 || response.data is! Map) {
        return null;
      }
      final payload = Map<String, dynamic>.from(response.data as Map);
      final accessToken = _string(payload['access_token']);
      if (accessToken == null) {
        return null;
      }
      final nextDocument = Map<String, dynamic>.from(record.document);
      final nextTokens = record.document['tokens'] is Map
          ? Map<String, dynamic>.from(record.document['tokens'] as Map)
          : <String, dynamic>{};
      nextTokens['access_token'] = accessToken;
      nextTokens['refresh_token'] =
          _string(payload['refresh_token']) ?? refreshToken;
      final idToken = _string(payload['id_token']) ?? record.idToken;
      if (idToken != null) {
        nextTokens['id_token'] = idToken;
      }
      if (record.providerAccountId != null) {
        nextTokens['account_id'] = record.providerAccountId;
      }
      nextDocument['tokens'] = nextTokens;
      nextDocument['last_refresh'] = _clock().toUtc().toIso8601String();
      await _writeAuth(record.home, nextDocument);
      return _CodexAuthRecord(
        home: record.home,
        document: nextDocument,
        accessToken: accessToken,
        refreshToken: nextTokens['refresh_token'] as String?,
        idToken: idToken,
        email: record.email ?? _jwtString(idToken, ['email']),
        providerAccountId: record.providerAccountId,
        isAmbient: record.isAmbient,
      );
    } on DioException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  Future<void> _writeAuth(Directory home, Map<String, dynamic> document) async {
    // The refreshed session stays in the original Codex home. No copy is made
    // and the credential contents never enter the dashboard cache or logs.
    final file = File(path.join(home.path, 'auth.json'));
    await file.writeAsString(jsonEncode(document), flush: true);
  }

  static Map<int, CodexQuotaWindow> parseUsageWindows(
    Map<String, dynamic> payload,
  ) {
    final windows = <int, CodexQuotaWindow>{};
    void addWindow(dynamic value, int? hint) {
      if (value is Map) {
        final window = _parseLiveWindow(
          Map<String, dynamic>.from(value),
          hint,
        );
        if (window != null && window.limitWindowSeconds != null) {
          windows[window.limitWindowSeconds!] = window;
        }
      }
    }
    final rateLimit = payload['rate_limit'] ?? payload['rateLimit'];
    if (rateLimit is Map) {
      final rate = Map<String, dynamic>.from(rateLimit);
      for (final entry in rate.entries) {
        final key = entry.key.toString().toLowerCase();
        if (entry.value is List) {
          for (final item in entry.value as List) {
            addWindow(item, _durationHint(key));
          }
        } else {
          addWindow(entry.value, _durationHint(key));
        }
      }
    }
    final rateLimits = payload['rate_limits'] ?? payload['rateLimits'];
    if (rateLimits is List) {
      for (final item in rateLimits) {
        addWindow(item, null);
      }
    }
    return windows;
  }

  static List<CodexQuotaWindow> _extractWindows(Map<String, dynamic> payload) {
    return parseUsageWindows(payload).values.toList();
  }

  static CodexQuotaWindow? _windowFor(
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

  static CodexQuotaWindow? _parseLiveWindow(
    Map<String, dynamic> value,
    int? hintedDuration,
  ) {
    final used = _number(value['used_percent'] ?? value['usedPercent']);
    final duration = _int(value['limit_window_seconds']) ??
        _int(value['limitWindowSeconds']) ??
        hintedDuration;
    if (used == null || duration == null) {
      return null;
    }
    return CodexQuotaWindow(
      limitWindowSeconds: duration,
      usedPercent: used.clamp(0, 100).toDouble(),
      remainingPercent: (100 - used).clamp(0, 100).toDouble(),
      resetAt: _date(value['reset_at'] ?? value['resetAt']),
    );
  }

  static int? _durationHint(String key) {
    if (key.contains('primary') || key.contains('session') || key.contains('five')) {
      return 18000;
    }
    if (key.contains('secondary') || key.contains('week')) {
      return 604800;
    }
    if (key.contains('month')) {
      return 2592000;
    }
    return null;
  }

  String _usageUrl(Directory home) {
    final config = File(path.join(home.path, 'config.toml'));
    var base = _codexUsageBase;
    try {
      for (final rawLine in config.readAsLinesSync()) {
        final line = rawLine.split('#').first.trim();
        if (!line.startsWith('chatgpt_base_url')) {
          continue;
        }
        final separator = line.indexOf('=');
        if (separator < 0) {
          continue;
        }
        final value = line.substring(separator + 1).trim();
        if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
          base = value.substring(1, value.length - 1);
        }
      }
    } on FileSystemException {
      // Use the public default endpoint.
    }
    base = base.replaceFirst(RegExp(r'/+$'), '');
    if ((base.startsWith('https://chatgpt.com') ||
            base.startsWith('https://chat.openai.com')) &&
        !base.contains('/backend-api')) {
      base = '$base/backend-api';
    }
    return base.contains('/backend-api')
        ? '$base/wham/usage'
        : '$base/api/codex/usage';
  }

  String? _defaultSupportPath() {
    final appData = Platform.environment['APPDATA'];
    if (appData == null || appData.isEmpty) {
      return null;
    }
    return path.join(appData, 'CodexBar', 'codex-accounts');
  }

  String? _defaultAmbientHome() {
    final userProfile = Platform.environment['USERPROFILE'];
    if (userProfile != null && userProfile.isNotEmpty) {
      return path.join(userProfile, '.codex');
    }
    final home = Platform.environment['HOME'];
    return home == null || home.isEmpty ? null : path.join(home, '.codex');
  }
}

class _CodexAuthRecord {
  final Directory home;
  final Map<String, dynamic> document;
  final String? accessToken;
  final String? refreshToken;
  final String? idToken;
  final String? email;
  final String? providerAccountId;
  final bool isAmbient;

  const _CodexAuthRecord({
    required this.home,
    required this.document,
    required this.accessToken,
    required this.refreshToken,
    required this.idToken,
    required this.email,
    required this.providerAccountId,
    required this.isAmbient,
  });

  String get stableId => providerAccountId ?? path.basename(home.path);

  String get identityKey =>
      (providerAccountId ?? email ?? home.path).toLowerCase();
}

bool _isUnauthorized(Response<dynamic>? response) {
  return response?.statusCode == 401 || response?.statusCode == 403;
}

String? _string(dynamic value) {
  if (value is! String || value.trim().isEmpty) {
    return null;
  }
  return value.trim();
}

double? _number(dynamic value) {
  final number = value is num ? value.toDouble() : null;
  return number != null && number.isFinite ? number : null;
}

int? _int(dynamic value) => value is num ? value.toInt() : null;

DateTime? _date(dynamic value) {
  if (value is num && value.isFinite) {
    return DateTime.fromMillisecondsSinceEpoch(
      (value.toDouble() * 1000).round(),
      isUtc: true,
    ).toLocal();
  }
  final raw = _string(value);
  return raw == null ? null : DateTime.tryParse(raw)?.toLocal();
}

String? _jwtString(String? token, List<String> keys) {
  if (token == null) {
    return null;
  }
  try {
    final parts = token.split('.');
    if (parts.length < 2) {
      return null;
    }
    final payload = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
    );
    if (payload is! Map) {
      return null;
    }
    for (final key in keys) {
      dynamic direct = payload[key];
      if (direct == null && key.startsWith('https://api.openai.com/auth.')) {
        final auth = payload['https://api.openai.com/auth'];
        if (auth is Map) {
          direct = auth[key.substring('https://api.openai.com/auth.'.length)];
        }
      }
      if (direct == null && key.startsWith('https://api.openai.com/profile.')) {
        final profile = payload['https://api.openai.com/profile'];
        if (profile is Map) {
          direct = profile[key.substring('https://api.openai.com/profile.'.length)];
        }
      }
      if (direct != null) {
        final result = _string(direct);
        if (result != null) {
          return result;
        }
      }
      final segments = key.split('.');
      dynamic current = payload;
      for (final segment in segments) {
        if (current is! Map) {
          current = null;
          break;
        }
        current = current[segment];
      }
      final result = _string(current);
      if (result != null) {
        return result;
      }
    }
  } on FormatException {
    return null;
  }
  return null;
}

bool _samePath(String left, String? right) {
  if (right == null || right.isEmpty) {
    return false;
  }
  return path.normalize(left).toLowerCase() == path.normalize(right).toLowerCase();
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
