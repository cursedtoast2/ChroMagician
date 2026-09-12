import 'dart:async';
import 'dart:math' as math;
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/link.dart';
import 'app_update_dialog.dart';
import 'controller.dart';
import 'firmware_dialog.dart';
import 'firmware_releases.dart';
import 'updates.dart';
import 'sd_folder_dialog.dart';
import 'visuals.dart';

const ink = Color(0xff121515);
const muted = Color(0xff9ba6a1);
const lime = Color(0xffc5ed9b);
const violet = Color(0xffc0a6ef);
const stroke = Color(0xff353d38);

String gameDescription(String summary) {
  final paragraph = summary.trim().split(RegExp(r'[\r\n]')).first.trim();
  final endings = RegExp(r'''[.!?]+["'”’)\]]*(?=\s|$)''');
  final abbreviation = RegExp(
    r'\b(?:Mr|Mrs|Ms|Dr|Prof|St|vs|e\.g|i\.e|[A-Z]|(?:[A-Z]\.)+[A-Z])$',
    caseSensitive: false,
  );
  var sentences = 0;
  for (final ending in endings.allMatches(paragraph)) {
    if (ending.group(0) == '.' &&
        abbreviation.hasMatch(paragraph.substring(0, ending.start))) {
      continue;
    }
    if (++sentences == 8) return paragraph.substring(0, ending.end);
  }
  return paragraph;
}

ThemeData appTheme() => ThemeData(
  brightness: Brightness.dark,
  useMaterial3: true,
  scaffoldBackgroundColor: ink,
  colorScheme: const ColorScheme.dark(
    primary: lime,
    secondary: violet,
    surface: Color(0xff202522),
    onPrimary: Color(0xff182412),
    onSurface: Color(0xfff0f3ee),
  ),
  textTheme: const TextTheme(
    bodyMedium: TextStyle(fontSize: 14, height: 1.5),
    bodyLarge: TextStyle(fontSize: 16, height: 1.5),
    labelLarge: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
  ),
  progressIndicatorTheme: const ProgressIndicatorThemeData(
    linearMinHeight: 10,
    borderRadius: BorderRadius.all(Radius.circular(5)),
  ),
  dividerColor: stroke,
  tooltipTheme: const TooltipThemeData(
    waitDuration: Duration(milliseconds: 400),
  ),
);

class ChromaticApp extends StatelessWidget {
  const ChromaticApp({super.key, required this.controller, this.updates});
  final CartController controller;
  final ReleaseUpdates? updates;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'ChroMagician',
    debugShowCheckedModeBanner: false,
    theme: appTheme(),
    home: Workspace(controller: controller, updates: updates),
  );
}

