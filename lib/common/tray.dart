import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/features/codex/codex_account_switcher.dart';
import 'package:fl_clash/features/codex/codex_account_snapshot.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:tray/tray.dart';

import 'app_localizations.dart';
import 'l10n_labels.dart';
import 'app_ports.dart';
import 'constant.dart';
import 'provider_reader.dart';
import 'system.dart';
import 'window.dart';

class AppTray implements TrayPort {
  static AppTray? _instance;

  final bool isMacOS;
  final bool isWindows;

  bool _isShutDown = false;
  bool _codexSwitching = false;
  TrayState? _lastTrayState;
  Traffic? _lastTraffic;
  ProviderReader? _lastReader;

  AppTray._internal({required this.isMacOS, required this.isWindows});

  factory AppTray() {
    _instance ??= AppTray._internal(
      isMacOS: system.isMacOS,
      isWindows: system.isWindows,
    );
    return _instance!;
  }

  @visibleForTesting
  factory AppTray.forPlatform({
    required bool isMacOS,
    required bool isWindows,
  }) {
    return AppTray._internal(isMacOS: isMacOS, isWindows: isWindows);
  }

  String get _trayIconSuffix {
    return isWindows ? 'ico' : 'png';
  }

  String get _trayIconDir {
    return isWindows ? 'assets/images/tray/windows' : 'assets/images/tray/unix';
  }

  String getTrayIcon({required bool isStart, required bool tunEnable}) {
    final status = switch ((isMacOS || !isStart, tunEnable)) {
      (true, _) => 1,
      (false, false) => 2,
      (false, true) => 3,
    };
    return '$_trayIconDir/status_$status.$_trayIconSuffix';
  }

  @override
  Future<void> shutdown() async {
    _isShutDown = true;
    await Tray.instance.hide();
  }

  @override
  Future<void> update({
    required TrayState trayState,
    required Traffic traffic,
    required ProviderReader read,
  }) async {
    if (_isShutDown) {
      return;
    }
    _lastTrayState = trayState;
    _lastTraffic = traffic;
    _lastReader = read;
    final codex = await CodexAccountSnapshotReader().read();
    await Tray.instance.show(
      TraySpec(
        icon: TrayIcon.asset(
          getTrayIcon(
            isStart: trayState.isStart,
            tunEnable: trayState.tunEnable,
          ),
          isTemplate: isMacOS,
        ),
        toolTip: _trayToolTip(codex),
        menu: _buildMenu(trayState: trayState, read: read, codex: codex),
      ),
    );
    await updateTitle(showTrayTitle: trayState.showTrayTitle, traffic: traffic);
  }

  Future<void> updateTitle({
    required bool showTrayTitle,
    required Traffic traffic,
  }) async {
    if (_isShutDown || !isMacOS) {
      return;
    }
    await Tray.instance.setTitle(showTrayTitle ? traffic.trayTitle : '');
  }

  List<TrayMenuItem> _buildMenu({
    required TrayState trayState,
    required ProviderReader read,
    required CodexSnapshotReadResult codex,
  }) {
    final commonAction = read(commonActionProvider.notifier);
    final systemAction = read(systemActionProvider.notifier);
    final setupAction = read(setupActionProvider.notifier);
    final appLocalizations = currentAppLocalizations;

    return [
      TrayMenuAction(
        label: appLocalizations.show,
        onSelected: () {
          window?.show();
        },
      ),
      TrayMenuCheckbox(
        label: trayState.isStart
            ? appLocalizations.stop
            : appLocalizations.start,
        checked: false,
        onSelected: commonAction.toggleRunning,
      ),
      if (isMacOS)
        TrayMenuCheckbox(
          label: appLocalizations.speedStatistics,
          checked: trayState.showTrayTitle,
          onSelected: commonAction.updateSpeedStatistics,
        ),
      ..._buildCodexMenu(codex),
      const TrayMenuSeparator(),
      for (final mode in Mode.values)
        TrayMenuCheckbox(
          label: mode.label,
          checked: mode == trayState.mode,
          onSelected: () {
            setupAction.changeMode(mode);
          },
        ),
      const TrayMenuSeparator(),
      if (isMacOS) ..._buildGroupMenu(trayState: trayState, read: read),
      if (trayState.isStart) ...[
        TrayMenuCheckbox(
          label: appLocalizations.tun,
          checked: trayState.tunEnable,
          onSelected: systemAction.updateTun,
        ),
        TrayMenuCheckbox(
          label: appLocalizations.systemProxy,
          checked: trayState.systemProxy,
          onSelected: systemAction.updateSystemProxy,
        ),
        const TrayMenuSeparator(),
      ],
      TrayMenuCheckbox(
        label: appLocalizations.autoLaunch,
        checked: trayState.autoLaunch,
        onSelected: systemAction.updateAutoLaunch,
      ),
      TrayMenuAction(
        label: appLocalizations.copyEnvVar,
        onSelected: () {
          _copyEnv(trayState.port);
        },
      ),
      const TrayMenuSeparator(),
      TrayMenuAction(
        label: appLocalizations.exit,
        onSelected: () {
          systemAction.handleExit();
        },
      ),
    ];
  }

