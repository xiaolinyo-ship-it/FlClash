import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/features/codex/codex_account_snapshot.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_ui/material_ui.dart' as material_ui;

class CodexAccounts extends StatefulWidget {
  final CodexAccountSnapshotReader? reader;
  final DateTime Function()? clock;
  final bool? isWindows;

  const CodexAccounts({
    super.key,
    @visibleForTesting this.reader,
    @visibleForTesting this.clock,
    @visibleForTesting this.isWindows,
  });

  @override
  State<CodexAccounts> createState() => _CodexAccountsState();
}

class _CodexAccountsState extends State<CodexAccounts> {
  late final CodexAccountSnapshotReader _reader;
  CodexAccountSnapshot? _snapshot;
  CodexSnapshotReadFailure? _failure;
  Set<String> _missingAccountIds = {};
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _reader = widget.reader ?? CodexAccountSnapshotReader(clock: widget.clock);
    _load();
  }

  Future<void> _load() async {
    if (_loading) {
      return;
    }
    setState(() => _loading = true);
    final result = await _reader.read();
    if (!mounted) {
      return;
    }
    final nextSnapshot = result.snapshot;
    if (nextSnapshot != null) {
      final previousIds = _snapshot?.accounts.map((item) => item.id).toSet();
      final nextIds = nextSnapshot.accounts.map((item) => item.id).toSet();
      final missing = {..._missingAccountIds};
      if (previousIds != null) {
        missing.addAll(previousIds.difference(nextIds));
      }
      missing.removeWhere(nextIds.contains);
      setState(() {
        _snapshot = nextSnapshot;
        _failure = result.failure;
        _missingAccountIds = missing;
        _loading = false;
      });
      return;
    }
    setState(() {
      _failure = result.failure ?? CodexSnapshotReadFailure.unknown;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!(widget.isWindows ?? system.isWindows)) {
      return const SizedBox.shrink();
    }
    final appLocalizations = context.appLocalizations;
    final snapshot = _snapshot;
    final failure = _failure;
    final now = widget.clock?.call() ?? DateTime.now();
    return CommonCard(
      type: CommonCardType.filled,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InfoHeader(
            padding: baseInfoEdgeInsets.copyWith(bottom: 0),
            info: Info(
              iconData: Icons.account_circle_outlined,
              label: appLocalizations.codexAccounts,
            ),
            actions: [
              IconButton(
                tooltip: appLocalizations.update,
                onPressed: _loading ? null : _load,
                icon: _loading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
              ),
            ],
          ),
          Padding(
            padding: baseInfoEdgeInsets.copyWith(top: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  appLocalizations.codexAccountsHint,
                  style: context.textTheme.bodySmall?.copyWith(
                    color: context.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                if (failure != null)
                  _CodexMessage(
                    message: _failureText(appLocalizations, failure),
                    isError: true,
                  ),
                if (snapshot != null) ...[
                  if (_missingAccountIds.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    _CodexMessage(
                      message: appLocalizations.codexAccountsMissing(
                        _missingAccountIds.length,
                      ),
                      isError: true,
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(
                    appLocalizations.codexAccountsLoaded(
                      snapshot.accounts.length,
                    ),
                    style: context.textTheme.labelMedium,
                  ),
                  if (snapshot.accounts.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(appLocalizations.codexNoAccounts),
                    )
                  else ...[
                    const SizedBox(height: 12),
                    LayoutBuilder(
                      builder: (_, constraints) {
                        final singleColumn = constraints.maxWidth < 700;
                        final width = singleColumn
                            ? constraints.maxWidth
                            : (constraints.maxWidth - 24) / 3;
                        return Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: snapshot.accounts
                              .map(
                                (account) => SizedBox(
                                  width: width,
                                  child: _CodexAccountCard(
                                    account: account,
                                    status: failure == null
                                        ? account.statusAt(now)
                                        : CodexAccountStatus.readFailed,
                                    localizations: appLocalizations,
                                  ),
                                ),
                              )
                              .toList(),
                        );
                      },
                    ),
                    const SizedBox(height: 8),
                    Text(
                      appLocalizations.codexCurrentNotConfirmed,
                      style: context.textTheme.bodySmall?.copyWith(
                        color: context.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      appLocalizations.codexSnapshotReadAt(
                        _formatDate(snapshot.readAt),
                      ),
                      style: context.textTheme.bodySmall?.copyWith(
                        color: context.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ] else if (failure != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(appLocalizations.codexNoHistoricalData),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CodexAccountCard extends StatelessWidget {
  final CodexAccountCardData account;
  final CodexAccountStatus status;
  final AppLocalizations localizations;

  const _CodexAccountCard({
    required this.account,
    required this.status,
    required this.localizations,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  account.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.textTheme.titleSmall,
                ),
              ),
              const SizedBox(width: 8),
              _CodexStatusChip(
                label: _statusText(localizations, status),
                color: _statusColor(colorScheme, status),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _CodexQuotaRow(
            label: localizations.codexFiveHour,
            window: account.fiveHour,
            localizations: localizations,
          ),
          const SizedBox(height: 10),
          _CodexQuotaRow(
            label: localizations.codexWeekly,
            window: account.weekly,
            localizations: localizations,
          ),
          const SizedBox(height: 12),
          Text(
            localizations.codexLastSuccessfulUpdate(
              _formatDate(account.updatedAt),
            ),
            style: context.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _CodexQuotaRow extends StatelessWidget {
  final String label;
  final CodexQuotaWindow? window;
  final AppLocalizations localizations;

  const _CodexQuotaRow({
    required this.label,
    required this.window,
    required this.localizations,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final currentWindow = window;
    final valid = currentWindow?.isConsistent ?? false;
    final used = currentWindow?.usedPercent;
    final remaining = currentWindow?.remainingPercent;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: context.textTheme.labelLarge),
            Text(
              valid
                  ? localizations.codexUsedRemaining(
                      _formatPercent(used),
                      _formatPercent(remaining),
                    )
                  : localizations.codexDataAnomaly,
              style: context.textTheme.bodySmall?.copyWith(
                color: valid ? colorScheme.onSurfaceVariant : colorScheme.error,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (valid)
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              minHeight: 5,
              value: (used! / 100).clamp(0, 1).toDouble(),
              backgroundColor: colorScheme.surfaceContainerHighest,
            ),
          )
        else
          Text(
            currentWindow == null
                ? localizations.codexUnavailable
                : localizations.codexDataAnomaly,
            style: context.textTheme.bodySmall?.copyWith(
              color: colorScheme.error,
            ),
          ),
        const SizedBox(height: 4),
        Text(
          localizations.codexResetAt(_formatDate(currentWindow?.resetAt)),
          style: context.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _CodexStatusChip extends StatelessWidget {
  final String label;
  final Color color;

  const _CodexStatusChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.opacity12,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: context.textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}

class _CodexMessage extends StatelessWidget {
  final String message;
  final bool isError;

  const _CodexMessage({required this.message, required this.isError});

  @override
  Widget build(BuildContext context) {
    final color = isError
        ? context.colorScheme.error
        : context.colorScheme.onSurfaceVariant;
    return Text(
      message,
      style: context.textTheme.bodySmall?.copyWith(color: color),
    );
  }
}

String _formatPercent(double? value) =>
    value == null ? '-' : '${value.round()}%';

String _formatDate(DateTime? value) =>
    value == null ? '-' : DateFormat('yyyy-MM-dd HH:mm').format(value);

String _failureText(
  AppLocalizations localizations,
  CodexSnapshotReadFailure failure,
) {
  return switch (failure) {
    CodexSnapshotReadFailure.fileUnavailable => localizations.codexReadFailed,
    CodexSnapshotReadFailure.invalidJson => localizations.codexInvalidSnapshot,
    CodexSnapshotReadFailure.invalidShape => localizations.codexInvalidSnapshot,
    CodexSnapshotReadFailure.unsupportedPlatform =>
      localizations.codexUnsupportedPlatform,
    CodexSnapshotReadFailure.unknown => localizations.codexReadFailed,
  };
}

String _statusText(AppLocalizations localizations, CodexAccountStatus status) {
  return switch (status) {
    CodexAccountStatus.normal => localizations.codexNormal,
    CodexAccountStatus.exhausted => localizations.codexExhausted,
    CodexAccountStatus.expired => localizations.codexExpired,
    CodexAccountStatus.dataAnomaly => localizations.codexDataAnomaly,
    CodexAccountStatus.readFailed => localizations.codexReadFailed,
  };
}

Color _statusColor(
  material_ui.ColorScheme colorScheme,
  CodexAccountStatus status,
) {
  return switch (status) {
    CodexAccountStatus.normal => colorScheme.primary,
    CodexAccountStatus.exhausted => colorScheme.error,
    CodexAccountStatus.expired => colorScheme.tertiary,
    CodexAccountStatus.dataAnomaly => colorScheme.error,
    CodexAccountStatus.readFailed => colorScheme.error,
  };
}
