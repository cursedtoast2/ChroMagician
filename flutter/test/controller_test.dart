import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:chromatic_pc_backup/backend.dart';
import 'package:chromatic_pc_backup/controller.dart';
import 'package:chromatic_pc_backup/catalog.dart';

const crystal = <String, dynamic>{
  'title': 'PM_CRYSTAL',
  'color': true,
  'cartridge_type': 16,
  'rom_size': 2097152,
  'save_size': 32768,
  'rtc_expected': true,
  'rom_writable': true,
};

class FakeBackend extends CartBackend {
  List<String> connected = ['/dev/ttyTEST'];
  final calls = <List<String>>[];
  Stream<BackendEvent> Function()? transfer;
  Stream<BackendEvent> Function()? inspection;
  Map<String, String>? firmware = {
    'chromatic': '4.2 CM',
    'mcu': 'v0.13.4',
    'fpga': '18.10',
  };
  int firmwareReads = 0;
  Future<Map<String, String>?> Function()? firmwareQuery;
  @override
  Future<Map<String, String>?> firmwareInfo(
    String port, {
    bool afterFlash = false,
    Map<String, String>? expectedVersion,
  }) async {
    if (afterFlash) throw StateError('Discovery must not restart the MCU');
    firmwareReads++;
    return firmwareQuery == null ? firmware : await firmwareQuery!();
  }

  @override
  Future<List<String>> devices() async => connected;
  @override
  Stream<BackendEvent> run(List<String> arguments) {
    calls.add(arguments);
    if (arguments.contains('--inspect')) {
      return inspection?.call() ??
          Stream.fromIterable([
            {'event': 'cartridge_inspected', 'cartridge': crystal},
            {'event': 'complete'},
          ]);
    }
    return transfer?.call() ??
        Stream.fromIterable([
          {'event': 'complete'},
        ]);
  }
}