class Workspace extends StatefulWidget {
  const Workspace({super.key, required this.controller, this.updates});
  final CartController controller;
  final ReleaseUpdates? updates;
  @override
  State<Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<Workspace> {
  CartController get c => widget.controller;
  bool _picking = false;
  bool _sdDropHover = false;
  String? _sdDragContext;
  final _sdSelection = <String>{};
  String? _sdSelectionContext;

  String? _promptedRelease;
  bool _updateDialog = false;

  @override
  void initState() {
    super.initState();
    widget.updates?.addListener(_updatesChanged);
    c.addListener(_updatesChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _offerUpdate());
  }

  @override
  void dispose() {
    widget.updates?.removeListener(_updatesChanged);
    c.removeListener(_updatesChanged);
    super.dispose();
  }

  void _updatesChanged() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => _offerUpdate());
  }

  Future<void> _offerUpdate() async {
    final release = widget.updates?.appUpdate;
    final restored = widget.updates?.restoredPreviousVersion == true;
    if (!mounted ||
        (!restored && (release == null || _promptedRelease == release.tag)) ||
        _updateDialog ||
        _picking ||
        c.busy ||
        c.firmwareOpen ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    _promptedRelease = release?.tag;
    _updateDialog = true;
    try {
      if (widget.updates!.restoredPreviousVersion) {
        widget.updates!.restoredPreviousVersion = false;
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Could not install update'),
            content: const Text(
              'ChroMagician restored the previous version because the update could not start.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          ),
        );
        return;
      }
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AppUpdateDialog(
          release: release!,
          installer: widget.updates!.installer,
          ignore: () => widget.updates!.ignore(release),
          beforeExit: c.pauseForAppUpdate,
          resume: c.resumeAfterAppUpdate,
        ),
      );
    } finally {
      _updateDialog = false;
    }
  }

  Future<void> showProjectAbout() async {
    final version =
        widget.updates?.appVersion ??
        (await PackageInfo.fromPlatform()).version;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('About ChroMagician'),
        content: SizedBox(
          width: 420,
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: 'Version $version\n\n',
                  style: const TextStyle(color: muted),
                ),
                const TextSpan(
                  text: 'ChroMagic and ChroMagician are a project by ',
                ),
                WidgetSpan(
                  alignment: PlaceholderAlignment.baseline,
                  baseline: TextBaseline.alphabetic,
                  child: Link(
                    uri: Uri.parse('https://x.com/CursedToastSDA'),
                    builder: (context, followLink) => Semantics(
                      link: true,
                      child: InkWell(
                        onTap: followLink,
                        child: Text(
                          'CursedToast',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: lime,
                                decoration: TextDecoration.underline,
                              ),
                        ),
                      ),
                    ),
                  ),
                ),
                const TextSpan(
                  text:
                      '.\n\n'
                      'This is an independent, unofficial community project. '
                      'It is not affiliated with, endorsed by, or sponsored by ModRetro or Nintendo.\n\n'
                      'ChroMagic and ChroMagician are intended for homebrew and personal backups. '
                      'We do not distribute commercial games or support piracy.',
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> pickFile(CartAction action) async {
    if (_picking ||
        c.busy ||
        c.port == null ||
        !c.cartridgeReady ||
        !c.actionAvailable(action)) {
      return;
    }
    setState(() => _picking = true);
    c.selectAction(action);
    final port = c.port;
    final cartridge = c.cartridge;
    final extension = p.extension(c.suggestedName);
    try {
      final types = [
        XTypeGroup(
          label: action.isGame ? 'Game Boy ROM' : 'Game Boy save',
          extensions: action.isGame ? ['gb', 'gbc'] : ['sav'],
          uniformTypeIdentifiers: const ['public.data'],
        ),
      ];
      String? selected;
      if (action.writes) {
        selected = (await openFile(
          acceptedTypeGroups: types,
          confirmButtonText: action.label,
        ))?.path;
      } else {
        selected = (await getSaveLocation(
          suggestedName: c.suggestedName,
          acceptedTypeGroups: types,
          confirmButtonText: action.label,
        ))?.path;
      }
      if (selected == null || !mounted) return;
      if (!action.writes && p.extension(selected).isEmpty) {
        selected += extension;
      }
      if (!mounted ||
          c.busy ||
          action != c.action ||
          port != c.port ||
          !identical(cartridge, c.cartridge)) {
        return;
      }
      c.chooseFile(selected);
      await c.transfer(replaceOutput: !action.writes);
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not choose a file: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) => Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xff181a1b), Color(0xff1c241a), Color(0xff19181e)],
          ),
        ),
        child: Stack(
          children: [
            const Positioned(
              right: -170,
              top: -280,
              child: AmbientGlow(color: Color(0xff526b25)),
            ),
            const Positioned(
              left: -220,
              bottom: -360,
              child: AmbientGlow(color: Color(0xff583780)),
            ),
            SafeArea(
              child: Column(
                children: [
                  header(),
                  if (c.port != null && (c.sdPresent || c.sdError != null))
                    Padding(
                      padding: const EdgeInsets.fromLTRB(34, 0, 34, 16),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: storageNavigation(),
                      ),
                    ),
                  Expanded(
                    child: c.showFirmwareSetup
                        ? firmwareSetupPrompt()
                        : c.showingSd
                        ? c.sdPresent
                              ? sdWorkspace()
                              : Center(
                                  child: Text(
                                    c.sdStatusMessage,
                                    style: const TextStyle(
                                      fontSize: 26,
                                      color: muted,
                                    ),
                                  ),
                                )
                        : c.loadingGame
                        ? const Center(
                            child: Text(
                              'Loading',
                              style: TextStyle(fontSize: 26, color: muted),
                            ),
                          )
                        : !c.cartridgeReady
                        ? connectionPrompt()
                        : LayoutBuilder(
                            builder: (context, constraints) =>
                                SingleChildScrollView(
                                  padding: const EdgeInsets.fromLTRB(
                                    34,
                                    8,
                                    34,
                                    28,
                                  ),
                                  child: ConstrainedBox(
                                    constraints: BoxConstraints(
                                      minHeight: math.max(
                                        0,
                                        constraints.maxHeight - 36,
                                      ),
                                    ),
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: [
                                            if (c.cartridgeReady) ...[
                                              cartridgeOverview(
                                                artHeight:
                                                    (constraints.maxHeight -
                                                            400)
                                                        .clamp(300.0, 480.0),
                                              ),
                                              const SizedBox(height: 26),
                                              navigation(),
                                              const SizedBox(height: 12),
                                              actionButtons(),
                                            ],
                                            if (c.error != null) ...[
                                              const SizedBox(height: 16),
                                              errorCard(),
                                            ],
                                          ],
                                        ),
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            top: 24,
                                          ),
                                          child: transferPanel(),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                          ),
                  ),
                  footer(),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  Future<String?> sdName(String title, {String initial = ''}) async {
    final input = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: input,
          autofocus: true,
          onSubmitted: (value) => Navigator.pop(context, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, input.text.trim()),
            child: Text(title),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    input.dispose();
    if (result == null || result.isEmpty) return null;
    if (result == '.' ||
        result == '..' ||
        result.contains(RegExp(r'[\\/:*?"<>|]')) ||
        result.endsWith('.') ||
        result.endsWith(' ')) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Choose a valid file name.')),
        );
      }
      return null;
    }
    return result;
  }

  Future<void> confirmSdBackup() async {
    if (_picking || c.busy || !c.sdPresent || !c.cartridgeReady) return;
    setState(() => _picking = true);
    final port = c.port;
    final cartridge = c.cartridge;
    final action = c.action;
    final generation = c.sdGeneration;
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            action.isGame ? 'Back up game to SD?' : 'Back up save to SD?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Back up'),
            ),
          ],
        ),
      );
      if (confirmed == true &&
          mounted &&
          c.port == port &&
          identical(c.cartridge, cartridge) &&
          c.action == action &&
          c.sdGeneration == generation &&
          c.sdPresent &&
          !c.busy) {
        await c.backupToSd();
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> sdAction(String action, [Map<String, dynamic>? entry]) async {
    if (_picking || c.busy || !c.sdPresent || c.port == null) return;
    setState(() => _picking = true);
    final port = c.port;
    final directory = c.sdDirectory;
    final generation = c.sdGeneration;
    final remote = entry == null ? null : c.sdPath(entry['name'] as String);
    List<String>? arguments;
    try {
      switch (action) {
        case 'upload':
          final files = await openFiles(confirmButtonText: 'Copy to SD card');
          if (files.length == 1) {
            final file = files.single;
            var name = p.basename(file.path);
            if (c.sdEntries.any(
              (entry) =>
                  (entry['name'] as String).toLowerCase() == name.toLowerCase(),
            )) {
              if (!mounted) return;
              final replacement = await sdName('Save as', initial: name);
              if (replacement == null) return;
              name = replacement;
            }
            arguments = [
              '--sd-put',
              p.posix.join(directory, name),
              '--file',
              file.path,
            ];
          } else if (files.isNotEmpty) {
            arguments = [
              '--sd-import',
              ...files.map((file) => file.path),
              '--destination',
              directory,
            ];
          }
        case 'upload-folder':
          final folder = await getDirectoryPath(
            confirmButtonText: 'Copy folder to SD',
          );
          if (folder != null) {
            arguments = ['--sd-import', folder, '--destination', directory];
          }
        case 'initialize':
          arguments = ['--sd-initialize'];
        case 'download':
          final target = await getSaveLocation(
            suggestedName: entry!['name'] as String,
            confirmButtonText: 'Copy to PC',
          );
          if (target != null) {
            arguments = ['--sd-get', remote!, '--file', target.path, '--force'];
          }
        case 'rename':
          final name = await sdName(
            'Rename',
            initial: entry!['name'] as String,
          );
          if (name != null) {
            arguments = [
              '--sd-rename',
              remote!,
              '--destination',
              p.posix.join(directory, name),
            ];
          }
        case 'mkdir':
          final name = await sdName('New folder');
          if (name != null) {
            arguments = ['--sd-mkdir', p.posix.join(directory, name)];
          }
        case 'delete':
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text('Delete ${entry!['name']}?'),
              content: entry['directory'] == true
                  ? const Text(
                      'This deletes the folder and everything inside it.',
                    )
                  : null,
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Delete'),
                ),
              ],
            ),
          );
          if (confirmed == true) {
            arguments = [
              entry!['directory'] == true ? '--sd-delete-tree' : '--sd-delete',
              remote!,
            ];
          }
      }
      if (arguments != null &&
          mounted &&
          c.port == port &&
          c.sdPresent &&
          c.sdDirectory == directory &&
          c.sdGeneration == generation &&
          !c.busy) {
        await c.sdCommand(arguments);
      }
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> sdBulkAction({required bool move}) async {
    if (_picking ||
        c.busy ||
        !c.sdPresent ||
        c.port == null ||
        _sdSelection.isEmpty) {
      return;
    }
    setState(() => _picking = true);
    final port = c.port;
    final generation = c.sdGeneration;
    final directory = c.sdDirectory;
    final entries = c.sdEntries
        .where((entry) => _sdSelection.contains(entry['name']))
        .toList();
    final paths = entries
        .map((entry) => c.sdPath(entry['name'] as String))
        .toList();
    try {
      List<String>? arguments;
      if (move) {
        final destination = await showDialog<String>(
          context: context,
          builder: (_) => SdFolderDialog(controller: c, sources: paths),
        );
        if (destination != null) {
          arguments = ['--sd-move', ...paths, '--destination', destination];
        }
      } else {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(
              'Delete ${paths.length} ${paths.length == 1 ? 'item' : 'items'}?',
            ),
            content: entries.any((entry) => entry['directory'] == true)
                ? const Text(
                    'This includes everything inside the selected folders.',
                  )
                : null,
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
        if (confirmed == true) arguments = ['--sd-delete-many', ...paths];
      }
      if (arguments != null &&
          mounted &&
          !c.busy &&
          c.port == port &&
          c.sdPresent &&
          c.sdGeneration == generation &&
          c.sdDirectory == directory) {
        await c.sdCommand(arguments);
        if (c.error != null &&
            c.port == port &&
            c.sdPresent &&
            c.sdGeneration == generation) {
          final failure = c.error;
          await c.listSd(directory);
          c.error = failure;
        }
        if (mounted && c.finished) setState(_sdSelection.clear);
      }
    } on Object catch (failure) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(failure.toString())));
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  String get _sdContext => '${c.port}:${c.sdGeneration}:${c.sdDirectory}';

  bool get _sdDropEnabled =>
      c.showingSd &&
      c.sdPresent &&
      c.port != null &&
      !c.busy &&
      !c.firmwareOpen &&
      !_picking &&
      ModalRoute.of(context)?.isCurrent == true;

  Future<void> sdDrop(DropDoneDetails details, String scope) async {
    final dragContext = _sdDragContext;
    _sdDragContext = null;
    if (!mounted ||
        !_sdDropEnabled ||
        scope != _sdContext ||
        (dragContext != null && dragContext != scope) ||
        details.files.isEmpty) {
      return;
    }
    setState(() {
      _sdDropHover = false;
      _picking = true;
    });
    try {
      await c.sdCommand([
        '--sd-import',
        ...details.files.map((file) => file.path),
        '--destination',
        c.sdDirectory,
      ]);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Widget sdWorkspace() {
    final scope = _sdContext;
    final dropEnabled = _sdDropEnabled;
    if (_sdSelectionContext != scope) {
      _sdSelection.clear();
      _sdSelectionContext = scope;
      _sdDropHover = false;
    }
    if (!dropEnabled) _sdDropHover = false;
    _sdSelection.removeWhere(
      (name) => !c.sdEntries.any((entry) => entry['name'] == name),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(34, 8, 34, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: c.busy || _picking ? null : () => sdAction('upload'),
                icon: const Icon(Icons.upload_rounded, size: 18),
                label: const Text('Copy to SD card'),
              ),
              OutlinedButton.icon(
                onPressed: c.busy || _picking
                    ? null
                    : () => sdAction('upload-folder'),
                icon: const Icon(Icons.drive_folder_upload_outlined, size: 18),
                label: const Text('Copy folder to SD'),
              ),
              OutlinedButton.icon(
                onPressed: c.busy || _picking ? null : () => sdAction('mkdir'),
                icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                label: const Text('New folder'),
              ),
              Tooltip(
                message:
                    'Creates the CHROMAGIC/BACKUPS folder on the card, where '
                    'the BACKUPS tab looks for games. Use it on a fresh card.',
                child: OutlinedButton.icon(
                  onPressed: c.busy || _picking
                      ? null
                      : () => sdAction('initialize'),
                  icon: const Icon(Icons.folder_special_outlined, size: 18),
                  label: const Text('Initialize backups'),
                ),
              ),
              if (_sdSelection.isNotEmpty) ...[
                OutlinedButton.icon(
                  key: const ValueKey('sd-move-selected'),
                  onPressed: c.busy || _picking
                      ? null
                      : () => sdBulkAction(move: true),
                  icon: const Icon(Icons.drive_file_move_outlined, size: 18),
                  label: const Text('Move'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('sd-delete-selected'),
                  onPressed: c.busy || _picking
                      ? null
                      : () => sdBulkAction(move: false),
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('Delete'),
                ),
                Text(
                  '${_sdSelection.length} selected',
                  style: const TextStyle(fontSize: 16, color: muted),
                ),
              ],
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const SizedBox(width: 16),
              Checkbox(
                key: const ValueKey('sd-select-all'),
                semanticLabel: 'Select all',
                tristate: true,
                value: _sdSelection.isEmpty
                    ? false
                    : _sdSelection.length == c.sdEntries.length
                    ? true
                    : null,
                onChanged: c.busy || _picking || c.sdEntries.isEmpty
                    ? null
                    : (_) => setState(() {
                        if (_sdSelection.length == c.sdEntries.length) {
                          _sdSelection.clear();
                        } else {
                          _sdSelection.addAll(
                            c.sdEntries.map((entry) => entry['name'] as String),
                          );
                        }
                      }),
              ),
              IconButton(
                tooltip: 'Parent folder',
                onPressed: c.busy || _picking || c.sdDirectory == '/'
                    ? null
                    : () => c.listSd(p.posix.dirname(c.sdDirectory)),
                icon: const Icon(Icons.arrow_upward_rounded),
              ),
              Expanded(
                child: Text(
                  c.sdDirectory == '/' ? 'SD Card' : c.sdDirectory,
                  style: const TextStyle(fontSize: 18),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (c.sdLoading)
                const Text(
                  'Loading',
                  style: TextStyle(fontSize: 16, color: muted),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: DropTarget(
              key: ValueKey('sd-drop-$scope'),
              enable: dropEnabled,
              onDragEntered: (_) {
                _sdDragContext = scope;
                setState(() => _sdDropHover = true);
              },
              onDragExited: (_) {
                if (_sdDropHover) setState(() => _sdDropHover = false);
              },
              onDragDone: (details) => sdDrop(details, scope),
              child: Container(
                decoration: BoxDecoration(
                  color: ink.withValues(alpha: 0.45),
                  border: Border.all(color: _sdDropHover ? lime : stroke),
                  borderRadius: BorderRadius.circular(14),
                ),
                clipBehavior: Clip.antiAlias,
                child: c.sdEntries.isEmpty
                    ? Center(
                        child: Text(
                          c.sdLoading ? 'Loading' : 'This folder is empty',
                          style: const TextStyle(fontSize: 16, color: muted),
                        ),
                      )
                    : ListView.separated(
                        itemCount: c.sdEntries.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final entry = c.sdEntries[index];
                          final name = entry['name'] as String;
                          final folder = entry['directory'] == true;
                          return Material(
                            color: Colors.transparent,
                            child: ListTile(
                              selected: _sdSelection.contains(name),
                              selectedTileColor: lime.withValues(alpha: 0.07),
                              leading: Checkbox(
                                key: ValueKey('sd-select-$name'),
                                semanticLabel: 'Select $name',
                                value: _sdSelection.contains(name),
                                onChanged: c.busy || _picking
                                    ? null
                                    : (selected) => setState(() {
                                        if (selected == true) {
                                          _sdSelection.add(name);
                                        } else {
                                          _sdSelection.remove(name);
                                        }
                                      }),
                              ),
                              title: Text(entry['name'] as String),
                              subtitle: folder
                                  ? null
                                  : Text(
                                      formatBytes(entry['size'] as int),
                                      style: const TextStyle(
                                        color: muted,
                                        fontSize: 14,
                                      ),
                                    ),
                              onTap: !c.busy && !_picking
                                  ? () {
                                      if (folder) {
                                        c.listSd(c.sdPath(name));
                                      } else {
                                        setState(() {
                                          if (!_sdSelection.remove(name)) {
                                            _sdSelection.add(name);
                                          }
                                        });
                                      }
                                    }
                                  : null,
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (folder)
                                    const Icon(
                                      Icons.chevron_right_rounded,
                                      color: muted,
                                    ),
                                  if (!folder)
                                    IconButton(
                                      tooltip: 'Copy to PC',
                                      onPressed: c.busy || _picking
                                          ? null
                                          : () => sdAction('download', entry),
                                      icon: const Icon(Icons.download_rounded),
                                    ),
                                  PopupMenuButton<String>(
                                    enabled: !c.busy && !_picking,
                                    onSelected: (action) =>
                                        sdAction(action, entry),
                                    itemBuilder: (_) => const [
                                      PopupMenuItem(
                                        value: 'rename',
                                        child: Text('Rename'),
                                      ),
                                      PopupMenuItem(
                                        value: 'delete',
                                        child: Text('Delete'),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ),
          ),
          if (c.error != null) ...[const SizedBox(height: 12), errorCard()],
          const SizedBox(height: 20),
          transferPanel(),
        ],
      ),
    );
  }

  Widget firmwareSetupPrompt() => Center(
    child: Padding(
      padding: const EdgeInsets.all(34),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'ChroMagic firmware required',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 26, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: const Text(
              'Back up games and saves, restore saves, and write homebrew to '
              'rewritable cartridges. With an SD card installed, you can also '
              'copy, rename and delete files.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 15, height: 1.6, color: muted),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed:
                c.port == null ||
                    _picking ||
                    c.firmwareOpen ||
                    (c.busy && !c.inspecting)
                ? null
                : openFirmware,
            child: const Text('Install ChroMagic'),
          ),
        ],
      ),
    ),
  );

  Widget connectionPrompt() => Center(
    child: Padding(
      padding: const EdgeInsets.all(34),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              c.port == null
                  ? 'Connect your Chromatic'
                  : c.needsPcMode
                  ? 'Enable C. MAGICIAN'
                  : c.pcModeEnabled == true
                  ? 'Insert a game cartridge'
                  : 'Connecting to Chromatic',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 12),
            Text(
              c.port == null
                  ? 'Power on your Chromatic and connect it by USB.'
                  : c.needsPcMode
                  ? 'Open System settings on your Chromatic.'
                  : '',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.6,
                color: muted.withValues(alpha: 0.7),
              ),
            ),
            if (c.port == null &&
                (Theme.of(context).platform == TargetPlatform.windows ||
                    Theme.of(context).platform == TargetPlatform.linux)) ...[
              const SizedBox(height: 12),
              Link(
                uri: Uri.parse(
                  'https://support.modretro.com/en_us/chromatic-firmware-updater-ryhoYnzCx',
                ),
                builder: (context, followLink) => Semantics(
                  link: true,
                  child: InkWell(
                    onTap: followLink,
                    child: Text(
                      'Already connected? Set up USB with MRUpdater.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.6,
                        color: muted.withValues(alpha: 0.7),
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );

  Future<void> openFirmware() async {
    if (c.port == null ||
        _picking ||
        c.firmwareOpen ||
        (c.busy && !c.inspecting)) {
      return;
    }
    setState(() => _picking = true);
    var acquired = false;
    try {
      acquired = await c.beginFirmware();
      if (!acquired || !mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => FirmwareDialog(
          controller: c,
          releases: widget.updates == null
              ? null
              : FirmwareReleases(
                  widget.updates!.client,
                  firmware: widget.updates!.firmware,
                ),
        ),
      );
    } on Object catch (error) {
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Firmware unavailable'),
            content: Text(error.toString()),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close'),
              ),
            ],
          ),
        );
      }
    } finally {
      if (acquired) await c.endFirmware();
      if (mounted) setState(() => _picking = false);
    }
  }

  Widget header() => Padding(
    padding: const EdgeInsets.fromLTRB(34, 22, 34, 22),
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 64),
      child: Row(
        children: [
          OutlinedButton.icon(
            onPressed: _picking ? null : showProjectAbout,
            icon: const Icon(Icons.info_outline, size: 17),
            label: const Text('About'),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed:
                      c.port == null ||
                          _picking ||
                          c.firmwareOpen ||
                          (c.busy && !c.inspecting)
                      ? null
                      : openFirmware,
                  icon: const Icon(Icons.system_update_alt, size: 17),
                  label: const Text('Firmware'),
                ),
                if (widget.updates?.firmwareAvailable(
                      c.firmwareVersion,
                      hasChroMagic: c.hasChroMagic,
                    ) ==
                    true)
                  IconButton(
                    tooltip: 'ChroMagic update available',
                    onPressed:
                        c.port == null || _picking || c.firmwareOpen || c.busy
                        ? null
                        : openFirmware,
                    icon: const Icon(
                      Icons.notification_important_outlined,
                      color: lime,
                      size: 20,
                    ),
                  ),
                if (c.ports.length > 1)
                  DropdownButton<String>(
                    value: c.port,
                    hint: const Text('Select Chromatic'),
                    items: c.ports
                        .map(
                          (port) =>
                              DropdownMenuItem(value: port, child: Text(port)),
                        )
                        .toList(),
                    onChanged: c.busy
                        ? null
                        : (port) {
                            if (port != null) unawaited(c.selectPort(port));
                          },
                  )
                else
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 13,
                      vertical: 9,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xff1c221e),
                      border: Border.all(color: stroke),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: c.port == null ? muted : lime,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          c.port == null
                              ? 'Connect your Chromatic'
                              : 'Chromatic connected',
                          style: const TextStyle(fontSize: 16),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget tabFrame(Widget child) => Container(
    padding: const EdgeInsets.all(5),
    decoration: BoxDecoration(
      color: const Color(0x66121415),
      border: Border.all(color: stroke),
      borderRadius: BorderRadius.circular(13),
    ),
    child: child,
  );

  ButtonStyle tabStyle(bool selected) => TextButton.styleFrom(
    padding: const EdgeInsets.symmetric(vertical: 16),
    foregroundColor: selected ? lime : muted,
    backgroundColor: selected ? const Color(0xff293125) : Colors.transparent,
    disabledBackgroundColor: Colors.transparent,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
  );

  Widget storageNavigation() => SizedBox(
    width: 280,
    child: tabFrame(
      Row(
        children: [
          for (final (sd, label) in [(false, 'Cartridge'), (true, 'SD Card')])
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Semantics(
                  selected: c.showingSd == sd,
                  child: TextButton(
                    style: tabStyle(c.showingSd == sd),
                    onPressed: c.busy
                        ? null
                        : () {
                            if (c.showingSd != sd) unawaited(c.showSd(sd));
                          },
                    child: Text(label),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );

  Widget navigation() => tabFrame(
    Row(
      children: CartAction.values
          .map(
            (action) => Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: TextButton(
                  key: ValueKey('cart-tab-${action.name}'),
                  onPressed: c.busy || _picking || !c.actionAvailable(action)
                      ? null
                      : () => c.selectAction(action),
                  style: tabStyle(c.action == action),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(actionIcon(action), size: 17),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          action.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          )
          .toList(),
    ),
  );

  Widget actionButtons() => Container(
    padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
    decoration: BoxDecoration(
      color: const Color(0x66121415),
      border: Border.all(color: stroke),
      borderRadius: BorderRadius.circular(13),
    ),
    child: Wrap(
      alignment: WrapAlignment.center,
      spacing: 16,
      runSpacing: 12,
      children: [
        FilledButton.icon(
          key: const ValueKey('cart-file-action'),
          onPressed: c.busy || _picking || !c.actionAvailable(c.action)
              ? null
              : () => pickFile(c.action),
          icon: Icon(actionIcon(c.action), size: 18),
          label: Text(c.action.writes ? c.action.label : 'Back up to PC'),
        ),
        if (!c.action.writes)
          Tooltip(
            message: c.sdPresent || !c.sdChecked ? '' : c.sdStatusMessage,
            child: FilledButton.icon(
              key: const ValueKey('cart-sd-action'),
              onPressed: c.busy || _picking || !c.sdPresent
                  ? null
                  : confirmSdBackup,
              icon: const Icon(Icons.sd_storage_outlined, size: 18),
              label: const Text('Back up to SD'),
            ),
          ),
      ],
    ),
  );

  Widget cartridgeOverview({double artHeight = 480}) => Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      SizedBox(
        width: c.game == null ? 116 : artHeight * .75,
        height: c.game == null ? 125 : artHeight,
        child: c.game?.coverBytes == null
            ? CustomPaint(
                painter: CartridgePainter(connected: c.cartridge != null),
              )
            : ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(
                  c.game!.coverBytes!,
                  key: ValueKey(c.game!.record['id']),
                  fit: BoxFit.contain,
                  semanticLabel: '${c.title} cover art',
                  errorBuilder: (_, _, _) => CustomPaint(
                    painter: CartridgePainter(connected: c.cartridge != null),
                  ),
                ),
              ),
      ),
      const SizedBox(width: 32),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              c.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 44,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.7,
              ),
            ),
            if (c.game != null) ...[
              const SizedBox(height: 12),
              Text(
                [
                  ...c.game!.developers,
                  ...c.game!.publishers.where(
                    (name) => !c.game!.developers.contains(name),
                  ),
                  if (c.game!.releaseDate != null) c.game!.releaseDate!,
                ].join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: muted, fontSize: 20),
              ),
              if (c.game!.stars case final double stars)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Semantics(
                    label: 'Rated ${stars.toStringAsFixed(1)} out of 5 stars',
                    child: ExcludeSemantics(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: List.generate(
                          5,
                          (index) => Icon(
                            stars - index >= 0.75
                                ? Icons.star_rounded
                                : stars - index >= 0.25
                                ? Icons.star_half_rounded
                                : Icons.star_outline_rounded,
                            size: 25,
                            color: const Color(0xffefbd63),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (c.game!.genres.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    c.game!.genres.join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: violet, fontSize: 16),
                  ),
                ),
              if (c.game!.summary?.trim().isNotEmpty == true)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    gameDescription(c.game!.summary!),
                    softWrap: true,
                    style: const TextStyle(fontSize: 18, height: 1.45),
                  ),
                ),
            ],
            const SizedBox(height: 12),
            if (c.cartridge != null)
              Wrap(
                spacing: 8,
                runSpacing: 7,
                children: [
                  tag(
                    c.cartridge!['color'] == true
                        ? 'GAME BOY COLOR'
                        : 'GAME BOY',
                    color: violet,
                  ),
                  if (c.canWriteGame) tag('Rewritable', color: lime),
                  if (c.cartridge!['cart_size'] case final int size
                      when size > 0)
                    tag('${formatBytes(size)} CART'),
                ],
              )
            else
              Text(
                c.inspecting
                    ? 'Reading the cartridge header…'
                    : 'Connect by USB and enable C. MAGICIAN in System settings.',
                style: const TextStyle(color: muted, fontSize: 13),
              ),
          ],
        ),
      ),
    ],
  );

  Widget tag(String text, {Color color = muted}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: const Color(0x55121514),
      border: Border.all(color: stroke),
      borderRadius: BorderRadius.circular(5),
    ),
    child: Text(
      text,
      style: TextStyle(color: color, fontSize: 14, letterSpacing: 0.5),
    ),
  );

  Widget errorCard() => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xff342822),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: const Color(0xff695142)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.info_outline, size: 18, color: Color(0xffe8bb91)),
        const SizedBox(width: 12),
        Expanded(
          child: SelectableText(
            c.error!,
            style: const TextStyle(color: Color(0xffefd2b8), fontSize: 12),
          ),
        ),
      ],
    ),
  );

  Widget transferPanel() => Container(
    key: const ValueKey('transfer-panel'),
    constraints: const BoxConstraints(minHeight: 132),
    padding: const EdgeInsets.all(21),
    decoration: BoxDecoration(
      color: const Color(0xe6141816),
      borderRadius: BorderRadius.circular(13),
      border: Border.all(color: stroke),
    ),
    child: !c.hasTransfer
        ? const SizedBox(width: double.infinity)
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            c.phase,
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: c.finished ? lime : null,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(5),
                      child: LinearProgressIndicator(
                        value: c.busy && c.progress == null
                            ? null
                            : c.progress ?? 0,
                        color: c.finished ? lime : violet,
                        backgroundColor: const Color(0xff303731),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        if (c.total > 0)
                          Text(
                            '${formatBytes(c.bytes)} / ${formatBytes(c.total)}',
                            style: const TextStyle(fontSize: 16, color: muted),
                          ),
                        const Spacer(),
                        if (c.progress != null)
                          Text(
                            '${(c.progress! * 100).floor()}%',
                            style: const TextStyle(fontSize: 16, color: muted),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
  );

  Widget footer() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 34, vertical: 12),
    decoration: const BoxDecoration(
      border: Border(top: BorderSide(color: Color(0xff2a302c))),
    ),
    child: const SizedBox(height: 15, width: double.infinity),
  );
}

IconData actionIcon(CartAction action) => switch (action) {
  CartAction.backupGame => Icons.download_rounded,
  CartAction.writeGame => Icons.upload_rounded,
  CartAction.backupSave => Icons.save_alt_rounded,
  CartAction.restoreSave => Icons.restore_rounded,
};
