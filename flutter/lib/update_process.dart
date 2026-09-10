import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart' as win;

Future<String?> linuxProcessIdentity(int processId) async {
  try {
    final stat = await File('/proc/$processId/stat').readAsString();
    final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
    return fields.first == 'Z' ? null : fields[19];
  } on FileSystemException {
    return null;
  }
}

Future<String?> processIdentity(int processId) async {
  if (!Platform.isWindows) return linuxProcessIdentity(processId);
  final process = _WindowsProcess.open(processId);
  try {
    return process?.running == true ? process!.identity : null;
  } finally {
    process?.close();
  }
}

Future<void> stopUpdateProcess(int processId, String identity) async {
  if (Platform.isWindows) {
    final process = _WindowsProcess.open(processId, terminate: true);
    try {
      if (process == null || !process.running || process.identity != identity) {
        return;
      }
      process.terminate();
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (process.running) {
        if (DateTime.now().isAfter(deadline)) {
          throw const FileSystemException(
            'The updated application did not exit.',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    } finally {
      process?.close();
    }
  } else if (await processIdentity(processId) == identity) {
    Process.killPid(processId, ProcessSignal.sigkill);
  }
}

class _WindowsProcess {
  _WindowsProcess(this.handle);
  final win.HANDLE handle;

  static _WindowsProcess? open(int pid, {bool terminate = false}) {
    if (pid <= 0) throw const FormatException('Invalid application process.');
    var access =
        win.PROCESS_QUERY_LIMITED_INFORMATION | win.PROCESS_SYNCHRONIZE;
    if (terminate) access |= win.PROCESS_TERMINATE;
    final result = win.OpenProcess(access, false, pid);
    if (result.value.address != 0) return _WindowsProcess(result.value);
    if (result.error == win.ERROR_INVALID_PARAMETER) return null;
    throw FileSystemException(
      'Could not inspect the application process.',
      '',
      OSError('OpenProcess', result.error),
    );
  }

  bool get running {
    final result = win.WaitForSingleObject(handle, 0);
    if (result.value == win.WAIT_OBJECT_0) return false;
    if (result.value == win.WAIT_TIMEOUT) return true;
    throw FileSystemException(
      'Could not wait for the application.',
      '',
      OSError('WaitForSingleObject', result.error),
    );
  }

  String get identity {
    final times = calloc<win.FILETIME>(4);
    try {
      final result = win.GetProcessTimes(
        handle,
        times,
        times + 1,
        times + 2,
        times + 3,
      );
      if (!result.value) {
        throw FileSystemException(
          'Could not identify the application.',
          '',
          OSError('GetProcessTimes', result.error),
        );
      }
      return ((times.ref.dwHighDateTime << 32) | times.ref.dwLowDateTime)
          .toString();
    } finally {
      calloc.free(times);
    }
  }

  void terminate() {
    final result = win.TerminateProcess(handle, 1);
    if (!result.value && running) {
      throw FileSystemException(
        'Could not stop the updated application.',
        '',
        OSError('TerminateProcess', result.error),
      );
    }
  }

  void close() {
    win.CloseHandle(handle);
  }
}