void main() {
  test('backup names use the catalog release name and share a save stem', () {
    final c = CartController(FakeBackend())
      ..port = '/dev/ttyTEST'
      ..cartridge = crystal
      ..game = const GameMetadata(
        {'title': "The Legend of Zelda: Link's Awakening DX"},
        releaseName:
            "Legend of Zelda, The - Link's Awakening DX (USA, Europe) (Rev 1) (SGB Enhanced)",
      );
    addTearDown(c.dispose);
    expect(
      c.suggestedName,
      "Legend of Zelda, The - Link's Awakening DX (USA, Europe) (Rev 1) (SGB Enhanced).gbc",
    );
    c.selectAction(CartAction.backupSave);
    expect(
      c.suggestedName,
      "Legend of Zelda, The - Link's Awakening DX (USA, Europe) (Rev 1) (SGB Enhanced).sav",
    );
    c.selectAction(CartAction.backupGame);
    c.cartridge = {...crystal, 'color': false};
    expect(c.suggestedName, endsWith('.gb'));
  });

  test(
    'filename fallbacks preserve readable names and exclude invalid path characters',
    () {
      final c = CartController(FakeBackend())
        ..cartridge = {...crystal, 'color': false};
      addTearDown(c.dispose);
      c.game = const GameMetadata({'title': 'Pokémon Crystal Version'});
      expect(c.suggestedName, 'Pokémon Crystal Version.gb');
      c.game = null;
      expect(c.suggestedName, 'PM_CRYSTAL.gb');
      for (final entry in <String, String>{
        '': 'cartridge.gb',
        '  ': 'cartridge.gb',
        '../Game/Save:File?*': '.._Game_Save_File__.gb',
        'CON': '_CON.gb',
        'Title... ': 'Title.gb',
      }.entries) {
        c.cartridge = {...c.cartridge!, 'title': entry.key};
        expect(c.suggestedName, entry.value);
      }
      c.game = GameMetadata({'title': 'あ' * 100});
      expect(utf8.encode(c.suggestedName).length, lessThanOrEqualTo(255));
      expect(c.suggestedName, '${'あ' * 80}.gb');
    },
  );

  test(
    'discovers, inspects, and forgets cartridge on USB disconnect',
    () async {
      final backend = FakeBackend();
      final c = CartController(backend);
      addTearDown(c.dispose);
      await c.refreshDevices();
      expect(c.title, 'PM_CRYSTAL');
      expect(c.cartridge!['rtc_expected'], true);
      expect(c.cartridge!.containsKey('has_rtc'), false);
      backend.connected = [];
      await c.refreshDevices();
      expect(c.port, null);
      expect(c.cartridge, null);
      expect(c.canStart, false);
    },
  );

  test(
    'file paths stay whole; restoration includes RTC automatically and overwrite is explicit',
    () async {
      final backend = FakeBackend();
      final c = CartController(backend)..port = '/dev/ttyTEST';
      addTearDown(c.dispose);
      c.selectAction(CartAction.restoreSave);
      c.chooseFile('/tmp/a save with spaces.sav');
      await c.transfer();
      expect(backend.calls.single, [
        '--write-sav',
        '/tmp/a save with spaces.sav',
        '--port',
        '/dev/ttyTEST',
        '--yes',
      ]);
      expect(backend.calls.last, isNot(contains('--save-only')));
      c.selectAction(CartAction.backupSave);
      c.chooseFile('/tmp/output.sav');
      await c.transfer();
      expect(backend.calls.last, isNot(contains('--force')));
      await c.transfer(replaceOutput: true);
      expect(backend.calls.last, contains('--force'));
      expect(backend.calls.last, isNot(contains('--yes')));
    },
  );

  for (final sd in [false, true]) {
    test(
      'disconnect clears active ${sd ? 'SD' : 'cart'} transfer and ignores late events',
      () async {
        final stream = StreamController<BackendEvent>();
        final backend = FakeBackend()..transfer = () => stream.stream;
        final c = CartController(backend)
          ..port = '/dev/ttyTEST'
          ..cartridge = crystal
          ..sdPresent = true
          ..showingSd = sd;
        addTearDown(c.dispose);
        c.chooseFile('/tmp/disconnect.gb');
        final running = sd
            ? c.sdCommand([
                '--sd-get',
                '/game.gb',
                '--file',
                '/tmp/disconnect.gb',
              ])
            : c.transfer();
        await Future<void>.delayed(Duration.zero);
        stream.add({'event': 'progress', 'received': 256, 'total': 1024});
        await Future<void>.delayed(Duration.zero);
        expect(c.hasTransfer, true);
        expect(c.progress, .25);
        await c.refreshDevices();
        expect(backend.calls.length, 1);
        backend.connected = [];
        await c.refreshDevices();
        expect(c.port, null);
        expect(c.hasTransfer, false);
        expect(c.progress, null);
        expect(c.activity, isEmpty);
        expect(c.checksum, null);
        expect(c.showingSd, false);
        stream.add({'event': 'progress', 'received': 512, 'total': 1024});
        stream.add({'event': 'complete'});
        stream.addError(
          const BackendFailure('transport_error', 'USB disconnected'),
        );
        await stream.close();
        await running;
        expect(c.hasTransfer, false);
        expect(c.progress, null);
        expect(c.error, null);
        expect(c.activity, isEmpty);
        expect(c.finished, false);
        expect(c.busy, false);
      },
    );
  }

  test(
    'one transfer at a time; no success before final verification',
    () async {
      final stream = StreamController<BackendEvent>();
      final backend = FakeBackend()..transfer = () => stream.stream;
      final c = CartController(backend)..port = '/dev/ttyTEST';
      addTearDown(c.dispose);
      c.chooseFile('/tmp/rom.gb');
      final running = c.transfer();
      await Future<void>.delayed(Duration.zero);
      c.selectAction(CartAction.writeGame);
      c.chooseFile('/tmp/other.gb');
      await c.transfer();
      expect(backend.calls.length, 1);
      expect(c.action, CartAction.backupGame);
      stream.add({'event': 'progress', 'received': 1024, 'total': 1024});
      await Future<void>.delayed(Duration.zero);
      expect(c.progress, 1);
      expect(c.finished, false);
      stream.addError(
        const BackendFailure('transport_error', 'USB disconnected'),
      );
      await stream.close();
      await running;
      expect(c.finished, false);
      expect(c.error, contains('USB disconnected'));
      expect(c.busy, false);
    },
  );

  test(
    'successful ROM write refreshes header once and retains completion',
    () async {
      final backend = FakeBackend();
      final c = CartController(backend)
        ..port = '/dev/ttyTEST'
        ..cartridge = crystal;
      addTearDown(c.dispose);
      c.selectAction(CartAction.writeGame);
      c.chooseFile('/tmp/crystal.gb');
      await c.transfer();
      expect(backend.calls.length, 2);
      expect(backend.calls.last, contains('--inspect'));
      expect(c.title, 'PM_CRYSTAL');
      expect(c.finished, true);
      expect(c.phase, 'Complete and verified');
    },
  );
}
