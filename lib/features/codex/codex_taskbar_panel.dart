// coverage:ignore-file

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:fl_clash/features/codex/codex_account_snapshot.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as path;
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

const codexTaskbarPanelArgument = '--codex-panel';

const _collapsedWidth = 420.0;
const _expandedWidth = 660.0;
const _collapsedHeight = 40.0;
const _expandedHeight = 126.0;
const _screenInset = 12.0;
const _positionFileName = 'codex-taskbar-panel-position.json';

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
    const options = WindowOptions(
      size: Size(_collapsedWidth, _collapsedHeight),
      minimumSize: Size(_collapsedWidth, _collapsedHeight),
      maximumSize: Size(_expandedWidth, _expandedHeight),
      center: false,
      backgroundColor: Colors.transparent,
      skipTaskbar: true,
      titleBarStyle: TitleBarStyle.hidden,
    );
    await windowManager.waitUntilReadyToShow(options);
    await windowManager.setAsFrameless();
    await windowManager.setPreventClose(false);
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setSkipTaskbar(true);
    await windowManager.setMovable(true);
    await windowManager.setResizable(false);
    await _placeInitialWindow(_collapsedHeight);
    runApp(const CodexTaskbarPanelApp());
    await WidgetsBinding.instance.endOfFrame;
    await windowManager.setSize(const Size(_collapsedWidth, _collapsedHeight));
    await windowManager.show();
    await windowManager.focus();
    await windowManager.setAlwaysOnTop(true);
  }

  static Future<bool> ensureStarted() async {
    if (!Platform.isWindows) {
      return false;
    }
    try {
      final process = await Process.start(Platform.resolvedExecutable, const [
        codexTaskbarPanelArgument,
      ], mode: ProcessStartMode.detached);
      unawaited(process.exitCode);
      return true;
    } catch (error) {
      debugPrint('Codex taskbar panel start failed: $error');
      return false;
    }
  }

  static Future<void> resizeAndPlace(bool expanded) async {
    final height = expanded ? _expandedHeight : _collapsedHeight;
    final width = expanded ? _expandedWidth : _collapsedWidth;
    final previousSize = await windowManager.getSize();
    final previousPosition = await windowManager.getPosition();
    await windowManager.setSize(Size(width, height));
    final position = Offset(
      previousPosition.dx + (previousSize.width - width) / 2,
      previousPosition.dy + previousSize.height - height,
    );
    final workArea = await _workAreaFor(position);
    if (workArea != null) {
      await windowManager.setPosition(
        codexTaskbarPanelClampPosition(
          workArea: workArea,
          panelSize: Size(width, height),
          position: position,
          inset: _screenInset,
        ),
      );
    }
  }

  static Future<void> rememberCurrentPosition() async {
    try {
      final position = await windowManager.getPosition();
      final filePath = _positionFilePath();
      if (filePath == null) {
        return;
      }
      final file = File(filePath);
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({'x': position.dx, 'y': position.dy}),
        flush: true,
      );
    } catch (error) {
      debugPrint('Codex taskbar panel position save failed: $error');
    }
  }

  static Future<void> _placeInitialWindow(double height) async {
    final displays = await screenRetriever.getAllDisplays();
    if (displays.isEmpty) {
      return;
    }
    final savedPosition = await _readSavedPosition();
    final display = displays.firstWhere(
      (item) =>
          item.visiblePosition != null &&
          (savedPosition == null ||
              _workArea(item, item.visiblePosition!).contains(savedPosition)),
      orElse: () => displays.first,
    );
    final origin = display.visiblePosition;
    if (origin == null) {
      return;
    }
    final workArea = _workArea(display, origin);
    final position = savedPosition == null
        ? codexTaskbarPanelPosition(
        workArea: workArea,
        panelSize: Size(_collapsedWidth, height),
            height: height,
            inset: _screenInset,
          )
        : codexTaskbarPanelClampPosition(
            workArea: workArea,
            panelSize: Size(_expandedWidth, height),
            position: savedPosition,
            inset: _screenInset,
          );
    await windowManager.setPosition(
      position,
    );
  }

  static String? _positionFilePath() {
    final appData = Platform.environment['APPDATA'];
    if (appData == null || appData.isEmpty) {
      return null;
    }
    return path.join(appData, 'FlClash', _positionFileName);
  }

  static Future<Offset?> _readSavedPosition() async {
    final filePath = _positionFilePath();
    if (filePath == null) {
      return null;
    }
    try {
      final value = jsonDecode(await File(filePath).readAsString());
      if (value is! Map) {
        return null;
      }
      final x = (value['x'] as num?)?.toDouble();
      final y = (value['y'] as num?)?.toDouble();
      if (x == null || y == null || !x.isFinite || !y.isFinite) {
        return null;
      }
      return Offset(x, y);
    } catch (_) {
      return null;
    }
  }

  static Future<Rect?> _workAreaFor(Offset position) async {
    final displays = await screenRetriever.getAllDisplays();
    if (displays.isEmpty) {
      return null;
    }
    for (final display in displays) {
      final origin = display.visiblePosition;
      if (origin == null) {
        continue;
      }
      final workArea = _workArea(display, origin);
      if (workArea.contains(position)) {
        return workArea;
      }
    }
    final display = displays.firstWhere(
      (item) => item.visiblePosition != null,
      orElse: () => displays.first,
    );
    final origin = display.visiblePosition;
    return origin == null ? null : _workArea(display, origin);
  }

  static Rect _workArea(Display display, Offset origin) {
    final size = display.visibleSize ?? display.size;
    return Rect.fromLTWH(origin.dx, origin.dy, size.width, size.height);
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
    workArea.left + (workArea.width - panelSize.width) / 2,
    workArea.bottom - height - inset,
  );
}

