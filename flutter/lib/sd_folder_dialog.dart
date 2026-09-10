import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'controller.dart';

class SdFolderDialog extends StatefulWidget {
  const SdFolderDialog({
    super.key,
    required this.controller,
    required this.sources,
  });

  final CartController controller;
  final List<String> sources;

  @override
  State<SdFolderDialog> createState() => _SdFolderDialogState();
}

class _SdFolderDialogState extends State<SdFolderDialog> {
  late final String? port = widget.controller.port;
  late final int generation = widget.controller.sdGeneration;
  late final String origin = widget.controller.sdDirectory;
  late String directory = origin;
  late List<Map<String, dynamic>> entries = widget.controller.sdEntries;
  bool loading = false;
  String? error;

  bool get connected =>
      widget.controller.port == port &&
      widget.controller.sdPresent &&
      widget.controller.sdGeneration == generation;

  bool excluded(String path) => widget.sources.any((source) {
    final key = source.toLowerCase();
    return path.toLowerCase() == key || path.toLowerCase().startsWith('$key/');
  });

  Future<void> open(String path) async {
    if (loading || !connected || excluded(path)) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await widget.controller.readSdDirectory(path);
      if (mounted && connected) {
        setState(() {
          directory = path;
          entries = result;
        });
      }
    } on Object catch (failure) {
      if (mounted) setState(() => error = failure.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final folders = entries
          .where((entry) => entry['directory'] == true)
          .toList();
      return AlertDialog(
        title: const Text('Move to folder'),
        content: SizedBox(
          width: 460,
          height: 320,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: 'Parent folder',
                    onPressed: !connected || loading || directory == '/'
                        ? null
                        : () => open(p.posix.dirname(directory)),
                    icon: const Icon(Icons.arrow_upward_rounded),
                  ),
                  Expanded(
                    child: Text(
                      directory == '/' ? 'SD Card' : directory,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              Expanded(
                child: !connected
                    ? const Center(child: Text('Chromatic disconnected'))
                    : loading
                    ? const Center(child: CircularProgressIndicator())
                    : error != null
                    ? Center(child: Text(error!))
                    : folders.isEmpty
                    ? const Center(child: Text('No folders'))
                    : ListView.builder(
                        itemCount: folders.length,
                        itemBuilder: (context, index) {
                          final entry = folders[index];
                          final path = p.posix.join(
                            directory,
                            entry['name'] as String,
                          );
                          return ListTile(
                            leading: const Icon(Icons.folder_outlined),
                            title: Text(entry['name'] as String),
                            enabled: !excluded(path),
                            onTap: excluded(path) ? null : () => open(path),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed:
                connected &&
                    !loading &&
                    error == null &&
                    directory != origin &&
                    !excluded(directory)
                ? () => Navigator.pop(context, directory)
                : null,
            child: const Text('Move here'),
          ),
        ],
      );
    },
  );
}
