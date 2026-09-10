import 'package:flutter/material.dart';
import 'app_update.dart';
import 'releases.dart';

class AppUpdateDialog extends StatefulWidget {
  const AppUpdateDialog({
    super.key,
    required this.release,
    required this.installer,
    required this.ignore,
    required this.beforeExit,
    required this.resume,
  });
  final GitHubRelease release;
  final AppInstaller installer;
  final Future<void> Function() ignore, beforeExit, resume;

  @override
  State<AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<AppUpdateDialog> {
  bool _working = false;
  bool _restarting = false;
  String? _status, _error;

  Future<void> _install() async {
    setState(() {
      _working = true;
      _error = null;
      _status = 'Downloading update...';
    });
    PreparedAppUpdate? prepared;
    try {
      prepared = await widget.installer.prepare(widget.release, (status) {
        if (mounted) setState(() => _status = status);
      });
      if (!mounted) return;
      setState(() {
        _restarting = true;
        _status = 'Restarting ChroMagician...';
      });
      await prepared.restart(() async {
        if (!mounted) throw const ReleaseFailure('Update canceled.');
        await widget.beforeExit();
        if (!mounted) throw const ReleaseFailure('Update canceled.');
      });
    } on Object catch (error) {
      await widget.resume();
      if (mounted) {
        setState(() {
          _error = error is ReleaseFailure
              ? error.message
              : 'The update could not be installed. Please try again.';
          _working = false;
          _restarting = false;
        });
      }
    } finally {
      await prepared?.discard();
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_restarting,
    child: AlertDialog(
      title: Text(
        _working ? 'Updating ChroMagician' : 'ChroMagician update available',
      ),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_working) ...[
              Text(_status!, style: Theme.of(context).textTheme.bodyLarge),
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
            ] else
              Text(_error ?? 'Version ${widget.release.tag} is available.'),
          ],
        ),
      ),
      actions: [
        if (_working && !_restarting)
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        if (!_working)
          TextButton(
            onPressed: () async {
              try {
                await widget.ignore();
                if (context.mounted) Navigator.pop(context);
              } on Object {
                if (mounted) {
                  setState(
                    () => _error =
                        'Could not save that choice. Please try again.',
                  );
                }
              }
            },
            child: const Text("Don't ask again for this release"),
          ),
        if (!_working)
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Later'),
          ),
        if (!_working)
          FilledButton(onPressed: _install, child: const Text('Update')),
      ],
    ),
  );
}