@visibleForTesting
Offset codexTaskbarPanelClampPosition({
  required Rect workArea,
  required Size panelSize,
  required Offset position,
  double inset = _screenInset,
}) {
  final minX = workArea.left + inset;
  final maxX = workArea.right - panelSize.width - inset;
  final minY = workArea.top + inset;
  final maxY = workArea.bottom - panelSize.height - inset;
  return Offset(
    position.dx.clamp(minX, maxX).toDouble(),
    position.dy.clamp(minY, maxY).toDouble(),
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
        fontFamily: 'Segoe UI',
        colorScheme: scheme,
        scaffoldBackgroundColor: Colors.transparent,
      ),
      home: const CodexTaskbarPanel(),
    );
  }
}

class CodexTaskbarPanel extends StatefulWidget {
  final CodexAccountSnapshotReader? reader;
  final DateTime Function()? clock;

  const CodexTaskbarPanel({
    super.key,
    @visibleForTesting this.reader,
    @visibleForTesting this.clock,
  });

  @override
  State<CodexTaskbarPanel> createState() => _CodexTaskbarPanelState();
}

class _CodexTaskbarPanelState extends State<CodexTaskbarPanel> {
  static const _refreshInterval = Duration(minutes: 2);

  late final CodexAccountSnapshotReader _reader;
  CodexAccountSnapshot? _snapshot;
  Set<String> _missingAccountIds = {};
  CodexSnapshotReadFailure? _failure;
  Timer? _refreshTimer;
  bool _expanded = false;
  bool _loading = false;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _reader = widget.reader ?? CodexAccountSnapshotReader(clock: widget.clock);
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

  Future<void> _startDragging() async {
    if (mounted) {
      setState(() => _dragging = true);
    }
    try {
      await windowManager.startDragging();
    } finally {
      if (mounted) {
        setState(() => _dragging = false);
      }
      await CodexTaskbarPanelRuntime.rememberCurrentPosition();
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
      onExit: (_) {
        if (!_dragging) {
          _setExpanded(false);
        }
      },
      child: Material(
        color: Colors.transparent,
        child: _expanded
            ? _buildExpanded(context, snapshot)
        : _buildCollapsed(context, current),
      ),
    );
  }

