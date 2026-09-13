import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

/// A registered Codex account slot. It contains only the stable slot id and
/// the local Codex home path; credential contents are never exposed here.
final class CodexAccountSlot {
  final String id;
  final String home;

  const CodexAccountSlot({required this.id, required this.home});
}

final class CodexAccountSwitchResult {
  final String accountId;
  final bool switched;
  final bool restartScheduled;
  final String? backupPath;
  final String? failure;

  const CodexAccountSwitchResult({
    required this.accountId,
    required this.switched,
    required this.restartScheduled,
    this.backupPath,
    this.failure,
  });
}

typedef CodexAuthCopier =
    Future<void> Function(String sourcePath, String destinationPath);

typedef CodexDesktopRestarter = Future<void> Function();

/// Switches the selected registered Codex home into the ambient Codex home.
///
/// This is deliberately a small, Windows-only bridge for the taskbar action:
/// it reads the local registry, backs up the current ambient auth file, copies
/// the selected auth file, and schedules a Codex Desktop restart. It does not
/// read accounts.json, perform OAuth, or touch FlClash's proxy processes.
final class CodexAccountSwitcher {
  final String? registryPath;
  final String? ambientHomePath;
  final String? backupDirectoryPath;
  final Future<String> Function()? readRegistryText;
  final CodexAuthCopier _copyAuth;
  final CodexDesktopRestarter _restartDesktop;
  final bool Function() _isWindows;
  final DateTime Function() _clock;

  CodexAccountSwitcher({
    this.registryPath,
    this.ambientHomePath,
    this.backupDirectoryPath,
    this.readRegistryText,
    CodexAuthCopier? copyAuth,
    CodexDesktopRestarter? restartDesktop,
    bool Function()? isWindows,
    DateTime Function()? clock,
  }) : _copyAuth = copyAuth ?? _copyFile,
       _restartDesktop = restartDesktop ?? CodexDesktopRestart.schedule,
       _isWindows = isWindows ?? (() => Platform.isWindows),
       _clock = clock ?? DateTime.now;

  Future<List<CodexAccountSlot>> readSlots() async {
    final raw = await _readRegistry();
    final decoded = jsonDecode(raw);
    if (decoded is! Map || decoded['accounts'] is! List) {
      throw const FormatException('Codex account registry is invalid');
    }

    final slots = <CodexAccountSlot>[];
    for (final item in decoded['accounts'] as List) {
      if (item is! Map) {
        continue;
      }
      final id = _string(item['id']);
      final home = _string(item['home']);
      if (id == null || home == null) {
        continue;
      }
      slots.add(CodexAccountSlot(id: id, home: path.normalize(home)));
    }
    if (slots.isEmpty) {
      throw const FormatException('Codex account registry has no slots');
    }
    return slots;
  }

  Future<CodexAccountSwitchResult> switchTo(String accountId) async {
    if (!_isWindows()) {
      return CodexAccountSwitchResult(
        accountId: accountId,
        switched: false,
        restartScheduled: false,
        failure: 'Codex 账户切换仅支持 Windows',
      );
    }

    final slots = await readSlots();
    final matching = slots.where((slot) => slot.id == accountId).toList();
    final target = matching.isEmpty ? null : matching.first;
    if (target == null) {
      return CodexAccountSwitchResult(
        accountId: accountId,
        switched: false,
        restartScheduled: false,
        failure: '未找到选中的 Codex 账户槽位',
      );
    }

    final ambient = path.normalize(ambientHomePath ?? _defaultAmbientHome());
    final sourceAuth = path.join(target.home, 'auth.json');
    final destinationAuth = path.join(ambient, 'auth.json');
    if (!await File(sourceAuth).exists()) {
      return CodexAccountSwitchResult(
        accountId: accountId,
        switched: false,
        restartScheduled: false,
        failure: '选中的 Codex 账户缺少认证文件',
      );
    }
    if (_samePath(sourceAuth, destinationAuth)) {
      return CodexAccountSwitchResult(
        accountId: accountId,
        switched: false,
        restartScheduled: false,
        failure: '该账户已经是当前 Codex 账户',
      );
    }

    await Directory(ambient).create(recursive: true);
    final backupPath = await _backupAmbientAuth(destinationAuth);
    await _copyAuth(sourceAuth, destinationAuth);
    await _restartDesktop();
    return CodexAccountSwitchResult(
      accountId: accountId,
      switched: true,
      restartScheduled: true,
      backupPath: backupPath,
    );
  }

