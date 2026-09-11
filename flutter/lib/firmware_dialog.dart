import 'dart:async';

import 'package:flutter/material.dart';

import 'controller.dart';
import 'firmware.dart';
import 'firmware_releases.dart';
import 'updates.dart';

class FirmwareDialog extends StatefulWidget {
  const FirmwareDialog({
    super.key,
    required this.controller,
    this.loadBundle,
    this.installer,
    this.releases,
  });
  final CartController controller;
  final Future<FirmwareBundle> Function()? loadBundle;
  final FirmwareInstaller? installer;
  final FirmwareReleases? releases;

  @override
  State<FirmwareDialog> createState() => _FirmwareDialogState();
}

class _FirmwareDialogState extends State<FirmwareDialog> {
  late final FirmwareInstaller installer =
      widget.installer ?? FirmwareInstaller(widget.controller.backend);
  late final Future<FirmwareReleases> downloads = widget.releases != null
      ? Future.value(widget.releases!)
      : ReleaseUpdates.configured().then(
          (updates) => FirmwareReleases(updates.client),
        );
  final releaseErrors = <String, String>{};
  FirmwareBundle? bundle;
  FirmwareRelease? selected;
  FirmwareProgress? progress;
  String? error;
  bool checking = true;
  bool installing = false;
  bool complete = false;

  bool get selectionReady =>
      selected != null &&
      (widget.loadBundle != null || selected!.version.isNotEmpty);
  bool get resolvingSelection =>
      !selectionReady &&
      selected != null &&
      !releaseErrors.containsKey(selected!.id);
  String? get displayedError => error ?? releaseErrors[selected?.id];

  String? get current {
    final version = widget.controller.firmwareVersion;
    if (widget.controller.port == null ||
        version == null ||
        installing ||
        complete) {
      return null;
    }
    return '${version['chromatic']} · MCU ${version['mcu']} · FPGA ${version['fpga']}';
  }

  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> load() async {
    try {
      final loaded =
          await (widget.loadBundle?.call() ?? firmwareToolConfiguration());
      if (!mounted) return;
      setState(() {
        bundle = loaded;
        selected = loaded.releases.firstWhere(
          (release) => release.id == 'chromagician',
        );
      });
      if (widget.loadBundle == null) {
        for (final release in loaded.releases) {
          unawaited(describe(release.id));
        }
      }
    } on Object catch (failure) {
      if (mounted) setState(() => error = failure.toString());
    } finally {
      if (mounted) setState(() => checking = false);
    }
  }

  Future<void> describe(String id) async {
    try {
      final release = await (await downloads).describe(id);
      if (!mounted) return;
      setState(() {
        bundle = FirmwareBundle(bundle!.directory, bundle!.tools, [
          for (final item in bundle!.releases) item.id == id ? release : item,
        ]);
        if (selected?.id == id) selected = release;
      });
    } on Object catch (failure) {
      if (mounted) setState(() => releaseErrors[id] = failure.toString());
    }
  }

  Future<void> install() async {
    if (widget.controller.port == null ||
        installing ||
        checking ||
        bundle == null ||
        !selectionReady) {
      return;
    }
    setState(() {
      installing = true;
      complete = false;
      error = null;
    });
    widget.controller.setFirmwareBusy(true);
    widget.controller.clearFirmwareVersion();
    try {
      void report(FirmwareProgress value) {
        if (mounted) setState(() => progress = value);
      }

      var prepared = bundle!;
      var release = selected!;
      if (widget.loadBundle == null) {
        prepared = await (await downloads).prepare(
          release.id,
          prepared.tools,
          report,
        );
        release = prepared.releases.single;
      }
      await installer.install(prepared, release, report);
      if (installer.verifiedPort != null) {
        widget.controller.port = installer.verifiedPort;
      }
      widget.controller.setFirmwareVersion(release.version);
      if (mounted) setState(() => selected = release);
      if (mounted) {
        setState(() {
          complete = true;
        });
      }
    } on Object catch (failure) {
      if (mounted) setState(() => error = failure.toString());
    } finally {
      widget.controller.setFirmwareBusy(false);
      if (mounted) setState(() => installing = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) => PopScope(
      canPop: !installing && !checking,
      child: AlertDialog(
        title: const Text('Firmware'),
        content: SizedBox(
          width: 470,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Keep Chromatic powered on and connected to USB'),
                const SizedBox(height: 20),
                if (bundle != null)
                  DropdownButtonFormField<String>(
                    initialValue: selected?.id,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                    ),
                    items: bundle!.releases
                        .map(
                          (release) => DropdownMenuItem(
                            value: release.id,
                            child: Text(release.label),
                          ),
                        )
                        .toList(),
                    onChanged:
                        widget.controller.port == null || installing || checking
                        ? null
                        : (id) => setState(() {
                            selected = bundle!.releases.firstWhere(
                              (release) => release.id == id,
                            );
                            complete = false;
                            error = null;
                            progress = null;
                          }),
                  ),
                if (current != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Installed: $current',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                if (!installing && progress == null && !complete) ...[
                  const SizedBox(height: 16),
                  const Text(
                    'No Warranty',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'ChroMagic firmware and ChroMagician are provided "as is", '
                    'with no warranty. Installation and use are at your own risk. '
                    'We are not responsible for data loss, device damage, or '
                    'any other loss or damage resulting from installation or use.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.65),
                    ),
                  ),
                ],
                if (checking || resolvingSelection || progress != null) ...[
                  const SizedBox(height: 22),
                  Text(
                    checking || resolvingSelection
                        ? 'Checking...'
                        : displayedError != null
                        ? 'Installation needs attention'
                        : complete
                        ? '${selected!.label} installed and verified.'
                        : '${progress!.component == null ? '' : '${progress!.component} · '}${progress!.phase}',
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 10),
                  if (displayedError == null)
                    LinearProgressIndicator(
                      value: checking || resolvingSelection
                          ? null
                          : progress?.fraction,
                    ),
                ],
                if (displayedError != null) ...[
                  const SizedBox(height: 16),
                  SelectableText(
                    displayedError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: installing || checking
                ? null
                : () => Navigator.pop(context),
            child: Text(complete ? 'Done' : 'Close'),
          ),
          if (!complete)
            FilledButton(
              onPressed:
                  widget.controller.port == null ||
                      installing ||
                      checking ||
                      bundle == null ||
                      !selectionReady
                  ? null
                  : install,
              child: Text(
                installing
                    ? 'Installing...'
                    : selected?.id == 'stock'
                    ? 'Restore stock'
                    : 'Install ChroMagic',
              ),
            ),
        ],
      ),
    ),
  );
}
