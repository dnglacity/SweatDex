// =============================================================================
// match_format_screen.dart  (AOD v1.13)
//
// Lists all Match Format templates for a team and allows coaches to create,
// view, and delete them.  Each template has a name and a list of sections,
// where each section has a title and a position count.
// =============================================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/player_service.dart';

// ---------------------------------------------------------------------------
// Data model
// ---------------------------------------------------------------------------

class MatchFormatSection {
  String title;
  int positionCount;

  MatchFormatSection({required this.title, required this.positionCount});

  factory MatchFormatSection.fromMap(Map<String, dynamic> m) =>
      MatchFormatSection(
        title: m['title'] as String? ?? '',
        positionCount: (m['position_count'] as int?) ?? 1,
      );

  Map<String, dynamic> toMap() => {
        'title': title,
        'position_count': positionCount,
      };
}

class MatchFormatTemplate {
  final String id;
  final String teamId;
  final String name;
  final String? sport;
  final List<MatchFormatSection> sections;
  final DateTime? createdAt;

  const MatchFormatTemplate({
    required this.id,
    required this.teamId,
    required this.name,
    this.sport,
    required this.sections,
    this.createdAt,
  });

  factory MatchFormatTemplate.fromMap(Map<String, dynamic> m) =>
      MatchFormatTemplate(
        id: m['id'] as String,
        teamId: (m['team_id'] as String?) ?? '',
        name: m['name'] as String,
        sport: m['sport'] as String?,
        sections: (m['sections'] as List<dynamic>? ?? [])
            .cast<Map<String, dynamic>>()
            .map(MatchFormatSection.fromMap)
            .toList(),
        createdAt: m['created_at'] != null
            ? DateTime.parse(m['created_at'] as String).toLocal()
            : null,
      );
}

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

class MatchFormatScreen extends StatefulWidget {
  final String teamId;

  const MatchFormatScreen({super.key, required this.teamId});

  @override
  State<MatchFormatScreen> createState() => _MatchFormatScreenState();
}

class _MatchFormatScreenState extends State<MatchFormatScreen> {
  final _service = PlayerService();

  List<MatchFormatTemplate> _templates = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await _service.getMatchFormatTemplates(widget.teamId);
      setState(() {
        _templates = rows.map(MatchFormatTemplate.fromMap).toList();
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _delete(MatchFormatTemplate t) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Format'),
        content: Text('Delete "${t.name}"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              'Delete',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _service.deleteMatchFormatTemplate(t.id);
      setState(() => _templates.removeWhere((x) => x.id == t.id));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  void _openEdit(MatchFormatTemplate t) async {
    final updated = await showModalBottomSheet<MatchFormatTemplate>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => EditFormatSheet(template: t),
    );
    if (updated != null) {
      setState(() {
        final i = _templates.indexWhere((x) => x.id == updated.id);
        if (i != -1) _templates[i] = updated;
      });
    }
  }

  void _openCreate() async {
    final created = await showModalBottomSheet<MatchFormatTemplate>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _CreateFormatSheet(teamId: widget.teamId),
    );
    if (created != null) {
      setState(() => _templates.add(created));
    }
  }

  void _openDetail(MatchFormatTemplate t) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _FormatDetailSheet(template: t),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Match Formats'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'New Format',
            onPressed: _openCreate,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Error loading formats', style: TextStyle(color: cs.error)),
                      const SizedBox(height: 8),
                      TextButton(onPressed: _load, child: const Text('Retry')),
                    ],
                  ),
                )
              : _templates.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.format_list_bulleted_outlined,
                              size: 56, color: cs.onSurface.withValues(alpha: 0.3)),
                          const SizedBox(height: 12),
                          Text(
                            'No formats yet',
                            style: TextStyle(
                                color: cs.onSurface.withValues(alpha: 0.5)),
                          ),
                          const SizedBox(height: 8),
                          FilledButton.icon(
                            onPressed: _openCreate,
                            icon: const Icon(Icons.add),
                            label: const Text('Create Format'),
                          ),
                        ],
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: _templates.length,
                      separatorBuilder: (context, index) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final t = _templates[i];
                        final sectionCount = t.sections.length;
                        return ListTile(
                          title: Text(t.name,
                              style: const TextStyle(fontWeight: FontWeight.w600)),
                          subtitle: Text(
                            sectionCount == 0
                                ? 'No sections'
                                : '$sectionCount ${sectionCount == 1 ? 'section' : 'sections'}',
                          ),
                          leading: const Icon(Icons.format_list_bulleted_outlined),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.edit_outlined),
                                tooltip: 'Edit',
                                onPressed: () => _openEdit(t),
                              ),
                              IconButton(
                                icon: Icon(Icons.delete_outline, color: cs.error),
                                tooltip: 'Delete',
                                onPressed: () => _delete(t),
                              ),
                            ],
                          ),
                          onTap: () => _openDetail(t),
                        );
                      },
                    ),
    );
  }
}

