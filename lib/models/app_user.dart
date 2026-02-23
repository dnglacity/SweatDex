// =============================================================================
// app_user.dart  (AOD v1.7)
//
// CHANGE (Notes.txt v1.7):
//   • Split `name` into `firstName` + `lastName` (DB trigger keeps `name`
//     column in sync for backwards compatibility).
//   • Added `nickname` — the user's own default display nickname.
//     Coaches may override this locally on their roster; this is the account-
//     level default.
//   • Added `athleteId` — optional athlete/student ID entered at sign-up or
//     editable in Account Settings.
//
// TeamMember changes:
//   • `roleLabel` updated with new roles: 'team_parent', 'team_manager'.
//   • Convenience getters updated.
// =============================================================================

class AppUser {
  /// Primary key — same UUID as auth.users.id.
  final String id;

  /// auth.users.id — used to resolve the current user's profile.
  final String userId;

  // CHANGE (v1.7): first + last name stored separately.
  final String firstName;
  final String lastName;

  /// Concatenated display name (kept in sync by DB trigger sync_user_name).
  String get name => '${firstName.trim()} ${lastName.trim()}'.trim();

  /// User's own default display nickname (optional).
  // CHANGE (v1.7): coaches can override this on their local roster view.
  final String? nickname;

  /// Optional athlete / student ID.
  // CHANGE (v1.7): entered at sign-up or editable in Account Settings.
  final String? athleteId;

  /// Email address — copied from auth.users at trigger time.
  final String email;

  /// Optional school / club / organization name.
  final String? organization;

  final DateTime? createdAt;

  const AppUser({
    required this.id,
    required this.userId,
    required this.firstName,
    required this.lastName,
    this.nickname,
    this.athleteId,
    required this.email,
    this.organization,
    this.createdAt,
  });

  // ── Deserialise from Supabase row ──────────────────────────────────────────
  factory AppUser.fromMap(Map<String, dynamic> map) {
    // Support both old `name` column and new first_name/last_name columns.
    // If first_name is absent (old row), split the name field as a fallback.
    final rawFirst = map['first_name'] as String?;
    final rawLast  = map['last_name']  as String?;
    String first   = rawFirst ?? '';
    String last    = rawLast  ?? '';

    if (first.isEmpty && last.isEmpty) {
      // Fallback: split the legacy name column on the first space.
      final legacyName = map['name'] as String? ?? '';
      final spaceIdx   = legacyName.indexOf(' ');
      if (spaceIdx > 0) {
        first = legacyName.substring(0, spaceIdx);
        last  = legacyName.substring(spaceIdx + 1);
      } else {
        first = legacyName;
      }
    }

    return AppUser(
      id:           map['id']           as String? ?? '',
      userId:       map['user_id']      as String? ?? '',
      firstName:    first,
      lastName:     last,
      nickname:     map['nickname']     as String?,
      athleteId:    map['athlete_id']   as String?,
      email:        map['email']        as String? ?? '',
      organization: map['organization'] as String?,
      createdAt:    map['created_at'] != null
                      ? DateTime.tryParse(map['created_at'] as String)
                      : null,
    );
  }

  // ── Serialise for update ───────────────────────────────────────────────────
  Map<String, dynamic> toMap() {
    return {
      'user_id':      userId,
      'first_name':   firstName,
      'last_name':    lastName,
      'email':        email,
      if (nickname     != null) 'nickname':     nickname,
      if (athleteId    != null) 'athlete_id':   athleteId,
      if (organization != null) 'organization': organization,
    };
  }

  // ── Copy helper ────────────────────────────────────────────────────────────
  AppUser copyWith({
    String? id,
    String? userId,
    String? firstName,
    String? lastName,
    String? nickname,
    String? athleteId,
    String? email,
    String? organization,
    DateTime? createdAt,
  }) {
    return AppUser(
      id:           id           ?? this.id,
      userId:       userId       ?? this.userId,
      firstName:    firstName    ?? this.firstName,
      lastName:     lastName     ?? this.lastName,
      nickname:     nickname     ?? this.nickname,
      athleteId:    athleteId    ?? this.athleteId,
      email:        email        ?? this.email,
      organization: organization ?? this.organization,
      createdAt:    createdAt    ?? this.createdAt,
    );
  }
}

// =============================================================================
// TeamMember  (AOD v1.7)
//
// CHANGE (v1.7):
//   • New roles added: 'team_parent' | 'team_manager'
//     Valid set: 'owner' | 'coach' | 'player' | 'team_parent' | 'team_manager'
//   • roleLabel, isCoach getters updated.
//   • firstName + lastName fields added for display.
// =============================================================================

class TeamMember {
  final String teamMemberId; // team_members.id (PK)
  final String teamId;
  final String userId;       // public.users.id
  final String role;         // see valid set above
  final String? playerId;    // players.id — set when role == 'player'

  // Denormalised user profile (joined from users table).
  final String firstName;
  final String lastName;
  final String email;
  final String? organization;

  const TeamMember({
    required this.teamMemberId,
    required this.teamId,
    required this.userId,
    required this.role,
    this.playerId,
    required this.firstName,
    required this.lastName,
    required this.email,
    this.organization,
  });

  // ── Convenience display name ───────────────────────────────────────────────
  /// Full name — uses first + last; falls back to email prefix.
  String get name {
    final full = '${firstName.trim()} ${lastName.trim()}'.trim();
    return full.isNotEmpty ? full : email;
  }

  // ── Convenience role checks ────────────────────────────────────────────────
  bool get isOwner   => role == 'owner';
  /// True for any role that can manage the roster.
  bool get isCoach   => role == 'coach' || role == 'owner' || role == 'team_manager';
  bool get isPlayer  => role == 'player';
  bool get isGuardian => role == 'team_parent';
  bool get isManager  => role == 'team_manager';

  // ── Deserialise from a joined Supabase row ─────────────────────────────────
  // Shape: { id, team_id, user_id, role, player_id,
  //          users: { first_name, last_name, name, email, organization } }
  factory TeamMember.fromMap(Map<String, dynamic> map) {
    final userMap = map['users'] as Map<String, dynamic>? ?? {};

    // Support both new first_name/last_name and old name column.
    final rawFirst = userMap['first_name'] as String?;
    final rawLast  = userMap['last_name']  as String?;
    String first   = rawFirst ?? '';
    String last    = rawLast  ?? '';

    if (first.isEmpty && last.isEmpty) {
      final legacy = userMap['name'] as String? ?? '';
      final idx    = legacy.indexOf(' ');
      first = idx > 0 ? legacy.substring(0, idx) : legacy;
      last  = idx > 0 ? legacy.substring(idx + 1) : '';
    }

    return TeamMember(
      teamMemberId: map['id']        as String? ?? '',
      teamId:       map['team_id']   as String? ?? '',
      userId:       map['user_id']   as String? ?? '',
      role:         map['role']      as String? ?? 'player',
      playerId:     map['player_id'] as String?,
      firstName:    first,
      lastName:     last,
      email:        userMap['email'] as String? ?? '',
      organization: userMap['organization'] as String?,
    );
  }

  // ── Display helper ─────────────────────────────────────────────────────────
  String get roleLabel {
    switch (role) {
      case 'owner':        return 'Owner';
      case 'coach':        return 'Coach';
      case 'player':       return 'Player';
      case 'team_parent':  return 'Team Parent';
      case 'team_manager': return 'Team Manager';
      default:
        if (role.isEmpty) return 'Unknown';
        return role[0].toUpperCase() + role.substring(1);
    }
  }
}