  List<TrayMenuItem> _buildCodexMenu(CodexSnapshotReadResult result) {
    final snapshot = result.snapshot;
    if (snapshot == null || snapshot.accounts.isEmpty) {
      return const [];
    }
    final currentConfirmed = snapshot.currentConfirmed;
    return [
      TrayMenuAction(
        label: currentConfirmed ? 'Codex 账户（单击切换）' : 'Codex 账户（当前账户未确认）',
        enabled: false,
      ),
      for (final account in snapshot.accounts)
        TrayMenuCheckbox(
          label: _trayAccountLabel(
            account,
            currentConfirmed: currentConfirmed,
            readFailed: result.missingAccountIds.contains(account.id),
          ),
          checked: currentConfirmed && account.isCurrent,
          enabled: !result.missingAccountIds.contains(account.id),
          onSelected: () {
            unawaited(_switchCodexAccount(account.id));
          },
        ),
    ];
  }

  String _trayToolTip(CodexSnapshotReadResult result) {
    final snapshot = result.snapshot;
    if (snapshot == null || snapshot.accounts.isEmpty) {
      return appName;
    }
    final first = snapshot.accounts
        .take(3)
        .map(
          (account) => _trayAccountLabel(
            account,
            currentConfirmed: snapshot.currentConfirmed,
          ),
        )
        .join('\n');
    return '$appName\n$first';
  }

  Future<void> _switchCodexAccount(String accountId) async {
    if (_codexSwitching || _isShutDown) {
      return;
    }
    _codexSwitching = true;
    try {
      final result = await CodexAccountSwitcher().switchTo(accountId);
      if (!result.switched) {
        commonPrint.log(
          'Codex account switch skipped: ${result.failure ?? 'unknown reason'}',
          logLevel: LogLevel.warning,
        );
        return;
      }
      commonPrint.log('Codex account switched; desktop restart scheduled');
      await Future<void>.delayed(const Duration(seconds: 1));
      final trayState = _lastTrayState;
      final traffic = _lastTraffic;
      final read = _lastReader;
      if (trayState != null && traffic != null && read != null) {
        await update(trayState: trayState, traffic: traffic, read: read);
      }
    } catch (error) {
      commonPrint.log(
        'Codex account switch failed: ${compactError(error)}',
        logLevel: LogLevel.error,
      );
    } finally {
      _codexSwitching = false;
    }
  }

  List<TrayMenuItem> _buildGroupMenu({
    required TrayState trayState,
    required ProviderReader read,
  }) {
    if (trayState.groups.isEmpty) {
      return const [];
    }
    return [
      for (final group in trayState.groups)
        TrayMenuSubmenu(
          label: group.name,
          items: [
            for (final proxy in group.all)
              TrayMenuCheckbox(
                label: proxy.name,
                checked:
                    read(selectedProxyNameProvider(group.name)) == proxy.name,
                onSelected: () {
                  read(
                    proxiesActionProvider.notifier,
                  ).changeProxy(groupName: group.name, proxyName: proxy.name);
                },
              ),
          ],
        ),
      const TrayMenuSeparator(),
    ];
  }

  Future<void> _copyEnv(int port) async {
    final url = 'http://127.0.0.1:$port';

    final cmdline = isWindows
        ? 'set \$env:all_proxy=$url'
        : 'export all_proxy=$url';

    await Clipboard.setData(ClipboardData(text: cmdline));
  }
}

String _trayAccountLabel(
  CodexAccountCardData account, {
  required bool currentConfirmed,
  bool readFailed = false,
}) {
  final weekly = _trayPercent(account.weekly?.remainingPercent);
  final fiveHour = _trayPercent(account.fiveHour?.remainingPercent);
  final current = account.isCurrent
      ? (currentConfirmed ? '（当前）' : '（当前未确认）')
      : '';
  final status = readFailed ? '读取失败' : _trayStatus(account);
  final reset = _trayDate(account.weekly?.resetAt ?? account.fiveHour?.resetAt);
  return '${account.displayName}$current  5h $fiveHour | W $weekly | $reset  $status';
}

String _trayPercent(double? value) =>
    value == null ? '未提供' : '${value.round()}%';

String _trayDate(DateTime? value) {
  if (value == null) {
    return '重置 —';
  }
  final local = value.toLocal();
  return '重置 ${local.month.toString().padLeft(2, '0')}.${local.day.toString().padLeft(2, '0')}';
}

String _trayStatus(CodexAccountCardData account) {
  return switch (account.statusAt(DateTime.now())) {
    CodexAccountStatus.normal => '正常',
    CodexAccountStatus.exhausted => '已用尽',
    CodexAccountStatus.expired => '数据过期',
    CodexAccountStatus.dataAnomaly => '数据异常',
    CodexAccountStatus.readFailed => '读取失败',
  };
}

final appTray = system.isDesktop ? AppTray() : null;
