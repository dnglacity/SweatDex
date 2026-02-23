import 'package:flutter/material.dart';

// =============================================================================
// player.dart  (AOD v1.7)
//
// CHANGE (Notes.txt v1.7):
//   • Renamed `studentId`    → `athleteId`
//   • Renamed `studentEmail` → `athleteEmail`
//     (DB columns renamed in migration; old column names dropped)
//   • Added `guardianEmail`  — optional parent/guardian email field.
//   • Added `grade`          — optional grade (9–12). Auto-incremented
//     July 1 by a DB scheduled function; local to the team (coaches see it).
//   • Added `gradeUpdatedAt` — tracks when grade was last incremented.
//
// All v1.6 fields (userId, position, nickname, etc.) retained.
// =============================================================================

class Player {
  final String id;
  final String teamId;
  final String name;

  // CHANGE (v1.7): renamed from studentId.
  final String? athleteId;

  // CHANGE (v1.7): renamed from studentEmail.
  final String? athleteEmail;

  // CHANGE (v1.7): parent/guardian email (optional). Triggers guardian link
  // when both the player and guardian have accounts.
  final String? guardianEmail;

  // CHANGE (v1.7): academic grade (9–12). Nullable = not set.
  // Auto-incremented to LEAST(grade+1, 13) on July 1 server-side.
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
    required this.name,
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
    // Support both old column names (student_*) and new (athlete_*) during
    // any transition period where both might exist in the DB response.
    final athleteId    = map['athlete_id']    as String?
                      ?? map['student_id']    as String?;
    final athleteEmail = map['athlete_email'] as String?
                      ?? map['student_email'] as String?;

    return Player(
      id:             map['id']           as String? ?? '',
      teamId:         map['team_id']      as String? ?? '',
      name:           map['name']         as String? ?? '',
      athleteId:      athleteId,
      athleteEmail:   athleteEmail,
      guardianEmail:  map['guardian_email'] as String?,
      grade:          map['grade'] as int?,
      gradeUpdatedAt: map['grade_updated_at'] != null
                        ? DateTime.tryParse(map['grade_updated_at'] as String)
                        : null,
      jerseyNumber:   map['jersey_number']?.toString(),
      nickname:       map['nickname']     as String?,
      position:       map['position']     as String?,
      userId:         map['user_id']      as String?,
      status:         map['status']       as String? ?? 'present',
      createdAt:      map['created_at'] != null
                        ? DateTime.tryParse(map['created_at'] as String)
                        : null,
    );
  }

  // ── Serialise for Supabase insert/update ───────────────────────────────────
  Map<String, dynamic> toMap() {
    return {
      'team_id':        teamId,
      'name':           name,
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
    String? name,
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
      name:           name           ?? this.name,
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