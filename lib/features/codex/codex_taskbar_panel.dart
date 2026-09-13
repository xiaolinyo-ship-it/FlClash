import 'dart:async';
import 'dart:io';

import 'package:fl_clash/features/codex/codex_account_snapshot.dart';
import 'package:fl_clash/features/codex/codex_account_switcher.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as path;
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

const codexTaskbarPanelArgument = '--codex-panel';

const _panelWidth = 620.0;
const _collapsedHeight = 52.0;
const _expandedHeight = 250.0;
const _screenInset = 12.0;

bool isCodexTaskbarPanel(List<String> args) =>
    args.contains(codexTaskbarPanelArgument);

abstract final class CodexTaskbarPanelRuntime {
  static RandomAccessFile? _lockFile;

  static Future<void> run() async {
    if (!Platform.isWindows) {
      return;
    }
    if (!await _acquireLock()) {
      return;
    }
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(false);
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setSkipTaskbar(true);
    await windowManager.setResizable(false);
    const options = WindowOptions(
      size: Size(_panelWidth, _collapsedHeight),
      minimumSize: Size(_panelWidth, _collapsedHeight),
      maximumSize: Size(_panelWidth, _expandedHeight),
      center: false,
      backgroundColor: Colors.transparent,
      skipTaskbar: true,
      titleBarStyle: TitleBarStyle.hidden,
    );
    await windowManager.waitUntilReadyToShow(options);
    await _placeWindow(_collapsedHeight);
    await windowManager.show();
    await windowManager.setAlwaysOnTop(true);
    runApp(const CodexTaskbarPanelApp());
  }

  static Future<bool> ensureStarted() async {
    if (!Platform.isWindows) {
      return false;
    }
    try {
      final process = await Process.start(
        Platform.resolvedExecutable,
        const [codexTaskbarPanelArgument],
        mode: ProcessStartMode.detached,
      );
      unawaited(process.exitCode);
      return true;
    } catch (error) {
      debugPrint('Codex taskbar panel start failed: $error');
      return false;
    }
  }

  static Future<void> resizeAndPlace(bool expanded) async {
    final height = expanded ? _expandedHeight : _collapsedHeight;
    await windowManager.setSize(Size(_panelWidth, height));
    await _placeWindow(height);
  }

  static Future<void> _placeWindow(double height) async {
    final displays = await screenRetriever.getAllDisplays();
    if (displays.isEmpty) {
      return;
    }
    final display = displays.firstWhere(
      (item) => item.visiblePosition != null,
      orElse: () => displays.first,
    );
    final origin = display.visiblePosition;
    if (origin == null) {
      return;
    }
    final workArea = Rect.fromLTWH(
      origin.dx,
      origin.dy,
      display.size.width,
      display.size.height,
    );
    await windowManager.setPosition(
      codexTaskbarPanelPosition(
        workArea: workArea,
        panelSize: const Size(_panelWidth, _collapsedHeight),
        height: height,
        inset: _screenInset,
      ),
    );
  }

  static Future<bool> _acquireLock() async {
    if (_lockFile != null) {
      return true;
    }
    final appData = Platform.environment['APPDATA'];
    if (appData == null || appData.isEmpty) {
      return false;
    }
    final lockPath = path.join(appData, 'FlClash', 'codex-taskbar-panel.lock');
    try {
      final file = File(lockPath);
      await file.parent.create(recursive: true);
      final lock = await file.open(mode: FileMode.write);
      await lock.lock();
      _lockFile = lock;
      return true;
    } catch (_) {
      return false;
    }
  }
}

@visibleForTesting
Offset codexTaskbarPanelPosition({
  required Rect workArea,
  required Size panelSize,
  required double height,
  double inset = _screenInset,
}) {
  return Offset(
    workArea.right - panelSize.width - inset,
    workArea.bottom - height - inset,
  );
}

class CodexTaskbarPanelApp extends StatelessWidget {
  const CodexTaskbarPanelApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xffd6bfc2),
      brightness: Brightness.dark,
      surface: const Color(0xff211f1f),
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: Colors.transparent,
      ),
      home: const CodexTaskbarPanel(),
    );
  }
}

class CodexTaskbarPanel extends StatefulWidget {
  final CodexAccountSnapshotReader? reader;
  final CodexAccountSwitcher? switcher;
  final DateTime Function()? clock;

  const CodexTaskbarPanel({
    super.key,
    @visibleForTesting this.reader,
    @visibleForTesting this.switcher,
    @visibleForTesting this.clock,
  });

  @override
  State<CodexTaskbarPanel> createState() => _CodexTaskbarPanelState();
}

class _CodexTaskbarPanelState extends State<CodexTaskbarPanel> {
  static const _refreshInterval = Duration(minutes: 2);