// ---------------------------------------------------------------------------
// Detail sheet — read-only view of a single template's sections
// ---------------------------------------------------------------------------

class _FormatDetailSheet extends StatelessWidget {
  final MatchFormatTemplate template;

  const _FormatDetailSheet({required this.template});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.35,
      maxChildSize: 0.92,
      builder: (_, controller) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 12),
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: cs.onSurface.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(template.name,
                style: tt.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              '${template.sections.length} section${template.sections.length == 1 ? '' : 's'}',
              style: TextStyle(color: cs.onSurface.withValues(alpha: 0.6)),
            ),
            const Divider(height: 24),
            Expanded(
              child: template.sections.isEmpty
                  ? Center(
                      child: Text('No sections',
                          style: TextStyle(
                              color: cs.onSurface.withValues(alpha: 0.4))))
                  : ListView.builder(
                      controller: controller,
                      itemCount: template.sections.length,
                      itemBuilder: (_, i) {
                        final s = template.sections[i];
                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            title: Text(s.title,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600)),
                            trailing: Chip(
                              label: Text(
                                '${s.positionCount} position${s.positionCount == 1 ? '' : 's'}',
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Edit format sheet
// ---------------------------------------------------------------------------

class EditFormatSheet extends StatefulWidget {
  final MatchFormatTemplate template;

  /// When provided, a Delete button is shown and this callback is invoked
  /// after the template is successfully deleted (sheet is popped with null).
  final VoidCallback? onDeleted;

  const EditFormatSheet({super.key, required this.template, this.onDeleted});

  @override
  State<EditFormatSheet> createState() => _EditFormatSheetState();
}

class _EditFormatSheetState extends State<EditFormatSheet> {
  final _service = PlayerService();
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;

  late final List<_SectionDraft> _sections;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.template.name);
    _sections = widget.template.sections
        .map((s) => _SectionDraft()
          ..titleCtrl.text = s.title
          ..countCtrl.text = s.positionCount.toString())
        .toList();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    for (final s in _sections) {
      s.dispose();
    }
    super.dispose();
  }

  void _addSection() => setState(() => _sections.add(_SectionDraft()));

  void _removeSection(int i) {
    setState(() {
      _sections[i].dispose();
      _sections.removeAt(i);
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final sections = _sections
        .map((s) => MatchFormatSection(
              title: s.titleCtrl.text.trim(),
              positionCount: int.tryParse(s.countCtrl.text.trim()) ?? 1,
            ))
        .toList();

    try {
      final row = await _service.updateMatchFormatTemplate(
        templateId: widget.template.id,
        name: _nameCtrl.text.trim(),
        sections: sections.map((s) => s.toMap()).toList(),
      );
      if (mounted) Navigator.pop(context, MatchFormatTemplate.fromMap(row));
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Format'),
        content:
            Text('Delete "${widget.template.name}"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Delete',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.error)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _saving = true);
    try {
      await _service.deleteMatchFormatTemplate(widget.template.id);
      if (mounted) {
        Navigator.pop(context, null);
        widget.onDeleted?.call();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: cs.onSurface.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Text(
                'Edit Match Format',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 20),
              TextFormField(
                controller: _nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Format Name *',
                  border: OutlineInputBorder(),
                ),
                textCapitalization: TextCapitalization.words,
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Text('Sections',
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _addSection,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add Section'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_sections.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'No sections yet. Tap "Add Section" to build your format.',
                    style: TextStyle(
                        color: cs.onSurface.withValues(alpha: 0.5),
                        fontSize: 13),
                  ),
                ),
              for (int i = 0; i < _sections.length; i++) ...[
                _SectionRow(
                  draft: _sections[i],
                  index: i,
                  onRemove: () => _removeSection(i),
                ),
                const SizedBox(height: 10),
              ],
              const SizedBox(height: 8),
              Row(
                children: [
                  if (widget.onDeleted != null) ...[
                    OutlinedButton(
                      onPressed: _saving ? null : _delete,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: cs.error,
                        side: BorderSide(color: cs.error),
                      ),
                      child: const Text('Delete'),
                    ),
                    const Spacer(),
                  ],
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Save Changes'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Create format sheet
// ---------------------------------------------------------------------------

class _CreateFormatSheet extends StatefulWidget {
  final String teamId;

  const _CreateFormatSheet({required this.teamId});

  @override
  State<_CreateFormatSheet> createState() => _CreateFormatSheetState();
}

class _CreateFormatSheetState extends State<_CreateFormatSheet> {
  final _service = PlayerService();
  final _formKey = GlobalKey<FormState>();
  final _nameCtrl = TextEditingController();

  final List<_SectionDraft> _sections = [];
  bool _saving = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    for (final s in _sections) {
      s.dispose();
    }
    super.dispose();
  }

  void _addSection() {
    setState(() => _sections.add(_SectionDraft()));
  }

  void _removeSection(int i) {
    setState(() {
      _sections[i].dispose();
      _sections.removeAt(i);
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final sections = _sections
        .map((s) => MatchFormatSection(
              title: s.titleCtrl.text.trim(),
              positionCount: int.tryParse(s.countCtrl.text.trim()) ?? 1,
            ))
        .toList();

    try {
      final row = await _service.createMatchFormatTemplate(
        teamId: widget.teamId,
        name: _nameCtrl.text.trim(),
        sections: sections.map((s) => s.toMap()).toList(),
      );
      if (mounted) Navigator.pop(context, MatchFormatTemplate.fromMap(row));
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Handle
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: cs.onSurface.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Text(
                'New Match Format',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 20),

              // Format name
              TextFormField(
                controller: _nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Format Name *',
                  hintText: 'e.g. High School Basketball',
                  border: OutlineInputBorder(),
                ),
                textCapitalization: TextCapitalization.words,
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 20),

              // Sections header
              Row(
                children: [
                  Text('Sections',
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _addSection,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add Section'),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              if (_sections.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'No sections yet. Tap "Add Section" to build your format.',
                    style: TextStyle(
                        color: cs.onSurface.withValues(alpha: 0.5),
                        fontSize: 13),
                  ),
                ),

              // Section rows
              for (int i = 0; i < _sections.length; i++) ...[
                _SectionRow(
                  draft: _sections[i],
                  index: i,
                  onRemove: () => _removeSection(i),
                ),
                const SizedBox(height: 10),
              ],

              const SizedBox(height: 8),

              // Save button
              FilledButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Save Format'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Draft state for a single section row
// ---------------------------------------------------------------------------

class _SectionDraft {
  final TextEditingController titleCtrl = TextEditingController();
  final TextEditingController countCtrl = TextEditingController(text: '1');

  void dispose() {
    titleCtrl.dispose();
    countCtrl.dispose();
  }
}

class _SectionRow extends StatelessWidget {
  final _SectionDraft draft;
  final int index;
  final VoidCallback onRemove;

  const _SectionRow({
    required this.draft,
    required this.index,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Section title
        Expanded(
          flex: 3,
          child: TextFormField(
            controller: draft.titleCtrl,
            decoration: InputDecoration(
              labelText: 'Section ${index + 1} Title *',
              hintText: 'e.g. 1st Quarter',
              border: const OutlineInputBorder(),
            ),
            textCapitalization: TextCapitalization.words,
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? 'Required' : null,
          ),
        ),
        const SizedBox(width: 8),
        // Position count
        SizedBox(
          width: 88,
          child: TextFormField(
            controller: draft.countCtrl,
            decoration: const InputDecoration(
              labelText: 'Positions *',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            validator: (v) {
              final n = int.tryParse(v ?? '');
              if (n == null || n < 1) return 'Min 1';
              return null;
            },
          ),
        ),
        const SizedBox(width: 4),
        // Remove button
        IconButton(
          icon: Icon(Icons.remove_circle_outline, color: cs.error),
          tooltip: 'Remove section',
          onPressed: onRemove,
        ),
      ],
    );
  }
}
