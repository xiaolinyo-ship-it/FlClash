// coverage:ignore-file

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
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
  }) : _client = client ?? _defaultClient(),
       _clock = clock ?? DateTime.now;

  static Dio _defaultClient() {
    final dio = Dio();
    final proxy = _localProxyUri();
    if (proxy == null || proxy.host.isEmpty || proxy.port <= 0) {
      return dio;
    }
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.findProxy = (_) => 'PROXY ${proxy.host}:${proxy.port}';
        return client;
      },
    );
    return dio;
  }

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
      final record = await _readAuth(
        home.home,
        registeredId: home.registeredId,
      );
      if (record == null || record.accessToken == null) {
        continue;
      }
      // A registered home is an independent account slot. Login switching
      // can temporarily make two homes contain the same provider identity;
      // collapsing them here would silently remove a registered account.
      if (registeredHomes != null) {
        records.add(record);
        continue;
      }
      final key = record.providerAccountId ?? record.email ?? home.home.path;
      final previous = byIdentity[key.toLowerCase()];
      if (previous == null || _preferRecord(record, previous)) {
        byIdentity[key.toLowerCase()] = record;
      }
    }
    records.addAll(byIdentity.values);
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
    var unavailableCount = 0;
    for (final record in records) {
      final account = await _readAccount(record);
      if (account == null) {
        unavailableCount++;
        continue;
      }
      accounts.add(account);
    }
    if (accounts.isEmpty) {
      return const CodexSnapshotReadResult(
        snapshot: null,
        failure: CodexSnapshotReadFailure.unknown,
      );
    }

    final current = accounts.where((account) => account.isCurrent).toList();
    final registeredMissingCount = registeredHomes == null
        ? 0
        : (registeredHomes.length - records.length).clamp(0, 999).toInt();
    if (registeredMissingCount == 0 && unavailableCount == 0) {
      await _writeRegistry(records);
    }
    return CodexSnapshotReadResult(
      snapshot: CodexAccountSnapshot(
        accounts: accounts,
        readAt: _clock(),
        source: CodexSnapshotSource.live,
        currentConfirmed: current.length == 1,
      ),
      failure: null,
      missingAccountCount: registeredMissingCount + unavailableCount,
      source: CodexSnapshotSource.live,
    );
  }

  Future<List<_CodexHome>> _discoverHomes(
    List<_RegisteredCodexHome>? registeredHomes,
  ) async {
    final result = <_CodexHome>[];
    final seen = <String>{};
    final add = (String? rawPath, {String? registeredId}) {
      if (rawPath == null || rawPath.trim().isEmpty) {
        return;
      }
      final normalized = path.normalize(rawPath);
      final key = normalized.toLowerCase();
      if (seen.add(key)) {
        result.add(
          _CodexHome(Directory(normalized), registeredId: registeredId),
        );
      }
    };

    if (registeredHomes != null) {
      for (final home in registeredHomes) {
        add(home.home, registeredId: home.id);
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
                  registeredHomes.any(
                    (home) => _samePath(home.home, entry.path),
                  ))) {
            add(entry.path);
          }
        }
      } on FileSystemException {
        // Missing managed homes are handled by the caller as a read failure.
      }
    }
    return result;
  }

  Future<List<_RegisteredCodexHome>?> _readRegistry() async {
    final file = _registryFile;
    if (file == null || !await file.exists()) {
      return null;
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['accounts'] is! List) {
        return null;
      }
      final homes = <_RegisteredCodexHome>[];
      for (final item in decoded['accounts'] as List) {
        if (item is Map) {
          final home = _string(item['home']);
          if (home != null) {
            homes.add(
              _RegisteredCodexHome(
                id: _string(item['id']) ?? path.basename(home),
                home: home,
              ),
            );
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
          final value = entry.value as Map;
          final providerAccountId = _string(value['providerAccountId']);
          if (providerAccountId != null) {
            accountIdentities.add(providerAccountId.toLowerCase());
          }
          final email = _string(value['email']);
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
              .map(
                (record) => {'id': record.stableId, 'home': record.home.path},
              )
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
    final appData = _flClashDataPath();
    if (appData == null || appData.isEmpty) {
      return null;
    }
    return File(path.join(appData, 'FlClash', 'codex-accounts-registry.json'));
  }

  Future<_CodexAuthRecord?> _readAuth(
    Directory home, {
    String? registeredId,
  }) async {
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
          _string(tokenMap['account_id']) ??
          _jwtString(idToken, [
            'https://api.openai.com/auth.chatgpt_account_id',
            'chatgpt_account_id',
          ]);
      final email =
          _string(document['email']) ??
          _jwtString(idToken, ['email']) ??
          _jwtString(idToken, ['https://api.openai.com/profile.email']);
      return _CodexAuthRecord(
        home: home,
        registeredId: registeredId,
        document: document,
        accessToken: accessToken,
        refreshToken: refreshToken,
        idToken: idToken,
        email: email,
        providerAccountId: providerAccountId,
        isAmbient: _samePath(
          home.path,
          ambientHomePath ?? _defaultAmbientHome(),
        ),
        lastRefresh: _date(document['last_refresh']),
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
    // Prefer the official local Codex app-server rate-limit RPC. It exposes
    // the optional monthly credit limit without adding a resident service or
    // reading another credential store. The HTTP path below remains the
    // compatibility fallback for older Codex installations.
    if (!const bool.fromEnvironment('FLCLASH_CODEX_GUI_SMOKE')) {
      final appServer = await _getAppServerUsage(record);
      if (appServer != null) {
        final windows = _extractWindows(appServer);
        if (_windowFor(windows, 18000) != null &&
            _windowFor(windows, 604800) != null) {
          return appServer;
        }
        final http = await _requestHttpUsage(record);
        return http == null ? appServer : _mergeUsagePayload(http, appServer);
      }
    }
    return _requestHttpUsage(record);
  }

  Future<Map<String, dynamic>?> _requestHttpUsage(
    _CodexAuthRecord record,
  ) async {
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
    if (response == null ||
        response.statusCode != 200 ||
        response.data is! Map) {
      return null;
    }
    return Map<String, dynamic>.from(response.data as Map);
  }

  Future<Map<String, dynamic>?> _getAppServerUsage(
    _CodexAuthRecord record,
  ) async {
    Process? process;
    StreamSubscription<String>? outputSubscription;
    Timer? timeout;
    var initialized = false;
    var completed = false;
    final result = Completer<Map<String, dynamic>?>();

    void complete(Map<String, dynamic>? value) {
      if (completed) {
        return;
      }
      completed = true;
      timeout?.cancel();
      if (!result.isCompleted) {
        result.complete(value);
      }
    }

    try {
      final appServerProcess = await Process.start(
        'codex',
        const ['app-server', '--stdio'],
        workingDirectory: record.home.path,
        environment: {...Platform.environment, 'CODEX_HOME': record.home.path},
        runInShell: false,
      );
      process = appServerProcess;
      // Never surface app-server diagnostics in the dashboard or logs.
      unawaited(appServerProcess.stderr.drain<void>());
      outputSubscription = appServerProcess.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) {
              if (completed || line.trim().isEmpty) {
                return;
              }
              dynamic decoded;
              try {
                decoded = jsonDecode(line);
              } on FormatException {
                return;
              }
              if (decoded is! Map) {
                return;
              }
              final id = decoded['id'];
              if (id == 1 && !initialized) {
                initialized = true;
                appServerProcess.stdin.writeln(
                  jsonEncode({'method': 'initialized', 'params': {}}),
                );
                appServerProcess.stdin.writeln(
                  jsonEncode({'method': 'account/rateLimits/read', 'id': 7}),
                );
                unawaited(appServerProcess.stdin.flush());
                return;
              }
              if (id != 7) {
                return;
              }
              final response = decoded['result'];
              if (response is Map && response['rateLimits'] is Map) {
                complete(Map<String, dynamic>.from(response));
              } else {
                complete(null);
              }
            },
            onError: (_) => complete(null),
            cancelOnError: true,
          );
      unawaited(appServerProcess.exitCode.then<void>((_) => complete(null)));
      timeout = Timer(const Duration(seconds: 15), () => complete(null));
      appServerProcess.stdin.writeln(
        jsonEncode({
          'method': 'initialize',
          'id': 1,
          'params': {
            'clientInfo': {
              'name': 'flclash',
              'title': 'FlClash',
              'version': '1',
            },
            'capabilities': {'experimentalApi': true},
          },
        }),
      );
      await appServerProcess.stdin.flush();
      return await result.future;
    } on ProcessException {
      complete(null);
      return null;
    } on IOException {
      complete(null);
      return null;
    } finally {
      timeout?.cancel();
      final subscription = outputSubscription;
      if (subscription != null) {
        await subscription.cancel();
      }
      final running = process;
      if (running != null) {
        running.kill();
      }
    }
  }

  static Map<String, dynamic> _mergeUsagePayload(
    Map<String, dynamic> http,
    Map<String, dynamic> appServer,
  ) {
    final merged = Map<String, dynamic>.from(http);
    final rateLimits = appServer['rateLimits'];
    if (rateLimits is Map) {
      merged['appServerRateLimits'] = Map<String, dynamic>.from(rateLimits);
    }
    final byLimitId = appServer['rateLimitsByLimitId'];
    if (byLimitId is Map) {
      merged['appServerRateLimitsByLimitId'] = Map<String, dynamic>.from(
        byLimitId,
      );
    }
    return merged;
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
        registeredId: record.registeredId,
        document: nextDocument,
        accessToken: accessToken,
        refreshToken: nextTokens['refresh_token'] as String?,
        idToken: idToken,
        email: record.email ?? _jwtString(idToken, ['email']),
        providerAccountId: record.providerAccountId,
        isAmbient: record.isAmbient,
        lastRefresh: record.lastRefresh,
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
    void addWindow(dynamic value, int? hint, {bool overwrite = true}) {
      if (value is Map) {
        final window = _parseLiveWindow(Map<String, dynamic>.from(value), hint);
        if (window != null && window.limitWindowSeconds != null) {
          final duration = window.limitWindowSeconds!;
          if (overwrite || !windows.containsKey(duration)) {
            windows[duration] = window;
          }
        }
      }
    }

    void addRateLimitObject(dynamic value, {bool overwrite = true}) {
      if (value is! Map) {
        return;
      }
      final rate = Map<String, dynamic>.from(value);
      for (final entry in rate.entries) {
        final key = entry.key.toString().toLowerCase();
        if (entry.value is List) {
          for (final item in entry.value as List) {
            addWindow(item, _durationHint(key), overwrite: overwrite);
          }
        } else {
          addWindow(entry.value, _durationHint(key), overwrite: overwrite);
        }
      }
    }

    final rateLimit = payload['rate_limit'] ?? payload['rateLimit'];
    addRateLimitObject(rateLimit);

    final protocolRateLimits = payload['rateLimits'];
    if (protocolRateLimits is Map) {
      addRateLimitObject(protocolRateLimits);
    }

    final appServerRateLimits =
        payload['appServerRateLimits'] ?? payload['app_server_rate_limits'];
    if (appServerRateLimits is Map) {
      addRateLimitObject(appServerRateLimits);
    }

    final byLimitId =
        payload['rateLimitsByLimitId'] ??
        payload['appServerRateLimitsByLimitId'];
    if (byLimitId is Map) {
      for (final value in byLimitId.values) {
        addRateLimitObject(value, overwrite: false);
      }
    }

    final rateLimits = payload['rate_limits'] ?? payload['rateLimits'];
    if (rateLimits is List) {
      for (final item in rateLimits) {
        addWindow(item, null, overwrite: false);
      }
    }

    // CodexBar also exposes feature-scoped windows here (for example Codex
    // Spark). Keep this parser future-proof for a monthly window nested under
    // one of these entries without allowing an auxiliary 5h/week window to
    // replace the account's primary window.
    final additional =
        payload['additional_rate_limits'] ?? payload['additionalRateLimits'];
    if (additional is List) {
      for (final item in additional) {
        if (item is Map) {
          addRateLimitObject(
            item['rate_limit'] ?? item['rateLimit'] ?? item,
            overwrite: false,
          );
        }
      }
    }

    // The Codex API may expose the effective monthly credit limit as
    // `individualLimit` instead of a 30-day rate-limit window. This is a
    // subscription credit quota, not local cost estimation or a cash balance.
    final monthlyCredit = _parseMonthlyCreditLimit(payload);
    if (monthlyCredit != null && !windows.containsKey(2592000)) {
      windows[2592000] = monthlyCredit;
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
    final duration =
        _int(value['limit_window_seconds']) ??
        _int(value['limitWindowSeconds']) ??
        _windowDurationSeconds(value) ??
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

  static int? _windowDurationSeconds(Map<String, dynamic> value) {
    final minutes =
        _int(value['window_duration_mins']) ??
        _int(value['windowDurationMins']);
    return minutes == null ? null : minutes * 60;
  }

  static CodexQuotaWindow? _parseMonthlyCreditLimit(
    Map<String, dynamic> payload,
  ) {
    dynamic individual;
    individual = payload['individual_limit'] ?? payload['individualLimit'];
    for (final nested in [
      payload['spend_control'] ?? payload['spendControl'],
      payload['rate_limit'] ?? payload['rateLimit'],
      payload['rateLimits'],
      payload['appServerRateLimits'] ?? payload['app_server_rate_limits'],
    ]) {
      if (individual != null || nested is! Map) {
        continue;
      }
      individual = nested['individual_limit'] ?? nested['individualLimit'];
    }
    if (individual is! Map) {
      return null;
    }

    final limit = _number(individual['limit']);
    final used = _number(individual['used']);
    final storedRemaining = _number(
      individual['remaining_percent'] ??
          individual['remainingPercent'] ??
          individual['percent_remaining'] ??
          individual['percentRemaining'],
    );
    final usedPercent = used != null && limit != null && limit > 0
        ? (used / limit * 100).clamp(0, 100).toDouble()
        : storedRemaining == null
        ? null
        : (100 - storedRemaining).clamp(0, 100).toDouble();
    if (usedPercent == null) {
      return null;
    }
    return CodexQuotaWindow(
      limitWindowSeconds: 2592000,
      usedPercent: usedPercent,
      remainingPercent:
          storedRemaining ?? (100 - usedPercent).clamp(0, 100).toDouble(),
      resetAt: _date(individual['resets_at'] ?? individual['resetsAt']),
    );
  }

  static int? _durationHint(String key) {
    if (key.contains('primary') ||
        key.contains('session') ||
        key.contains('five')) {
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
    if (!base.startsWith('https://')) {
      base = _codexUsageBase;
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

  String? _flClashDataPath() {
    final smokeDataDir = const bool.fromEnvironment('FLCLASH_CODEX_GUI_SMOKE')
        ? Platform.environment['FLCLASH_CODEX_GUI_SMOKE_DATA_DIR']
        : null;
    if (smokeDataDir != null && smokeDataDir.isNotEmpty) {
      return smokeDataDir;
    }
    return Platform.environment['APPDATA'];
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
  final String? registeredId;
  final Map<String, dynamic> document;
  final String? accessToken;
  final String? refreshToken;
  final String? idToken;
  final String? email;
  final String? providerAccountId;
  final bool isAmbient;
  final DateTime? lastRefresh;

  const _CodexAuthRecord({
    required this.home,
    required this.registeredId,
    required this.document,
    required this.accessToken,
    required this.refreshToken,
    required this.idToken,
    required this.email,
    required this.providerAccountId,
    required this.isAmbient,
    required this.lastRefresh,
  });

  String get stableId => registeredId ?? providerAccountId ?? path.basename(home.path);

  String get identityKey =>
      (providerAccountId ?? email ?? home.path).toLowerCase();
}

class _RegisteredCodexHome {
  final String id;
  final String home;

  const _RegisteredCodexHome({required this.id, required this.home});
}

class _CodexHome {
  final Directory home;
  final String? registeredId;

  const _CodexHome(this.home, {this.registeredId});
}

bool _preferRecord(_CodexAuthRecord candidate, _CodexAuthRecord current) {
  if (candidate.isAmbient != current.isAmbient) {
    return candidate.isAmbient;
  }
  final candidateRefresh = candidate.lastRefresh;
  final currentRefresh = current.lastRefresh;
  if (candidateRefresh != null && currentRefresh == null) {
    return true;
  }
  if (candidateRefresh != null && currentRefresh != null) {
    return candidateRefresh.isAfter(currentRefresh);
  }
  return false;
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
  final number = value is num
      ? value.toDouble()
      : value is String
      ? double.tryParse(value.trim())
      : null;
  return number != null && number.isFinite ? number : null;
}

int? _int(dynamic value) {
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value.trim());
  }
  return null;
}

Uri? _localProxyUri() {
  for (final name in [
    'HTTPS_PROXY',
    'https_proxy',
    'HTTP_PROXY',
    'http_proxy',
  ]) {
    final raw = Platform.environment[name]?.trim();
    if (raw == null || raw.isEmpty) {
      continue;
    }
    final uri = Uri.tryParse(raw);
    if (uri != null && uri.host.isNotEmpty && uri.port > 0) {
      return uri;
    }
  }
  return null;
}

DateTime? _date(dynamic value) {
  if (value is num && value.isFinite) {
    return DateTime.fromMillisecondsSinceEpoch(
      (value.toDouble() * 1000).round(),
      isUtc: true,
    ).toLocal();
  }
  final raw = _string(value);
  if (raw == null) {
    return null;
  }
  final normalized = raw.replaceFirstMapped(
    RegExp(r'(\.\d{6})\d+(?=Z$|[+-]\d{2}:?\d{2}$)'),
    (match) => match.group(1)!,
  );
  return DateTime.tryParse(normalized)?.toLocal();
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
          direct =
              profile[key.substring('https://api.openai.com/profile.'.length)];
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
  return path.normalize(left).toLowerCase() ==
      path.normalize(right).toLowerCase();
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