  late final CodexAccountSnapshotReader _reader;
  late final CodexAccountSwitcher _switcher;
  CodexAccountSnapshot? _snapshot;
  Set<String> _missingAccountIds = {};
  CodexSnapshotReadFailure? _failure;
  String? _message;
  String? _switchingId;
  Timer? _refreshTimer;
  bool _expanded = false;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _reader = widget.reader ?? CodexAccountSnapshotReader(clock: widget.clock);
    _switcher = widget.switcher ?? CodexAccountSwitcher();
    _load();
    _refreshTimer = Timer.periodic(_refreshInterval, (_) => _load());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading) {
      return;
    }
    _loading = true;
    CodexSnapshotReadResult result;
    try {
      result = await _reader.read();
    } catch (_) {
      if (mounted) {
        setState(() {
          _failure = CodexSnapshotReadFailure.unknown;
          _loading = false;
        });
      }
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _snapshot = result.snapshot ?? _snapshot;
      _failure = result.failure;
      _missingAccountIds = result.missingAccountIds.toSet();
      _loading = false;
    });
  }

  Future<void> _setExpanded(bool expanded) async {
    if (_expanded == expanded) {
      return;
    }
    setState(() => _expanded = expanded);
    await CodexTaskbarPanelRuntime.resizeAndPlace(expanded);
  }

  Future<void> _switchAccount(CodexAccountCardData account) async {
    if (_switchingId != null) {
      return;
    }
    setState(() {
      _switchingId = account.id;
      _message = '正在切换…';
    });
    try {
      final result = await _switcher.switchTo(account.id);
      if (!mounted) {
        return;
      }
      setState(() {
        _message = result.switched
            ? '已切换，Codex Desktop 正在重启'
            : (result.failure ?? '切换失败');
        _switchingId = null;
      });
      if (result.switched) {
        await Future<void>.delayed(const Duration(seconds: 2));
        await _load();
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _switchingId = null;
        _message = '切换失败：$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    CodexAccountCardData? current;
    if (snapshot != null && snapshot.currentConfirmed) {
      current = snapshot.accounts
          .where((account) => account.isCurrent)
          .firstOrNull;
    }
    return MouseRegion(
      onEnter: (_) => _setExpanded(true),
      onExit: (_) => _setExpanded(false),
      child: Material(
        color: Colors.transparent,
        child: _expanded
            ? _buildExpanded(context, snapshot)
            : _buildCollapsed(context, current),
      ),
    );
  }

  Widget _buildCollapsed(
    BuildContext context,
    CodexAccountCardData? current,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final fiveHour = current?.fiveHour?.remainingPercent;
    final weekly = current?.weekly?.remainingPercent;
    final reset = _shortDate(current?.weekly?.resetAt ?? current?.fiveHour?.resetAt);
    return _PanelSurface(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          Icon(Icons.code, size: 18, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              current == null
                  ? 'Codex  当前账户未确认'
                  : '${current.displayName}  5h ${_percent(fiveHour)}  W ${_percent(weekly)}  $reset',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          if (_loading)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
    );
  }

  Widget _buildExpanded(
    BuildContext context,
    CodexAccountSnapshot? snapshot,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final failure = _failure;
    final accounts = snapshot?.accounts ?? const <CodexAccountCardData>[];
    return _PanelSurface(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.code, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Codex 账户',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: '刷新快照',
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.refresh, size: 18),
              ),
            ],
          ),
          if (failure != null)
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _failureText(failure),
                style: TextStyle(color: scheme.error, fontSize: 11),
              ),
            ),
          if (accounts.isEmpty)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('暂无可显示的账户数据'),
              ),
            )
          else
            for (final account in accounts)
              _AccountRow(
                account: account,
                currentConfirmed: snapshot?.currentConfirmed ?? false,
                missing: _missingAccountIds.contains(account.id),
                switching: _switchingId == account.id,
                onTap: () => _switchAccount(account),
              ),
          if (_message != null)
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _message!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PanelSurface extends StatelessWidget {
  final EdgeInsets padding;
  final Widget child;

  const _PanelSurface({required this.padding, required this.child});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      height: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: scheme.surfaceContainer.withValues(alpha: .94),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant),
        boxShadow: const [
          BoxShadow(
            blurRadius: 18,
            spreadRadius: 1,
            color: Color(0x66000000),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _AccountRow extends StatelessWidget {
  final CodexAccountCardData account;
  final bool currentConfirmed;
  final bool missing;
  final bool switching;
  final VoidCallback onTap;

  const _AccountRow({
    required this.account,
    required this.currentConfirmed,
    required this.missing,
    required this.switching,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final status = missing
        ? '读取失败'
        : _status(account.statusAt(DateTime.now()));
    final statusColor = missing || account.hasDataAnomaly
        ? scheme.error
        : scheme.primary;
    final current = currentConfirmed && account.isCurrent;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Material(
        color: scheme.surface.withValues(alpha: .55),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: missing || switching ? null : onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                Icon(
                  Icons.circle,
                  size: 9,
                  color: current ? scheme.primary : scheme.outline,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    current ? '当前  ${account.displayName}' : account.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Text(
                  '5h ${_percent(account.fiveHour?.remainingPercent)}  W ${_percent(account.weekly?.remainingPercent)}  ${_shortDate(account.weekly?.resetAt ?? account.fiveHour?.resetAt)}',
                  style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
                ),
                const SizedBox(width: 8),
                if (switching)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Text(status, style: TextStyle(color: statusColor, fontSize: 11)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _percent(double? value) => value == null ? '-' : '${value.round()}%';

String _shortDate(DateTime? value) {
  if (value == null) {
    return '--.--';
  }
  final local = value.toLocal();
  return '${local.month.toString().padLeft(2, '0')}.${local.day.toString().padLeft(2, '0')}';
}

String _status(CodexAccountStatus status) {
  return switch (status) {
    CodexAccountStatus.normal => '正常',
    CodexAccountStatus.exhausted => '已用尽',
    CodexAccountStatus.expired => '数据过期',
    CodexAccountStatus.dataAnomaly => '数据异常',
    CodexAccountStatus.readFailed => '读取失败',
  };
}

String _failureText(CodexSnapshotReadFailure failure) {
  return switch (failure) {
    CodexSnapshotReadFailure.fileUnavailable => '快照不可用，等待 Codex 数据更新',
    CodexSnapshotReadFailure.invalidJson => '快照格式异常',
    CodexSnapshotReadFailure.invalidShape => '快照结构异常',
    CodexSnapshotReadFailure.unsupportedPlatform => '当前平台不支持',
    CodexSnapshotReadFailure.unknown => '读取失败',
  };
}
