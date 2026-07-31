import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';

import '../../utils/url_launcher.dart';

/// Opens the shared, accessible "show notes" dialog used everywhere episode
/// notes are shown — subscribed-episode actions and not-yet-subscribed search
/// previews alike — so the open announcement, heading, link handling, and
/// empty state stay identical app-wide (#305, #326).
void showEpisodeShowNotesDialog(
  BuildContext context, {
  required String title,
  required String? descriptionHtml,
}) {
  showDialog<void>(
    context: context,
    barrierLabel: 'Dismiss show notes',
    builder: (dialogContext) => AlertDialog(
      // Announced by VoiceOver/TalkBack when the dialog opens so the user
      // knows what surfaced.
      semanticLabel: 'Show notes',
      // The title heads the dialog so heading navigation lands on it; the open
      // announcement above already says "Show notes".
      title: Semantics(
        header: true,
        label: title,
        child: ExcludeSemantics(child: Text(title)),
      ),
      content: SingleChildScrollView(
        child: descriptionHtml != null
            ? Html(
                data: descriptionHtml,
                onLinkTap: (url, _, __) async {
                  if (url == null) return;
                  await safeLaunchUrl(url);
                },
              )
            : Text(
                'No show notes available.',
                style: Theme.of(dialogContext).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(dialogContext).colorScheme.onSurfaceVariant,
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
