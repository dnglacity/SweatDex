import 'package:flutter/material.dart';

class Player {
  final String id;
  final String teamId;
  final String name;
  final String? studentId;
  final String? studentEmail;
  final String? jerseyNumber; // Changed to String to allow "12A", "00", etc.
  final String? nickname;
  final String status;
  final DateTime? createdAt;

  Player({
    required this.id,
    required this.teamId,
    required this.name,
    this.studentId,
    this.studentEmail,
    this.jerseyNumber,
    this.nickname,
    this.status = 'present',
    this.createdAt,
  });

  // 1. Convert Supabase Map (JSON) to Player Object
  // This is used when READING from the database
  factory Player.fromMap(Map<String, dynamic> map) {
    return Player(
      id: map['id'] ?? '',
      teamId: map['team_id'] ?? '',
      name: map['name'] ?? '',
      studentId: map['student_id'],
      studentEmail: map['student_email'],
      jerseyNumber: map['jersey_number']?.toString(), // Convert to string if needed
      nickname: map['nickname'],
      status: map['status'] ?? 'present',
      createdAt: map['created_at'] != null 
          ? DateTime.parse(map['created_at']) 
          : null,
    );
  }

  // 2. Convert Player Object to Map (JSON)
  // This is used when WRITING to the database
  Map<String, dynamic> toMap() {
    return {
      'team_id': teamId,
      'name': name,
      'student_id': studentId,
      'student_email': studentEmail,
      'jersey_number': jerseyNumber,
      'nickname': nickname,
      'status': status,
      // Don't include 'id' or 'created_at' when creating - Supabase handles these
    };
  }

  // 3. Create a copy with updated fields (useful for editing)
  Player copyWith({
    String? id,
    String? teamId,
    String? name,
    String? studentId,
    String? studentEmail,
    String? jerseyNumber,
    String? nickname,
    String? status,
    DateTime? createdAt,
  }) {
    return Player(
      id: id ?? this.id,
      teamId: teamId ?? this.teamId,
      name: name ?? this.name,
      studentId: studentId ?? this.studentId,
      studentEmail: studentEmail ?? this.studentEmail,
      jerseyNumber: jerseyNumber ?? this.jerseyNumber,
      nickname: nickname ?? this.nickname,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  // 4. Display jersey with fallback
  String get displayJersey => jerseyNumber ?? '-';

  // 5. Display name with nickname
  String get displayName => nickname != null ? '$name ($nickname)' : name;

  // NEW: Get status color
  Color get statusColor {
    switch (status) {
      case 'present':
        return Colors.green;
      case 'absent':
        return Colors.red;
      case 'late':
        return Colors.orange;
      case 'excused':
        return Colors.blue;
      default:
        return Colors.grey;
    }
  }

  // NEW: Get status icon
  IconData get statusIcon {
    switch (status) {
      case 'present':
        return Icons.check_circle;
      case 'absent':
        return Icons.cancel;
      case 'late':
        return Icons.access_time;
      case 'excused':
        return Icons.event_busy;
      default:
        return Icons.help;
    }
  }

  // NEW: Get status label
  String get statusLabel {
    return status[0].toUpperCase() + status.substring(1);
  }

}