  Widget _buildCollapsed(BuildContext context, CodexAccountCardData? current) {
    final fiveHour = current?.fiveHour?.remainingPercent;
    final weekly = current?.weekly?.remainingPercent;
    final reset = current?.hasDataAnomaly == true
        ? '--.--'
        : _shortDate(current?.weekly?.resetAt ?? current?.fiveHour?.resetAt);
    return Center(
      child: SizedBox(
        width: 396,
        height: 30,
        child: _PanelSurface(
          popup: false,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          onDrag: _startDragging,
          child: _SummaryLine(
            account: current,
            fiveHour: current?.hasDataAnomaly == true ? null : fiveHour,
            weekly: current?.hasDataAnomaly == true ? null : weekly,
            reset: reset,
            loading: _loading,
          ),
        ),
      ),
    );
  }

  Widget _buildExpanded(BuildContext context, CodexAccountSnapshot? snapshot) {
    final failure = _failure;
    final accounts = snapshot?.accounts ?? const <CodexAccountCardData>[];
    return _PanelSurface(
      popup: true,
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      onDrag: _startDragging,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (failure != null)
            _PanelToolbar(
              failure: _failureText(failure),
              loading: _loading,
              onRefresh: _loading ? null : _load,
            ),
          if (accounts.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(8, 8, 8, 6),
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
              ),
        ],
      ),
    );
  }
}

class _PanelSurface extends StatelessWidget {
  final EdgeInsets padding;
  final Widget child;
  final Future<void> Function()? onDrag;
  final bool popup;

