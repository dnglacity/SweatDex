import 'dart:convert';
import 'package:csv/csv.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/player.dart';
import '../services/player_service.dart';

// =============================================================================
// csv_import_screen.dart  (AOD v1.22)
//
// Allows a coach to populate their team roster by uploading a CSV file.
//
// Flow:
//   1. Coach downloads the template CSV (shows required/optional columns).
//   2. Coach picks a .csv file from their device.
//   3. App parses the file, validates rows, and shows a preview table.
//   4. Coach taps "Import" — rows are batch-inserted via PlayerService.
//
// CSV columns (case-insensitive header matching):
//   Required : first_name, last_name
//   Optional : jersey_number, position, nickname, athlete_email, guardian_email
// =============================================================================

class CsvImportScreen extends StatefulWidget {
  final String teamId;

  const CsvImportScreen({super.key, required this.teamId});

  @override
  State<CsvImportScreen> createState() => _CsvImportScreenState();
}

class _CsvImportScreenState extends State<CsvImportScreen> {
  final _service = PlayerService();

  // Parsed rows ready to preview/import.
  List<_CsvRow> _rows = [];
  String? _fileName;
  bool _importing = false;
  String? _parseError;

  // ── Template ───────────────────────────────────────────────────────────────

  static const _templateCsv =
      'first_name,last_name,jersey_number,position,nickname,athlete_email,guardian_email\n'
      'Jane,Smith,10,Forward,,jane@example.com,parent@example.com\n'
      'Marcus,Jones,5,Guard,MJ,,\n';

