import 'package:fl_clash/enum/enum.dart';
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
      return [
        const TrayMenuSubmenu(
          label: 'Codex：额度不可用',
          items: <TrayMenuItem>[],
        ),
      ];
    }
    return [
      TrayMenuSubmenu(
        label: 'Codex：${snapshot.accounts.length} 个账户',
        items: [
          for (final account in snapshot.accounts)
            TrayMenuAction(
              label: _trayAccountLabel(account),
              enabled: false,
            ),
        ],
      ),
    ];
  }

  String _trayToolTip(CodexSnapshotReadResult result) {
    final snapshot = result.snapshot;
    if (snapshot == null || snapshot.accounts.isEmpty) {
      return '$appName\nCodex：额度不可用';
    }
    final first = snapshot.accounts.take(3).map(_trayAccountLabel).join('\n');
    return '$appName\n$first';
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

String _trayAccountLabel(CodexAccountCardData account) {
  final weekly = _trayPercent(account.weekly?.remainingPercent);
  final monthly = _trayPercent(account.monthly?.remainingPercent);
  final current = account.isCurrent ? '（当前）' : '';
  return '${account.displayName}$current  周余$weekly  月余$monthly';
}

String _trayPercent(double? value) =>
    value == null ? '未提供' : '${value.round()}%';

final appTray = system.isDesktop ? AppTray() : null;