  Future<String> _readRegistry() async {
    final reader = readRegistryText;
    if (reader != null) {
      return reader();
    }
    final resolved = registryPath ?? _defaultRegistryPath();
    return File(resolved).readAsString();
  }

  Future<String?> _backupAmbientAuth(String sourcePath) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      return null;
    }
    final directory =
        backupDirectoryPath ??
        path.join(_defaultFlClashDataPath(), 'FlClash', 'codex-auth-backups');
    await Directory(directory).create(recursive: true);
    final stamp = _clock().toUtc().toIso8601String().replaceAll(
      RegExp(r'[^0-9]'),
      '',
    );
    final destination = path.join(directory, 'ambient-auth-$stamp.json');
    await _copyAuth(sourcePath, destination);
    return destination;
  }

  String _defaultRegistryPath() {
    return path.join(
      _defaultFlClashDataPath(),
      'FlClash',
      'codex-accounts-registry.json',
    );
  }

  String _defaultFlClashDataPath() {
    final appData = Platform.environment['APPDATA'];
    if (appData == null || appData.isEmpty) {
      throw const FileSystemException('APPDATA is unavailable');
    }
    return appData;
  }

  String _defaultAmbientHome() {
    final userProfile = Platform.environment['USERPROFILE'];
    if (userProfile == null || userProfile.isEmpty) {
      throw const FileSystemException('USERPROFILE is unavailable');
    }
    return path.join(userProfile, '.codex');
  }
}

abstract final class CodexDesktopRestart {
  static Future<void> schedule() async {
    if (!Platform.isWindows) {
      throw UnsupportedError('Codex Desktop restart is Windows-only');
    }
    final appData = Platform.environment['APPDATA'];
    if (appData == null || appData.isEmpty) {
      throw const FileSystemException('APPDATA is unavailable');
    }
    final scriptPath = path.join(
      appData,
      'FlClash',
      'codex-desktop-restart.ps1',
    );
    const script = _restartScript;
    await File(scriptPath).parent.create(recursive: true);
    await File(scriptPath).writeAsString(script, flush: true);

    final windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final powershell = path.join(
      windir,
      'System32',
      'WindowsPowerShell',
      'v1.0',
      'powershell.exe',
    );
    final process = await Process.start(powershell, [
      '-NoProfile',
      '-NonInteractive',
      '-WindowStyle',
      'Hidden',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      scriptPath,
    ], mode: ProcessStartMode.detachedWithStdio);
    unawaited(process.exitCode);
  }
}

const String _restartScript = r'''
$ErrorActionPreference = 'SilentlyContinue'
$main = Get-CimInstance Win32_Process | Where-Object {
  ($_.Name -ieq 'ChatGPT.exe' -or $_.Name -ieq 'Codex.exe') -and
  $_.ExecutablePath -and
  $_.ExecutablePath -like '*\OpenAI.Codex_*\app\*'
} | Select-Object -First 1
$launcherPath = $main.ExecutablePath
if (-not $launcherPath) {
  $package = Get-AppxPackage | Where-Object {
    $_.Name -eq 'OpenAI.Codex' -or $_.PackageFamilyName -like 'OpenAI.Codex*'
  } | Sort-Object Version -Descending | Select-Object -First 1
  if ($package -and $package.InstallLocation) {
    $candidate = Join-Path $package.InstallLocation 'app\ChatGPT.exe'
    if (Test-Path -LiteralPath $candidate) { $launcherPath = $candidate }
    if (-not $launcherPath) {
      $candidate = Join-Path $package.InstallLocation 'app\Codex.exe'
      if (Test-Path -LiteralPath $candidate) { $launcherPath = $candidate }
    }
  }
}
$targets = Get-CimInstance Win32_Process | Where-Object {
  $_.ExecutablePath -and (
    $_.ExecutablePath -like '*\OpenAI.Codex_*\app\*' -or
    $_.ExecutablePath -like '*\OpenAI.Codex_*\app\resources\*'
  )
}
foreach ($target in $targets) {
  & taskkill.exe /PID $target.ProcessId /T /F | Out-Null
}
Start-Sleep -Milliseconds 900
if ($launcherPath) { Start-Process -FilePath $launcherPath }
''';

Future<void> _copyFile(String sourcePath, String destinationPath) async {
  await File(sourcePath).copy(destinationPath);
}

String? _string(dynamic value) {
  if (value is! String || value.trim().isEmpty) {
    return null;
  }
  return value.trim();
}

bool _samePath(String left, String right) =>
    path.normalize(left).toLowerCase() == path.normalize(right).toLowerCase();
