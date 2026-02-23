// =============================================================================
// sport_autocomplete_field.dart  (AOD v1.7 — BUG FIX)
//
// BUG FIX (Notes.txt — Sport field typing):
//   The original _SportAutocompleteField was a StatelessWidget. Its
//   fieldViewBuilder set `textController.text = controller.text` on EVERY
//   rebuild. Because Flutter calls fieldViewBuilder during each frame while
//   the user is typing, this assignment ran mid-keystroke and replaced the
//   in-progress text with the last committed value — effectively swallowing
//   all but the final character typed.
//
//   Root cause: Flutter's Autocomplete widget creates its own internal
//   TextEditingController (textController) inside fieldViewBuilder. We must
//   only copy our external controller's value into it on the FIRST build,
//   not on every subsequent rebuild.
//
//   Fix: converted to a StatefulWidget. `_synced` boolean gates the initial
//   copy so subsequent rebuilds never touch the controller text.
//
// EXTRACTED (Notes.txt — optimization):
//   This widget was duplicated in team_selection_screen.dart AND
//   roster_screen.dart. It is now a standalone file so both screens import
//   one source of truth, eliminating the duplication.
//
// USAGE:
//   SportAutocompleteField(
//     controller: sportSearchController,   // external TextEditingController
//     sports: _sports,                     // List<Map<String,dynamic>> from DB
//     initialSportId: selectedSportId,     // optional; just for documentation
//     onSelected: (name, id) { ... },      // called on pick OR typed change
//   )
// =============================================================================

import 'package:flutter/material.dart';

class SportAutocompleteField extends StatefulWidget {
  /// External controller that holds the current sport name text.
  final TextEditingController controller;

  /// Full list of sports from the DB (id, name, category).
  final List<Map<String, dynamic>> sports;

  /// The currently selected sport_id — informational only; not mutated here.
  final String? initialSportId;

  /// Called when the user picks a suggestion OR types a custom value.
  /// [id] is null when the user typed a value not present in the list.
  final void Function(String name, String? id) onSelected;

  const SportAutocompleteField({
    super.key,
    required this.controller,
    required this.sports,
    this.initialSportId,
    required this.onSelected,
  });

  @override
  State<SportAutocompleteField> createState() => _SportAutocompleteFieldState();
}

class _SportAutocompleteFieldState extends State<SportAutocompleteField> {
  // BUG FIX: gate flag — we copy the external controller's text into the
  // Autocomplete's internal textController exactly once (on first build).
  // Without this, the assignment runs on every rebuild and overwrites the
  // user's in-progress typing.
  bool _synced = false;

  @override
  Widget build(BuildContext context) {
    return Autocomplete<Map<String, dynamic>>(
      // Seed the initial text shown in the field from the external controller.
      initialValue: TextEditingValue(text: widget.controller.text),

      // Filter the sports list to match whatever the user has typed so far.
      optionsBuilder: (TextEditingValue textEditingValue) {
        final query = textEditingValue.text.toLowerCase();
        if (query.isEmpty) return widget.sports;
        return widget.sports.where(
          (s) => (s['name'] as String).toLowerCase().contains(query),
        );
      },

      // What string to show in the field after a suggestion is selected.
      displayStringForOption: (s) => s['name'] as String,

      // Build the visible text input.
      fieldViewBuilder: (context, textController, focusNode, onSubmitted) {
        // BUG FIX: only copy our value on the first build.
        // All subsequent rebuilds leave textController alone so the user's
        // in-progress input is not wiped.
        if (!_synced) {
          textController.text = widget.controller.text;
          _synced = true;
        }

        return TextFormField(
          controller: textController,
          focusNode: focusNode,
          decoration: const InputDecoration(
            labelText: 'Sport',
            hintText: 'e.g., Basketball (Boys)',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.sports),
          ),
          onChanged: (v) {
            // Keep external controller in sync so the parent can read the value.
            widget.controller.text = v;
            // Typed value that doesn't match a list item → sport_id = null.
            widget.onSelected(v, null);
          },
          onFieldSubmitted: (_) => onSubmitted(),
        );
      },

      // Build the dropdown list of matching options.
      optionsViewBuilder: (context, onOptionSelected, options) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: options.length,
                itemBuilder: (_, i) {
                  final sport = options.elementAt(i);
                  return ListTile(
                    title: Text(sport['name'] as String),
                    subtitle: Text(sport['category'] as String? ?? ''),
                    onTap: () => onOptionSelected(sport),
                  );
                },
              ),
            ),
          ),
        );
      },

      // User picked a suggestion from the dropdown.
      onSelected: (sport) {
        widget.controller.text = sport['name'] as String;
        widget.onSelected(
          sport['name'] as String,
          sport['id'] as String?,
        );
      },
    );
  }
}