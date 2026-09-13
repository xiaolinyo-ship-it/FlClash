// coverage:ignore-file

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:fl_clash/features/codex/codex_account_snapshot.dart';
import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as path;
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

const codexTaskbarPanelArgument = '--codex-panel';
const codexTaskbarPanelPreviewArgument = '--codex-panel-preview';

// These are logical pixels. CodexBar uses a transparent 360x36 FloatBar
// window and a 324x120 account popup. The native panel is parked inside the
// taskbar strip; only its compact pill is painted in the lower 36 px.
const _panelWidth = 360.0;
const _popupWidth = 324.0;
const _pillWidth = 196.0;
const _collapsedHeight = 36.0;
const _pillHeight = 20.0;
const _popupHeight = 120.0;
const _panelGap = 4.0;
const _expandedHeight = _popupHeight + _panelGap + _collapsedHeight;
const _screenInset = 8.0;
const _positionFileName = 'codex-taskbar-panel-position.json';
const _positionSchemaVersion = 2;

bool isCodexTaskbarPanel(List<String> args) =>
    args.contains(codexTaskbarPanelArgument) ||
    args.contains(codexTaskbarPanelPreviewArgument);

bool isCodexTaskbarPanelPreview(List<String> args) =>
    args.contains(codexTaskbarPanelPreviewArgument);

abstract final class CodexTaskbarPanelRuntime {
  static RandomAccessFile? _lockFile;

  static Future<void> run({bool preview = false}) async {
    if (!Platform.isWindows) {
      return;
    }
    if (!await _acquireLock()) {
      return;
    }
    await windowManager.ensureInitialized();
    final initialHeight = preview ? _expandedHeight : _collapsedHeight;
    final captureKey = preview ? GlobalKey() : null;
    final previewReader = preview
        ? CodexAccountSnapshotReader(snapshotPath: _previewSnapshotPath())
        : null;
    final options = WindowOptions(
      size: Size(_panelWidth, initialHeight),
      minimumSize: const Size(_panelWidth, _collapsedHeight),
      maximumSize: const Size(_panelWidth, _expandedHeight),
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
    await windowManager.setResizable(false);
    await _placeInitialWindow(initialHeight);
    runApp(
      CodexTaskbarPanelApp(
        initialExpanded: preview,
        captureKey: captureKey,
        reader: previewReader,
      ),
    );
    await WidgetsBinding.instance.endOfFrame;
    await windowManager.setSize(Size(_panelWidth, initialHeight));
    await windowManager.show();
    await windowManager.focus();
    await windowManager.setAlwaysOnTop(true);
    if (preview && captureKey != null) {
      await WidgetsBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await _capturePreview(captureKey);
    }
  }

  static String? _previewSnapshotPath() {
    final appData = Platform.environment['APPDATA'];
    if (appData == null || appData.isEmpty) {
      return null;
    }
    return path.join(appData, 'CodexBar', 'codex-accounts', 'snapshots.json');
  }

  static Future<void> _capturePreview(GlobalKey key) async {
    final context = key.currentContext;
    if (context == null) {
      return;
    }
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderRepaintBoundary) {
      return;
    }
    final pixelRatio = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1;
    final image = await renderObject.toImage(pixelRatio: pixelRatio);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final output = Platform.environment['FLCLASH_CODEX_PANEL_CAPTURE_PATH'];
      if (data == null || output == null || output.isEmpty) {
        return;
      }
      final file = File(output);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
    } catch (error) {
      debugPrint('Codex taskbar panel preview capture failed: $error');
    } finally {
      image.dispose();
    }
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
    const width = _panelWidth;
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
        jsonEncode({
          'version': _positionSchemaVersion,
          'x': position.dx,
          'y': position.dy,
        }),
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
            panelSize: Size(_panelWidth, height),
            height: height,
            inset: _screenInset,
          )
        : codexTaskbarPanelClampPosition(
            workArea: workArea,
            panelSize: Size(_panelWidth, height),
            position: savedPosition,
            inset: _screenInset,
          );
    await windowManager.setPosition(position);
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
      final version = (value['version'] as num?)?.toInt();
      if (version != _positionSchemaVersion) {
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
    // Use the full monitor bounds, not visibleSize. The old CodexBar taskbar
    // style deliberately occupies the reserved Windows taskbar strip.
    final size = display.size;
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
  final bool initialExpanded;
  final GlobalKey? captureKey;
  final CodexAccountSnapshotReader? reader;

  const CodexTaskbarPanelApp({
    super.key,
    this.initialExpanded = false,
    this.captureKey,
    this.reader,
  });

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
      home: CodexTaskbarPanel(
        initialExpanded: initialExpanded,
        captureKey: captureKey,
        reader: reader,
      ),
    );
  }
}

class CodexTaskbarPanel extends StatefulWidget {
  final CodexAccountSnapshotReader? reader;
  final DateTime Function()? clock;
  final bool initialExpanded;
  final GlobalKey? captureKey;

