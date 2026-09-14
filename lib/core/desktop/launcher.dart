import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';

import 'model.dart';
import 'process_probe.dart';

typedef CoreProcessStarter =
    Future<Process> Function(String executable, List<String> arguments);

abstract interface class CoreProcessLauncher {
  Future<CoreProcessLease> start({
    required String sessionId,
    required String address,
  });
}

abstract interface class DesktopCoreLauncherResolver {
  Future<CoreProcessLauncher> resolve();
}

final class DirectCoreLauncher implements CoreProcessLauncher {
  final CoreProcessStarter _startProcess;
  final String corePath;
  final bool _detached;

  DirectCoreLauncher({CoreProcessStarter? startProcess, String? corePath})
    : _startProcess = startProcess ?? _startDetachedCore,
      corePath = corePath ?? appPath.corePath,
      _detached = startProcess == null;

  @override
  Future<CoreProcessLease> start({
    required String sessionId,
    required String address,
  }) async {
    final process = await _startProcess(corePath, [address]);
    process.stdout.listen((_) {});
    process.stderr.listen((data) {
      final error = utf8.decode(data);
      if (error.isNotEmpty) {
        commonPrint.log(error, logLevel: LogLevel.warning);
      }
    });
    return DirectCoreLease(
      sessionId: sessionId,
      process: process,
      detached: _detached,
    );
  }
}

Future<Process> _startDetachedCore(String executable, List<String> arguments) {
  // FlClashCore.exe is a Windows CUI binary. Detaching it prevents Windows
  // from creating a console window whose close event would terminate the
  // core and, in turn, make the main FlClash window lose its proxy session.
  // Stdio remains connected so the existing diagnostic listeners continue to
  // work.
  return Process.start(
    executable,
    arguments,
    mode: ProcessStartMode.detachedWithStdio,
  );
}

final class DirectCoreLease implements CoreProcessLease {
  @override
  final String sessionId;

  final Process _process;
  final bool _detached;
  Future<CoreProcessStopResult>? _stopOperation;

  DirectCoreLease({
    required this.sessionId,
    required Process process,
    bool detached = false,
  }) : _process = process,
       _detached = detached;

  @override
  CoreProcessOwner get owner => CoreProcessOwner.direct;

  @override
  int get pid => _process.pid;

  @override
  Future<CoreProcessStopResult> stop(Duration timeout) {
    final stopOperation = _stopOperation;
    if (stopOperation != null) {
      return stopOperation;
    }
    final nextOperation = _stop(timeout).then((result) {
      if (!result.exitConfirmed) {
        _stopOperation = null;
      }
      return result;
    });
    _stopOperation = nextOperation;
    return nextOperation;
  }

  Future<CoreProcessStopResult> _stop(Duration timeout) async {
    final stopped = _process.kill();
    if (_detached) {
      final deadline = DateTime.now().add(timeout);
      do {
        if (!await isProcessAlive(_process.pid)) {
          return CoreProcessStopResult(stopped: stopped, exitConfirmed: true);
        }
        if (DateTime.now().isAfter(deadline)) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      } while (true);
      return CoreProcessStopResult(stopped: stopped, exitConfirmed: false);
    }
    try {
      await _process.exitCode.timeout(timeout);
      return CoreProcessStopResult(stopped: stopped, exitConfirmed: true);
    } on TimeoutException {
      return CoreProcessStopResult(stopped: stopped, exitConfirmed: false);
    }
  }
}