  void _downloadTemplate() {
    if (kIsWeb) {
      // On web, encode as a data URI and trigger a browser download.
      final bytes = utf8.encode(_templateCsv);
      final b64 = base64Encode(bytes);
      // Use a hidden anchor click via JS interop.
      // ignore: undefined_prefixed_name
      _triggerWebDownload(b64);
    } else {
      // On mobile/desktop, copy to clipboard and notify the user.
      Clipboard.setData(const ClipboardData(text: _templateCsv));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Template CSV copied to clipboard — paste into a spreadsheet app.'),
          duration: Duration(seconds: 4),
        ),
      );
    }
  }

  // On web: inject a temporary <a> element and click it.
  void _triggerWebDownload(String b64) {
    // Using dart:html is not available in non-web builds, so we use a
    // platform channel / js interop via url_launcher approach:
    // Since url_launcher isn't a dependency we use Clipboard as fallback.
    Clipboard.setData(const ClipboardData(text: _templateCsv));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Template copied to clipboard — paste into Excel or Google Sheets and save as CSV.'),
        duration: Duration(seconds: 5),
      ),
    );
  }

  // ── File picking & parsing ─────────────────────────────────────────────────

  Future<void> _pickFile() async {
    setState(() {
      _parseError = null;
      _rows = [];
      _fileName = null;
    });

    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv'],
        withData: true, // needed for web
      );
    } catch (e) {
      setState(() => _parseError = 'Could not open file picker: $e');
      return;
    }

    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null) {
      setState(() => _parseError = 'Could not read file contents.');
      return;
    }

    final content = utf8.decode(bytes, allowMalformed: true);
    _parseCsv(content, file.name);
  }

  void _parseCsv(String content, String name) {
    try {
      final rows = const CsvToListConverter(eol: '\n').convert(content);
      if (rows.isEmpty) {
        setState(() => _parseError = 'The file appears to be empty.');
        return;
      }

      // Normalise header row.
      final header = rows.first
          .map((c) => c.toString().trim().toLowerCase().replaceAll(' ', '_'))
          .toList();

      int col(String key) => header.indexOf(key);

      final fnIdx = col('first_name');
      final lnIdx = col('last_name');

      if (fnIdx < 0 || lnIdx < 0) {
        setState(() => _parseError =
            'Missing required columns. The header row must contain "first_name" and "last_name".');
        return;
      }

      String? cell(List<dynamic> row, int idx) {
        if (idx < 0 || idx >= row.length) return null;
        final v = row[idx].toString().trim();
        return v.isEmpty ? null : v;
      }

      final parsed = <_CsvRow>[];
      for (var i = 1; i < rows.length; i++) {
        final r = rows[i];
        final fn = cell(r, fnIdx);
        final ln = cell(r, lnIdx);
        if (fn == null && ln == null) continue; // skip blank rows

        parsed.add(_CsvRow(
          rowNumber: i + 1,
          firstName: fn ?? '',
          lastName: ln ?? '',
          jerseyNumber: cell(r, col('jersey_number')),
          position: cell(r, col('position')),
          nickname: cell(r, col('nickname')),
          athleteEmail: cell(r, col('athlete_email')),
          guardianEmail: cell(r, col('guardian_email')),
          error: (fn == null || fn.isEmpty || ln == null || ln.isEmpty)
              ? 'first_name and last_name are required'
              : null,
        ));
      }

      if (parsed.isEmpty) {
        setState(() => _parseError = 'No data rows found after the header.');
        return;
      }

      setState(() {
        _rows = parsed;
        _fileName = name;
        _parseError = null;
      });
    } catch (e) {
      setState(() => _parseError = 'Failed to parse CSV: $e');
    }
  }

  // ── Import ─────────────────────────────────────────────────────────────────

  List<_CsvRow> get _validRows => _rows.where((r) => r.error == null).toList();

  Future<void> _import() async {
    final valid = _validRows;
    if (valid.isEmpty) return;

    setState(() => _importing = true);

    final players = valid
        .map((r) => Player(
              id: '',
              teamId: widget.teamId,
              firstName: r.firstName,
              lastName: r.lastName,
              jerseyNumber: r.jerseyNumber,
              position: r.position,
              nickname: r.nickname,
              athleteEmail: r.athleteEmail,
              guardianEmail: r.guardianEmail,
              status: 'present',
            ))
        .toList();

    try {
      final count = await _service.bulkAddPlayers(players);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$count player${count == 1 ? '' : 's'} imported successfully.')),
      );
      Navigator.pop(context, true); // true → caller should refresh roster
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString().replaceFirst('Exception: ', '');
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Import Errors'),
          content: SingleChildScrollView(child: Text(msg)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  // ── UI ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasRows = _rows.isNotEmpty;
    final errorCount = _rows.where((r) => r.error != null).length;
    final validCount = _validRows.length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Import Roster from CSV'),
        actions: [
          if (hasRows && validCount > 0)
            FilledButton.icon(
              onPressed: _importing ? null : _import,
              icon: _importing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.upload, size: 18),
              label: Text('Import $validCount'),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: theme.colorScheme.primary,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              ),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Instructions card ──────────────────────────────────────────
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('How to import', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    const Text(
                      '1. Download the template and fill it in.\n'
                      '2. Save as CSV (.csv) and pick the file below.\n'
                      '3. Review the preview, then tap Import.',
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _downloadTemplate,
                      icon: const Icon(Icons.download, size: 18),
                      label: const Text('Download Template CSV'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // ── File picker ────────────────────────────────────────────────
            Row(
              children: [
                FilledButton.icon(
                  onPressed: _pickFile,
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: const Text('Choose CSV File'),
                ),
                const SizedBox(width: 12),
                if (_fileName != null)
                  Expanded(
                    child: Text(
                      _fileName!,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
              ],
            ),

            // ── Parse error ────────────────────────────────────────────────
            if (_parseError != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline, color: theme.colorScheme.error, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _parseError!,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // ── Summary banner ─────────────────────────────────────────────
            if (hasRows) ...[
              const SizedBox(height: 12),
              _SummaryBanner(validCount: validCount, errorCount: errorCount),
            ],

            // ── Preview table ──────────────────────────────────────────────
            if (hasRows) ...[
              const SizedBox(height: 12),
              Expanded(child: _PreviewTable(rows: _rows)),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Summary banner ─────────────────────────────────────────────────────────

class _SummaryBanner extends StatelessWidget {
  final int validCount;
  final int errorCount;

  const _SummaryBanner({required this.validCount, required this.errorCount});

  @override
  Widget build(BuildContext context) {
    final hasErrors = errorCount > 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: hasErrors ? Colors.orange.shade50 : Colors.green.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: hasErrors ? Colors.orange.shade200 : Colors.green.shade200,
        ),
      ),
      child: Row(
        children: [
          Icon(
            hasErrors ? Icons.warning_amber_rounded : Icons.check_circle_outline,
            size: 18,
            color: hasErrors ? Colors.orange.shade700 : Colors.green.shade700,
          ),
          const SizedBox(width: 8),
          Text(
            hasErrors
                ? '$validCount row${validCount == 1 ? '' : 's'} ready · $errorCount with errors (will be skipped)'
                : '$validCount row${validCount == 1 ? '' : 's'} ready to import',
            style: TextStyle(
              color: hasErrors ? Colors.orange.shade800 : Colors.green.shade800,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Preview table ──────────────────────────────────────────────────────────

class _PreviewTable extends StatelessWidget {
  final List<_CsvRow> rows;

  const _PreviewTable({required this.rows});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          headingRowColor: WidgetStateProperty.all(
            theme.colorScheme.surfaceContainerHighest,
          ),
          columnSpacing: 16,
          columns: const [
            DataColumn(label: Text('#')),
            DataColumn(label: Text('First Name')),
            DataColumn(label: Text('Last Name')),
            DataColumn(label: Text('Jersey')),
            DataColumn(label: Text('Position')),
            DataColumn(label: Text('Nickname')),
            DataColumn(label: Text('Athlete Email')),
            DataColumn(label: Text('Guardian Email')),
            DataColumn(label: Text('Status')),
          ],
          rows: rows.map((r) {
            final isError = r.error != null;
            return DataRow(
              color: isError
                  ? WidgetStateProperty.all(Colors.red.shade50)
                  : null,
              cells: [
                DataCell(Text('${r.rowNumber}')),
                DataCell(
                  isError
                      ? Tooltip(
                          message: r.error!,
                          child: Text(r.firstName,
                              style: const TextStyle(color: Colors.red)),
                        )
                      : Text(r.firstName),
                ),
                DataCell(Text(r.lastName)),
                DataCell(Text(r.jerseyNumber ?? '')),
                DataCell(Text(r.position ?? '')),
                DataCell(Text(r.nickname ?? '')),
                DataCell(Text(r.athleteEmail ?? '')),
                DataCell(Text(r.guardianEmail ?? '')),
                DataCell(
                  isError
                      ? const Icon(Icons.error_outline, color: Colors.red, size: 18)
                      : const Icon(Icons.check_circle_outline, color: Colors.green, size: 18),
                ),
              ],
            );
          }).toList(),
        ),
      ),
    );
  }
}

// ── Data class for a parsed CSV row ────────────────────────────────────────

class _CsvRow {
  final int rowNumber;
  final String firstName;
  final String lastName;
  final String? jerseyNumber;
  final String? position;
  final String? nickname;
  final String? athleteEmail;
  final String? guardianEmail;
  final String? error; // non-null means row will be skipped

  const _CsvRow({
    required this.rowNumber,
    required this.firstName,
    required this.lastName,
    this.jerseyNumber,
    this.position,
    this.nickname,
    this.athleteEmail,
    this.guardianEmail,
    this.error,
  });
}
