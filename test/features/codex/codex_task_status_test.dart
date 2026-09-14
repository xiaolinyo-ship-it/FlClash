import 'dart:io';

import 'package:fl_clash/features/codex/codex_task_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('maps the task states to the compact panel labels', () {
    expect(codexTaskStatusLabel(CodexTaskStatus.thinking), '思考中');
    expect(codexTaskStatusLabel(CodexTaskStatus.completed), '已完成');
    expect(codexTaskStatusLabel(CodexTaskStatus.unavailable), '—');
  });

  test('uses rollout modification time without reading rollout contents', () async {
    final root = await Directory.systemTemp.createTemp('flclash-task-status-');
    try {
      final rollout = File('${root.path}${Platform.pathSeparator}rollout-test.jsonl');
      await rollout.writeAsString('not parsed by the status adapter');
      final now = DateTime(2026, 9, 14, 12);
      await rollout.setLastModified(now.subtract(const Duration(seconds: 30)));
      final reader = CodexTaskStatusReader(
        sessionsRoot: root.path,
        clock: () => now,
      );

      expect(await reader.read(), CodexTaskStatus.thinking);
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('shows completed after the active window and hides stale sessions', () async {
    final root = await Directory.systemTemp.createTemp('flclash-task-status-');
    try {
      final rollout = File('${root.path}${Platform.pathSeparator}rollout-test.jsonl');
      await rollout.writeAsString('{}');
      final now = DateTime(2026, 9, 14, 12);
      final reader = CodexTaskStatusReader(
        sessionsRoot: root.path,
        clock: () => now,
      );

      await rollout.setLastModified(now.subtract(const Duration(minutes: 5)));
      expect(await reader.read(), CodexTaskStatus.completed);

      await rollout.setLastModified(now.subtract(const Duration(minutes: 31)));
      expect(await reader.read(), CodexTaskStatus.unavailable);
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('returns unavailable when the sessions directory is missing', () async {
    final reader = CodexTaskStatusReader(
      sessionsRoot: '${Directory.systemTemp.path}${Platform.pathSeparator}missing-flclash-sessions',
    );

    expect(await reader.read(), CodexTaskStatus.unavailable);
  });
}