  const CodexTaskbarPanel({
    super.key,
    @visibleForTesting this.reader,
    @visibleForTesting this.clock,
    this.initialExpanded = false,
    this.captureKey,
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
  late bool _expanded = widget.initialExpanded;
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
    return RepaintBoundary(
      key: widget.captureKey,
      child: MouseRegion(
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
      ),
    );
  }

  Widget _buildCollapsed(BuildContext context, CodexAccountCardData? current) {
    return _buildPill(current);
  }

  Widget _buildPill(CodexAccountCardData? current) {
    final fiveHour = current?.fiveHour?.remainingPercent;
    final weekly = current?.weekly?.remainingPercent;
    final reset = current?.hasDataAnomaly == true
        ? '--.--'
        : _shortDate(current?.weekly?.resetAt ?? current?.fiveHour?.resetAt);
    return Align(
      alignment: Alignment.center,
      child: SizedBox(
        width: _pillWidth,
        height: _pillHeight,
        child: _PanelSurface(
          popup: false,
          padding: const EdgeInsets.symmetric(horizontal: 8),
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
    final accounts = snapshot?.accounts ?? const <CodexAccountCardData>[];
    CodexAccountCardData? current;
    if (snapshot != null && snapshot.currentConfirmed) {
      current = snapshot.accounts
          .where((account) => account.isCurrent)
          .firstOrNull;
    }
    return Stack(
      alignment: Alignment.bottomCenter,
      children: [
        Positioned(
          top: 0,
          width: _popupWidth,
          left: (_panelWidth - _popupWidth) / 2,
          height: _popupHeight,
          child: _PanelSurface(
            popup: true,
            padding: const EdgeInsets.fromLTRB(3, 4, 3, 4),
            onDrag: _startDragging,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (accounts.isEmpty)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(7, 7, 7, 6),
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
                if (_failure != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(7, 2, 7, 0),
                      child: Text(
                        _failureText(_failure!),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xffffcf8a),
                          fontSize: 8,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        Positioned(
          bottom: 0,
          width: _panelWidth,
          height: _collapsedHeight,
          child: _buildPill(current),
        ),
      ],
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
    final surface = Container(
      width: double.infinity,
      height: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.all(Radius.circular(popup ? 12 : 7)),
        boxShadow: popup
            ? const [
                BoxShadow(
                  blurRadius: 24,
                  offset: Offset(0, 8),
                  color: Color(0x5C000000),
                ),
                BoxShadow(
                  blurRadius: 0,
                  spreadRadius: 1,
                  color: Color(0x3DFFFFFF),
                ),
              ]
            : const [
                BoxShadow(
                  blurRadius: 2,
                  offset: Offset(0, 1),
                  color: Color(0x380E2A3E),
                ),
              ],
      ),
      child: MouseRegion(
        cursor: onDrag == null ? MouseCursor.defer : SystemMouseCursors.grab,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: onDrag == null ? null : (_) => unawaited(onDrag!()),
          child: ClipRRect(
            borderRadius: BorderRadius.all(Radius.circular(popup ? 12 : 7)),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: Container(
                padding: padding,
                decoration: BoxDecoration(
                  color: popup
                      ? const Color(0xF5171F2B)
                      : const Color(0x14FFFFFF),
                  borderRadius: BorderRadius.all(
                    Radius.circular(popup ? 12 : 7),
                  ),
                  border: Border.all(
                    color: popup
                        ? const Color(0xADFFFFFF)
                        : const Color(0x38FFFFFF),
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
    return Opacity(opacity: popup ? 0.8 : 1, child: surface);
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
    return Row(
      children: [
        _StatusDot(
          current: account != null && account!.isCurrent,
          color: const Color(0xadffffff),
        ),
        const SizedBox(width: 2),
        Expanded(
          child: Text.rich(
            TextSpan(
              style: const TextStyle(
                color: Color(0xf2ffffff),
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
              children: [
                const TextSpan(text: '5h '),
                TextSpan(
                  text: _percent(fiveHour),
                  style: const TextStyle(color: Color(0xff9be8b5)),
                ),
                const TextSpan(text: ' | W '),
                TextSpan(
                  text: _percent(weekly),
                  style: const TextStyle(color: Color(0xff9be8b5)),
                ),
                TextSpan(
                  text: ' | $reset',
                  style: const TextStyle(color: Color(0xb8ffffff)),
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (loading)
          const Padding(
            padding: EdgeInsets.only(left: 5),
            child: SizedBox(
              width: 10,
              height: 10,
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
      width: 5,
      height: 5,
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
      padding: const EdgeInsets.only(top: 2),
      child: Container(
        decoration: BoxDecoration(
          color: current ? const Color(0x1A74D69B) : const Color(0x0EFFFFFF),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: current ? const Color(0x8074D69B) : const Color(0x00FFFFFF),
            width: current ? 1.0 : .5,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 8),
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
              const SizedBox(width: 5),
              Expanded(
                child: Semantics(
                  label: current ? '当前账户 ${account.displayName}' : null,
                  child: Text(
                    account.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xffe3e5e8),
                      fontSize: 10,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text.rich(
                TextSpan(
                  style: const TextStyle(
                    color: Color(0xffd0d3d8),
                    fontSize: 10,
                    fontWeight: FontWeight.w400,
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
                    const TextSpan(text: ' | W '),
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
                          ' | ${account.hasDataAnomaly ? '--.--' : _shortDate(account.weekly?.resetAt ?? account.fiveHour?.resetAt)}',
                      style: const TextStyle(color: Color(0xffc8cbd0)),
                    ),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.clip,
              ),
              if (showStatus)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Text(
                    status,
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 8,
                      fontWeight: FontWeight.w400,
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
