import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// =============================================================================
// date_input_field.dart
//
// Reusable date input widget with separate YYYY / MM / DD boxes and a
// calendar icon that opens showDatePicker.
//
// API:
//   initialValue  — 'YYYY-MM-DD' string or null
//   onChanged     — called with 'YYYY-MM-DD' when all three fields are valid,
//                   or null when all fields are cleared
// =============================================================================

class DateInputField extends StatefulWidget {
  final String? initialValue;
  final ValueChanged<String?> onChanged;

  const DateInputField({
    super.key,
    this.initialValue,
    required this.onChanged,
  });

  @override
  State<DateInputField> createState() => _DateInputFieldState();
}

class _DateInputFieldState extends State<DateInputField> {
  late final TextEditingController _yearCtrl;
  late final TextEditingController _monthCtrl;
  late final TextEditingController _dayCtrl;
  final _yearFocus  = FocusNode();
  final _monthFocus = FocusNode();
  final _dayFocus   = FocusNode();

  @override
  void initState() {
    super.initState();
    String year = '', month = '', day = '';
    final v = widget.initialValue;
    if (v != null && v.contains('-')) {
      final parts = v.split('-');
      if (parts.length == 3) {
        year  = parts[0];
        month = parts[1];
        day   = parts[2];
      }
    }
    _yearCtrl  = TextEditingController(text: year);
    _monthCtrl = TextEditingController(text: month);
    _dayCtrl   = TextEditingController(text: day);
  }

  @override
  void dispose() {
    _yearCtrl.dispose();
    _monthCtrl.dispose();
    _dayCtrl.dispose();
    _yearFocus.dispose();
    _monthFocus.dispose();
    _dayFocus.dispose();
    super.dispose();
  }

  void _notify() {
    final y = _yearCtrl.text.trim();
    final m = _monthCtrl.text.trim();
    final d = _dayCtrl.text.trim();

    if (y.isEmpty && m.isEmpty && d.isEmpty) {
      widget.onChanged(null);
      return;
    }

    final yi = int.tryParse(y);
    final mi = int.tryParse(m);
    final di = int.tryParse(d);

    if (y.length == 4 && yi != null &&
        m.length == 2 && mi != null && mi >= 1 && mi <= 12 &&
        d.length == 2 && di != null && di >= 1 && di <= 31) {
      widget.onChanged('$y-${m.padLeft(2, '0')}-${d.padLeft(2, '0')}');
    }
  }

  Future<void> _pickDate() async {
    // Seed the picker with whatever is currently typed, falling back to today.
    DateTime initial = DateTime.now();
    final yi = int.tryParse(_yearCtrl.text.trim());
    final mi = int.tryParse(_monthCtrl.text.trim());
    final di = int.tryParse(_dayCtrl.text.trim());
    if (yi != null && mi != null && di != null) {
      try {
        initial = DateTime(yi, mi, di);
      } catch (_) {}
    }

    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );

    if (picked != null && mounted) {
      final y = '${picked.year}';
      final m = picked.month.toString().padLeft(2, '0');
      final d = picked.day.toString().padLeft(2, '0');
      setState(() {
        _yearCtrl.text  = y;
        _monthCtrl.text = m;
        _dayCtrl.text   = d;
      });
      widget.onChanged('$y-$m-$d');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        // ── Year ──────────────────────────────────────────────────────────────
        SizedBox(
          width: 68,
          child: TextField(
            controller: _yearCtrl,
            focusNode: _yearFocus,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(4),
            ],
            decoration: const InputDecoration(
              labelText: 'YYYY',
              border: OutlineInputBorder(),
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 6, vertical: 12),
            ),
            onChanged: (v) {
              if (v.length == 4) _monthFocus.requestFocus();
              _notify();
            },
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 4),
          child: Text('/', style: TextStyle(fontSize: 18, color: Colors.grey)),
        ),
        // ── Month ─────────────────────────────────────────────────────────────
        SizedBox(
          width: 52,
          child: TextField(
            controller: _monthCtrl,
            focusNode: _monthFocus,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(2),
            ],
            decoration: const InputDecoration(
              labelText: 'MM',
              border: OutlineInputBorder(),
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 6, vertical: 12),
            ),
            onChanged: (v) {
              if (v.length == 2) _dayFocus.requestFocus();
              _notify();
            },
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 4),
          child: Text('/', style: TextStyle(fontSize: 18, color: Colors.grey)),
        ),
        // ── Day ───────────────────────────────────────────────────────────────
        SizedBox(
          width: 52,
          child: TextField(
            controller: _dayCtrl,
            focusNode: _dayFocus,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(2),
            ],
            decoration: const InputDecoration(
              labelText: 'DD',
              border: OutlineInputBorder(),
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 6, vertical: 12),
            ),
            onChanged: (_) => _notify(),
          ),
        ),
        // ── Calendar picker ───────────────────────────────────────────────────
        IconButton(
          icon: const Icon(Icons.calendar_today),
          tooltip: 'Pick date',
          onPressed: _pickDate,
        ),
      ],
    );
  }
}
