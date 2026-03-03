import 'package:flutter/material.dart';
import '../constants/date_constants.dart';
import '../models/match.dart';
import 'match_view_screen.dart';

// =============================================================================
// matches_screen.dart  (AOD v1.12)
//
// Matches tab shown inside RosterScreen's bottom navigation.
// Displays a list of matches created via the "Create Event" FAB.
// =============================================================================

class MatchesScreen extends StatelessWidget {
  final List<Match> matches;
  final bool isCoach;
  final String? currentTeamId;
  final void Function(Match updated)? onMatchUpdated;
  final void Function(String matchId)? onMatchDeleted;
  final void Function(Match added)? onMatchAdded;

  const MatchesScreen({
    super.key,
    this.matches = const [],
    this.isCoach = false,
    this.currentTeamId,
    this.onMatchUpdated,
    this.onMatchDeleted,
    this.onMatchAdded,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (matches.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sports, size: 72, color: cs.onSurface.withValues(alpha: 0.2)),
            const SizedBox(height: 16),
            Text(
              'No matches yet',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: cs.onSurface.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Tap "Create Event" to schedule a match.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: cs.onSurface.withValues(alpha: 0.4),
              ),
            ),
          ],
        ),
      );
    }

    // Sort ascending by date.
    final sorted = List<Match>.from(matches)..sort((a, b) => a.date.compareTo(b.date));

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      itemCount: sorted.length,
      separatorBuilder: (context, index) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final match = sorted[i];
        final isPast = match.date.isBefore(DateTime.now());

        return Card(
          elevation: isPast ? 0 : 2,
          color: isPast ? cs.surfaceContainerHighest : cs.surface,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => Navigator.push<Match?>(
              context,
              MaterialPageRoute(
                builder: (_) => MatchViewScreen(
                  match: match,
                  isCoach: isCoach,
                  currentTeamId: currentTeamId,
                ),
              ),
            ).then((result) {
              if (result == null) {
                // null means deleted
                onMatchDeleted?.call(match.id);
              } else if (result != match) {
                onMatchUpdated?.call(result);
              }
            }),
            child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Date badge
                Container(
                  width: 52,
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  decoration: BoxDecoration(
                    color: isPast
                        ? cs.onSurface.withValues(alpha: 0.08)
                        : cs.primary,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    children: [
                      Text(
                        kShortMonthNames[match.date.month - 1].toUpperCase(),
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: isPast ? cs.onSurface.withValues(alpha: 0.5) : cs.onPrimary,
                        ),
                      ),
                      Text(
                        '${match.date.day}',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: isPast ? cs.onSurface.withValues(alpha: 0.5) : cs.onPrimary,
                        ),
                      ),
                      Text(
                        '${match.date.year}',
                        style: TextStyle(
                          fontSize: 10,
                          color: isPast ? cs.onSurface.withValues(alpha: 0.4) : cs.onPrimary.withValues(alpha: 0.8),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        match.title,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                          color: isPast
                              ? cs.onSurface.withValues(alpha: 0.5)
                              : cs.onSurface,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            match.isHome ? Icons.home_outlined : Icons.directions_bus_outlined,
                            size: 14,
                            color: cs.onSurface.withValues(alpha: 0.55),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            match.locationLabel,
                            style: TextStyle(
                              fontSize: 13,
                              color: cs.onSurface.withValues(alpha: 0.55),
                            ),
                          ),
                        ],
                      ),
                      if (match.notes.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          match.notes,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: cs.onSurface.withValues(alpha: 0.5),
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          ), // InkWell
        );
      },
    );
  }
}
