import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_email_sender/flutter_email_sender.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../../../core/logging/log_providers.dart';
import '../../../../core/providers/core_providers.dart';

class BugReportScreen extends ConsumerStatefulWidget {
  const BugReportScreen({super.key});

  @override
  ConsumerState<BugReportScreen> createState() => _BugReportScreenState();
}

class _BugReportScreenState extends ConsumerState<BugReportScreen> {
  final _doingController = TextEditingController();
  final _happenedController = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _doingController.dispose();
    _happenedController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final doing = _doingController.text.trim();
    final happened = _happenedController.text.trim();

    if (doing.isEmpty || happened.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please fill in both fields before sending.'),
        ),
      );
      return;
    }

    setState(() => _sending = true);

    try {
      final logService = ref.read(logServiceProvider);
      final packageInfo = await ref.read(packageInfoProvider.future);
      final logFile = await logService.ensureLogFile();

      final subject =
          'Earshot Bug Report v${packageInfo.version}+${packageInfo.buildNumber}';

      final body =
          '''Earshot Bug Report
==================
Version: ${packageInfo.version}+${packageInfo.buildNumber}
Platform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}
Date: ${DateTime.now().toIso8601String()}

What were you doing:
$doing

What happened:
$happened
''';

      final email = Email(
        body: body,
        subject: subject,
        recipients: const ['michael@payown.media'],
        attachmentPaths: [logFile.path],
        isHTML: false,
      );

      try {
        await FlutterEmailSender.send(email);
        if (mounted) context.pop();
      } on PlatformException catch (e) {
        if (e.code == 'not_available') {
          // Mail not configured — fall back to share sheet.
          await SharePlus.instance.share(
            ShareParams(
              files: [XFile(logFile.path)],
              subject: subject,
              text: body,
            ),
          );
          if (mounted) context.pop();
        } else {
          rethrow;
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not send report: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Send Bug Report'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Cancel',
          onPressed: () => context.pop(),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Describe what happened. A debug log will be attached automatically. '
                'The log includes episode titles, feed URLs, and playback events. '
                'It does not include your email address or account information.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _doingController,
                minLines: 3,
                maxLines: null,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'What were you doing?',
                  hintText:
                      'e.g. I was scrubbing through an episode on the player screen',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _happenedController,
                minLines: 3,
                maxLines: null,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'What happened?',
                  hintText: 'e.g. The app froze and I had to force-quit it',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 32),
              Semantics(
                button: true,
                label: _sending ? 'Sending report' : 'Send Report',
                enabled: !_sending,
                child: ExcludeSemantics(
                  child: FilledButton(
                    onPressed: _sending ? null : _send,
                    child: _sending
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text('Send Report'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
