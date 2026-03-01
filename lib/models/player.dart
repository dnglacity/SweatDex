import 'package:flutter/material.dart';

// =============================================================================
// player.dart  (AOD v1.9)
//
// CHANGE (v1.8):
//   • Split `name` into `firstName` + `lastName` (DB columns: first_name,
//     last_name). The `name` getter concatenates them for display compatibility
//     so all existing callers (screens, game roster JSONB) continue to work.
//   • `toMap` writes first_name + last_name; no longer writes `name`.
//
// CHANGE (v1.9):
//   • Removed legacy `name`-column fallback from `fromMap`. Migration is
//     complete — _kPlayerColumns never selects `name`, so the split path
//     was unreachable dead code.
//
// All v1.7 fields retained.
// =============================================================================

class Player {
  final String id;
  final String teamId;

  // CHANGE (v1.8): stored as separate columns in the DB.
  final String firstName;
  final String lastName;

  // CHANGE (v1.7): renamed from studentId.
  final String? athleteId;

  // CHANGE (v1.7): renamed from studentEmail.
  final String? athleteEmail;

  // CHANGE (v1.7): parent/guardian email (optional).
  final String? guardianEmail;

  // CHANGE (v1.7): academic grade (9–12). Auto-incremented July 1 server-side.
  final int? grade;

  /// Date the grade was last auto-incremented.
  final DateTime? gradeUpdatedAt;

  final String? jerseyNumber;
  final String? nickname;
  final String? position;

  /// FK → public.users.id. Null until the player signs up and is linked.
  final String? userId;

  final String status;
  final DateTime? createdAt;

  const Player({
    required this.id,
    required this.teamId,
    required this.firstName,
    required this.lastName,
    this.athleteId,
    this.athleteEmail,
    this.guardianEmail,
    this.grade,
    this.gradeUpdatedAt,
    this.jerseyNumber,
    this.nickname,
    this.position,
    this.userId,
    this.status = 'present',
    this.createdAt,
  });

  // ── Deserialise from Supabase row ──────────────────────────────────────────
  factory Player.fromMap(Map<String, dynamic> map) {
    // Support both old column names (student_*) and new (athlete_*).
    final athleteId    = map['athlete_id']   as String?
                      ?? map['student_id']   as String?;
    final athleteEmail = map['athlete_email'] as String?
                      ?? map['student_email'] as String?;

    final String first = map['first_name'] as String? ?? '';
    final String last  = map['last_name']  as String? ?? '';

    return Player(
      id:             map['id']      as String? ?? '',
      teamId:         map['team_id'] as String? ?? '',
      firstName:      first,
      lastName:       last,
      athleteId:      athleteId,
      athleteEmail:   athleteEmail,
      guardianEmail:  map['guardian_email'] as String?,
      grade:          map['grade'] as int?,
      gradeUpdatedAt: map['grade_updated_at'] != null
                        ? DateTime.tryParse(map['grade_updated_at'] as String)
                        : null,
      jerseyNumber:   map['jersey_number']?.toString(),
      nickname:       map['nickname']  as String?,
      position:       map['position']  as String?,
      userId:         map['user_id']   as String?,
      status:         map['status']    as String? ?? 'present',
      createdAt:      map['created_at'] != null
                        ? DateTime.tryParse(map['created_at'] as String)
                        : null,
    );
  }

  // ── Serialise for Supabase insert/update ───────────────────────────────────
  Map<String, dynamic> toMap() {
    return {
      'team_id':        teamId,
      'first_name':     firstName,
      'last_name':      lastName,
      'athlete_id':     athleteId,
      'athlete_email':  athleteEmail,
      'guardian_email': guardianEmail,
      'grade':          grade,
      'jersey_number':  jerseyNumber,
      'nickname':       nickname,
      'position':       position,
      'user_id':        userId,
      'status':         status,
    };
  }

  // ── Copy helper ────────────────────────────────────────────────────────────
  Player copyWith({
    String? id,
    String? teamId,
    String? firstName,
    String? lastName,
    String? athleteId,
    String? athleteEmail,
    String? guardianEmail,
    int?    grade,
    DateTime? gradeUpdatedAt,
    String? jerseyNumber,
    String? nickname,
    String? position,
    String? userId,
    String? status,
    DateTime? createdAt,
  }) {
    return Player(
      id:             id             ?? this.id,
      teamId:         teamId         ?? this.teamId,
      firstName:      firstName      ?? this.firstName,
      lastName:       lastName       ?? this.lastName,
      athleteId:      athleteId      ?? this.athleteId,
      athleteEmail:   athleteEmail   ?? this.athleteEmail,
      guardianEmail:  guardianEmail  ?? this.guardianEmail,
      grade:          grade          ?? this.grade,
      gradeUpdatedAt: gradeUpdatedAt ?? this.gradeUpdatedAt,
      jerseyNumber:   jerseyNumber   ?? this.jerseyNumber,
      nickname:       nickname       ?? this.nickname,
      position:       position       ?? this.position,
      userId:         userId         ?? this.userId,
      status:         status         ?? this.status,
      createdAt:      createdAt      ?? this.createdAt,
    );
  }

  // ── Display helpers ────────────────────────────────────────────────────────

  /// Full name — used throughout all existing screens unchanged.
  String get name => '$firstName $lastName'.trim();

  String get displayJersey   => jerseyNumber ?? '-';
  String get displayName     => nickname != null ? '$name ($nickname)' : name;
  String get displayPosition => position?.isNotEmpty == true ? position! : '-';

  /// Grade display string: "10th", "11th", etc. or "—" if not set.
  String get displayGrade {
    if (grade == null) return '—';
    switch (grade!) {
      case 9:  return '9th (Freshman)';
      case 10: return '10th (Sophomore)';
      case 11: return '11th (Junior)';
      case 12: return '12th (Senior)';
      default: return 'Grade $grade';
    }
  }

  /// True when this player row is linked to an app account.
  bool get hasLinkedAccount => userId != null && userId!.isNotEmpty;

  // ── Status helpers ─────────────────────────────────────────────────────────

  Color get statusColor {
    switch (status) {
      case 'present': return Colors.green;
      case 'absent':  return Colors.red;
      case 'late':    return Colors.orange;
      case 'excused': return Colors.blue;
      default:        return Colors.grey;
    }
  }

  IconData get statusIcon {
    switch (status) {
      case 'present': return Icons.check_circle;
      case 'absent':  return Icons.cancel;
      case 'late':    return Icons.access_time;
      case 'excused': return Icons.event_busy;
      default:        return Icons.help;
    }
  }

  String get statusLabel {
    if (status.isEmpty) return 'Unknown';
    return status[0].toUpperCase() + status.substring(1);
  }
}
