class Player {
  final String id;
  final String teamId;
  final String displayName;
  final String? nickname;
  final int? jerseyNumber;
  final String? position;
  final String? gradeLevel;

  Player({
    required this.id,
    required this.teamId,
    required this.displayName,
    this.nickname,
    this.jerseyNumber,
    this.position,
    this.gradeLevel,
  });

  // 1. Convert Supabase Map (JSON) to Player Object
  // This is used when READING from the database
  factory Player.fromMap(Map<String, dynamic> map) {
    return Player(
      id: map['id'],
      teamId: map['team_id'],
      displayName: map['display_name'],
      nickname: map['nickname'],
      jerseyNumber: map['jersey_number'],
      position: map['position_label'],
      gradeLevel: map['grade_level'],
    );
  }

  // 2. Convert Player Object to Map (JSON)
  // This is used when WRITING to the database
  Map<String, dynamic> toMap() {
    return {
      'team_id': teamId,
      'display_name': displayName,
      'nickname': nickname,
      'jersey_number': jerseyNumber,
      'position_label': position,
      'grade_level': gradeLevel,
    };
  }
}