  const _PanelSurface({
    required this.padding,
    required this.child,
    required this.popup,
    this.onDrag,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.all(Radius.circular(popup ? 20 : 14)),
        boxShadow: const [
          BoxShadow(
            blurRadius: 20,
            spreadRadius: 1,
            color: Color(0x73000000),
          ),
        ],
      ),
      child: MouseRegion(
        cursor: onDrag == null
            ? MouseCursor.defer
            : SystemMouseCursors.grab,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: onDrag == null ? null : (_) => unawaited(onDrag!()),
          child: ClipRRect(
            borderRadius: BorderRadius.all(Radius.circular(popup ? 20 : 14)),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: Container(
                padding: padding,
                decoration: BoxDecoration(
                  color: popup
                      ? const Color(0xCC171F2B)
                      : const Color(0xBDD5E7F2),
                  borderRadius: BorderRadius.all(
                    Radius.circular(popup ? 20 : 14),
                  ),
                  border: Border.all(
                    color: popup
                        ? const Color(0x8AFFFFFF)
                        : const Color(0x99FFFFFF),
                    width: 1.0,
                  ),
                ),
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SummaryLine extends StatelessWidget {
  final CodexAccountCardData? account;
  final double? fiveHour;
  final double? weekly;
  final String reset;
  final bool loading;

  const _SummaryLine({
    required this.account,
    required this.fiveHour,
    required this.weekly,
    required this.reset,
    required this.loading,
  });

  @override
  Widget build(BuildContext context) {
    final name = account?.displayName ?? 'Codex 账户未确认';
    return Row(
      children: [
        _StatusDot(
          current: account != null && account!.isCurrent,
          color: const Color(0xff36556b),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text.rich(
            TextSpan(
              style: const TextStyle(
                color: Color(0xff182a36),
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
              children: [
                TextSpan(text: name),
                const TextSpan(text: '   5h '),
                TextSpan(
                  text: _percent(fiveHour),
                  style: const TextStyle(color: Color(0xff3f8f5b)),
                ),
                const TextSpan(text: '  |  W '),
                TextSpan(
                  text: _percent(weekly),
                  style: const TextStyle(color: Color(0xff3f8f5b)),
                ),
                TextSpan(
                  text: '  |  $reset',
                  style: const TextStyle(color: Color(0xff40505a)),
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (loading)
          const Padding(
            padding: EdgeInsets.only(left: 8),
            child: SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(
                strokeWidth: 1.7,
                color: Color(0xffd9dde2),
              ),
            ),
          ),
      ],
    );
  }
}

class _PanelToolbar extends StatelessWidget {
  final String? failure;
  final bool loading;
  final VoidCallback? onRefresh;

  const _PanelToolbar({
    required this.failure,
    required this.loading,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final text = failure;
    return SizedBox(
      height: 20,
      child: Row(
        children: [
          if (text != null)
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: failure == null
                      ? const Color(0xffc8cbd0)
                      : const Color(0xffffb4ab),
                  fontSize: 10,
                ),
              ),
            )
          else
            const Spacer(),
          if (loading)
            const SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(
                strokeWidth: 1.7,
                color: Color(0xffd9dde2),
              ),
            ),
          IconButton(
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 22, height: 20),
            tooltip: '刷新额度',
            onPressed: onRefresh,
            icon: const Icon(
              Icons.refresh,
              size: 15,
              color: Color(0xffc8cbd0),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  final bool current;
  final Color color;

  const _StatusDot({
    required this.current,
    this.color = const Color(0xffa9adb3),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: current
            ? Border.all(color: const Color(0xffe7eaee), width: 1.2)
            : null,
        boxShadow: current
            ? const [
                BoxShadow(
                  blurRadius: 4,
                  spreadRadius: 1,
                  color: Color(0x66E7EAEE),
                ),
              ]
            : null,
      ),
    );
  }
}

class _AccountRow extends StatelessWidget {
  final CodexAccountCardData account;
  final bool currentConfirmed;
  final bool missing;

  const _AccountRow({
    required this.account,
    required this.currentConfirmed,
    required this.missing,
  });

  @override
  Widget build(BuildContext context) {
    final status = missing ? '读取失败' : _status(account.statusAt(DateTime.now()));
    final current = currentConfirmed && account.isCurrent;
    final statusColor = missing || account.hasDataAnomaly
        ? const Color(0xffffcf8a)
        : status == '已用尽'
            ? const Color(0xffffb4b4)
            : const Color(0xff9be8b5);
    final showStatus = status != '正常';
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Container(
        decoration: BoxDecoration(
          color: current
              ? const Color(0x1A74D69B)
              : const Color(0x0EFFFFFF),
          borderRadius: BorderRadius.circular(13),
          border: Border.all(
            color: current
                ? const Color(0x8074D69B)
                : const Color(0x00FFFFFF),
            width: current ? 1.0 : .5,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
          child: Row(
            children: [
              _StatusDot(
                current: current,
                color: missing || account.hasDataAnomaly
                    ? const Color(0xffffcf8a)
                    : current
                        ? const Color(0xff74d69b)
                        : const Color(0x8AFFFFFF),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Semantics(
                  label: current ? '当前账户 ${account.displayName}' : null,
                  child: Text(
                    account.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xffe3e5e8),
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text.rich(
                TextSpan(
                  style: const TextStyle(
                    color: Color(0xffd0d3d8),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                  children: [
                    const TextSpan(text: '5h '),
                    TextSpan(
                      text: _percent(
                        account.hasDataAnomaly
                            ? null
                            : account.fiveHour?.remainingPercent,
                      ),
                      style: const TextStyle(color: Color(0xffb7e4bf)),
                    ),
                    const TextSpan(text: '  |  W '),
                    TextSpan(
                      text: _percent(
                        account.hasDataAnomaly
                            ? null
                            : account.weekly?.remainingPercent,
                      ),
                      style: const TextStyle(color: Color(0xffb7e4bf)),
                    ),
                    TextSpan(
                      text:
                          '  |  ${account.hasDataAnomaly ? '--.--' : _shortDate(account.weekly?.resetAt ?? account.fiveHour?.resetAt)}',
                      style: const TextStyle(color: Color(0xffc8cbd0)),
                    ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.clip,
              ),
              if (showStatus)
                Padding(
                  padding: const EdgeInsets.only(left: 9),
                  child: Text(
                    status,
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
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
