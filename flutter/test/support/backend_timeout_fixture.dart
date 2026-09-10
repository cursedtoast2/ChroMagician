import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  Timer(const Duration(seconds: 10), () => exit(19));
  final mode = arguments[arguments.indexOf('--port') + 1];
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  stdout.writeln(jsonEncode({'event': 'started', 'port': socket.port}));
  await stdout.flush();
  if (!arguments.contains('--firmware-info')) {
    await Future<void>.delayed(const Duration(seconds: 1));
    stdout.writeln('{"event":"complete"}');
    await stdout.flush();
    exit(0);
  }
  if (mode == 'success' || mode == 'complete-but-alive') {
    stdout.writeln(
      jsonEncode({
        'event': 'firmware_info',
        'version': {'mcu': 'v0.13.4', 'fpga': '18.8', 'chromatic': 'v4.2'},
      }),
    );
    stdout.writeln('{"event":"complete"}');
    await stdout.flush();
    if (mode == 'success') exit(0);
    await stdout.close();
    await stderr.close();
  } else if (mode == 'chatter') {
    Timer.periodic(const Duration(milliseconds: 50), (_) {
      stdout.writeln('{"event":"waiting"}');
    });
  }
  await Completer<void>().future;
}
