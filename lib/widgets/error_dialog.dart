import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Shows a persistent, copyable error dialog.
///
/// Unlike a SnackBar, this dialog stays until the user dismisses it and
/// allows long-press or the Copy button to copy the error text.
Future<void> showErrorDialog(BuildContext context, dynamic error) {
  final message = error.toString().replaceAll('Exception: ', '');
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.error_outline, color: Colors.red, size: 32),
      title: const Text('Error'),
      content: SelectableText(message),
      actions: [
        TextButton.icon(
          icon: const Icon(Icons.copy, size: 16),
          label: const Text('Copy'),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: message));
            ScaffoldMessenger.of(ctx).showSnackBar(
              const SnackBar(content: Text('Copied to clipboard')),
            );
          },
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Dismiss'),
        ),
      ],
    ),
  );
}
