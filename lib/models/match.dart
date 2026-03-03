// =============================================================================
// match.dart  (AOD v1.22+)
//
// Match model — persisted to public.matches in Supabase.
// Fields mirror the DB columns defined in supabase_script.md.
// =============================================================================

class Match {
  final String id;
  final String teamId;
  final String myTeamName;
  final String opponentName;
  final DateTime date;
  final bool isHome; // true = Home, false = Away
  final String notes;
  final DateTime? createdAt;
  // selectedRosterId is persisted to matches.selected_roster_id;
  // selectedRosterName is in-memory only (derived from the roster title).
  final String? selectedRosterId;
  final String? selectedRosterName;
  // isStaged is persisted to matches.is_staged; set by the match owner when
  // they confirm they are ready — shown as a green checkmark on both screens.
  final bool isStaged;
  // linkedMatchId is the opposing team's match row. Set after invite redemption.
  final String? linkedMatchId;
  // isGuestMatch is true for match rows created when a team accepts a match
  // invite (Team B). Guest teams cannot modify match settings or create invites.
  final bool isGuestMatch;

  const Match({
    required this.id,
    required this.teamId,
    required this.myTeamName,
    required this.opponentName,
    required this.date,
    required this.isHome,
    this.notes = '',
    this.createdAt,
    this.selectedRosterId,
    this.selectedRosterName,
    this.isStaged = false,
    this.linkedMatchId,
    this.isGuestMatch = false,
  });

  String get title => '$myTeamName vs. $opponentName';
  String get locationLabel => isHome ? 'Home' : 'Away';

  factory Match.fromMap(Map<String, dynamic> m) => Match(
        id: m['id'] as String,
        teamId: m['team_id'] as String,
        myTeamName: m['my_team_name'] as String,
        opponentName: m['opponent_name'] as String,
        date: DateTime.parse(m['match_date'] as String).toLocal(),
        isHome: m['is_home'] as bool? ?? true,
        notes: m['notes'] as String? ?? '',
        createdAt: m['created_at'] != null
            ? DateTime.parse(m['created_at'] as String).toLocal()
            : null,
        selectedRosterId: m['selected_roster_id'] as String?,
        isStaged: m['is_staged'] as bool? ?? false,
        linkedMatchId: m['linked_match_id'] as String?,
        isGuestMatch: m['is_guest_match'] as bool? ?? false,
      );

  Map<String, dynamic> toMap() => {
        'team_id': teamId,
        'my_team_name': myTeamName,
        'opponent_name': opponentName,
        'match_date': date.toUtc().toIso8601String(),
        'is_home': isHome,
        'notes': notes,
      };

  Match copyWith({
    String? id,
    String? teamId,
    String? myTeamName,
    String? opponentName,
    DateTime? date,
    bool? isHome,
    String? notes,
    DateTime? createdAt,
    Object? selectedRosterId = _sentinel,
    Object? selectedRosterName = _sentinel,
    bool? isStaged,
    Object? linkedMatchId = _sentinel,
    bool? isGuestMatch,
  }) =>
      Match(
        id: id ?? this.id,
        teamId: teamId ?? this.teamId,
        myTeamName: myTeamName ?? this.myTeamName,
        opponentName: opponentName ?? this.opponentName,
        date: date ?? this.date,
        isHome: isHome ?? this.isHome,
        notes: notes ?? this.notes,
        createdAt: createdAt ?? this.createdAt,
        selectedRosterId: identical(selectedRosterId, _sentinel)
            ? this.selectedRosterId
            : selectedRosterId as String?,
        selectedRosterName: identical(selectedRosterName, _sentinel)
            ? this.selectedRosterName
            : selectedRosterName as String?,
        isStaged: isStaged ?? this.isStaged,
        linkedMatchId: identical(linkedMatchId, _sentinel)
            ? this.linkedMatchId
            : linkedMatchId as String?,
        isGuestMatch: isGuestMatch ?? this.isGuestMatch,
      );
}

const Object _sentinel = Object();
