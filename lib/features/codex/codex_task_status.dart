import 'dart:io';

import 'package:path/path.dart' as path;

enum CodexTaskStatus {
  thinking,
  completed,
  unavailable,
}

class CodexTaskStatusReader {
  static const activeWindow = Duration(seconds: 120);
  static const completedWindow = Duration(minutes: 30);

  final String? sessionsRoot;
  final DateTime Function() clock;

  CodexTaskStatusReader({
    this.sessionsRoot,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  Future<CodexTaskStatus> read() async {
    final root = sessionsRoot ?? _defaultSessionsRoot();
    if (root == null || root.isEmpty) {
      return CodexTaskStatus.unavailable;
    }

    DateTime? latestActivity;
    try {
      final directory = Directory(root);
      if (!await directory.exists()) {
        return CodexTaskStatus.unavailable;
      }
      await for (final entity in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) {
          continue;
        }
        final name = path.basename(entity.path).toLowerCase();
        if (!name.startsWith('rollout-') || !name.endsWith('.jsonl')) {
          continue;
        }
        final modified = (await entity.stat()).modified;
        if (latestActivity == null || modified.isAfter(latestActivity!)) {
          latestActivity = modified;
        }
      }
    } catch (_) {
      return CodexTaskStatus.unavailable;
    }

    if (latestActivity == null) {
      return CodexTaskStatus.unavailable;
    }
    final age = clock().difference(latestActivity!);
    if (age <= activeWindow) {
      return CodexTaskStatus.thinking;
    }
    if (age <= completedWindow) {
      return CodexTaskStatus.completed;
    }
    return CodexTaskStatus.unavailable;
  }

  static String? _defaultSessionsRoot() {
    final codexHome = Platform.environment['CODEX_HOME'];
    if (codexHome != null && codexHome.isNotEmpty) {
      return path.join(codexHome, 'sessions');
    }
    final userProfile = Platform.environment['USERPROFILE'];
    if (userProfile == null || userProfile.isEmpty) {
      return null;
    }
    return path.join(userProfile, '.codex', 'sessions');
  }
}

String codexTaskStatusLabel(CodexTaskStatus status) {
  return switch (status) {
    CodexTaskStatus.thinking => '思考中',
    CodexTaskStatus.completed => '已完成',
    CodexTaskStatus.unavailable => '—',
  };
}
