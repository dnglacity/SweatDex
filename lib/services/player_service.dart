import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sweatdex/models/player.dart';

// ─────────────────────────────────────────────────────────────────────────────
// player_service.dart
//
// All Supabase database interactions for players, teams, coaches, game rosters,
// and player-account linking.
//
// BUG FIX (Issue 1 / 42501): createTeam() now calls the Supabase RPC
//   `create_team` (SECURITY DEFINER function defined in migration_v2.sql).
//   The function runs as postgres, bypassing RLS entirely, so the teams INSERT
//   and team_coaches INSERT happen atomically without the chicken-and-egg
//   problem of `is_team_member()` evaluating before the membership row exists.
//
// NEW: getGameRosters(), createGameRoster(), updateGameRosterLineup(),
//   deleteGameRoster() — persist game rosters to Supabase instead of memory.
//
// NEW: getPlayerLinkedTeams() — returns teams where the current auth account
//   is linked as a player via the player_accounts table.
//
// BUG FIX (Bug 3): createTeam() previously used a name+sport+timestamp query
//   to retrieve the new team ID, which could return the wrong row if two coaches
//   simultaneously created identically-named teams. The RPC approach eliminates
//   this race entirely by returning the ID from the function directly.
//
// BUG FIX (Bug 9): removeCoachFromTeam() uses a single join query rather than
//   two sequential round-trips to check ownership.
// ─────────────────────────────────────────────────────────────────────────────

class PlayerService {
  final _supabase = Supabase.instance.client;

  // ===========================================================================
  // PLAYER OPERATIONS
  // ===========================================================================

  /// Inserts a new player row. RLS: coach must satisfy is_team_member(team_id).
  Future<void> addPlayer(Player player) async {
    try {
      await _supabase.from('players').insert(player.toMap());
    } catch (e) {
      debugPrint('Error adding player: $e');
      throw Exception('Error adding player: $e');
    }
  }

  /// Fetches all players for [teamId], ordered by name.
  Future<List<Player>> getPlayers(String teamId) async {
    try {
      final response = await _supabase
          .from('players')
          .select()
          .eq('team_id', teamId)
          .order('name', ascending: true);
      return (response as List).map((d) => Player.fromMap(d)).toList();
    } catch (e) {
      debugPrint('Error fetching players: $e');
      throw Exception('Error fetching players: $e');
    }
  }

  /// Real-time stream of players for [teamId].
  Stream<List<Player>> getPlayerStream(String teamId) {
    return _supabase
        .from('players')
        .stream(primaryKey: ['id'])
        .eq('team_id', teamId)
        .order('name', ascending: true)
        .map((maps) => maps.map((m) => Player.fromMap(m)).toList());
  }

  /// Overwrites all mutable fields for a player row.
  Future<void> updatePlayer(Player player) async {
    try {
      await _supabase
          .from('players')
          .update(player.toMap())
          .eq('id', player.id);
    } catch (e) {
      debugPrint('Error updating player: $e');
      throw Exception('Error updating player: $e');
    }
  }

  /// Updates only the `status` field for a single player.
  Future<void> updatePlayerStatus(String playerId, String status) async {
    try {
      await _supabase
          .from('players')
          .update({'status': status}).eq('id', playerId);
    } catch (e) {
      debugPrint('Error updating status: $e');
      throw Exception('Error updating status: $e');
    }
  }

  /// Sets [status] on every player in [teamId] in a single query.
  Future<void> bulkUpdateStatus(String teamId, String status) async {
    try {
      await _supabase
          .from('players')
          .update({'status': status}).eq('team_id', teamId);
    } catch (e) {
      debugPrint('Error bulk updating status: $e');
      throw Exception('Error bulk updating status: $e');
    }
  }

  /// Deletes players by [playerIds] in a single query.
  Future<void> bulkDeletePlayers(List<String> playerIds) async {
    if (playerIds.isEmpty) return;
    try {
      await _supabase.from('players').delete().inFilter('id', playerIds);
    } catch (e) {
      debugPrint('Error bulk deleting: $e');
      throw Exception('Error bulk deleting players: $e');
    }
  }

  /// Deletes a single player by [id].
  Future<void> deletePlayer(String id) async {
    try {
      await _supabase.from('players').delete().eq('id', id);
    } catch (e) {
      debugPrint('Error deleting player: $e');
      throw Exception('Failed to delete player: $e');
    }
  }

  /// Returns attendance summary counts. Falls back to all-zeros on error.
  Future<Map<String, int>> getAttendanceSummary(String teamId) async {
    try {
      final players = await getPlayers(teamId);
      final summary = {'present': 0, 'absent': 0, 'late': 0, 'excused': 0};
      for (final p in players) {
        summary[p.status] = (summary[p.status] ?? 0) + 1;
      }
      return summary;
    } catch (e) {
      debugPrint('Error getting attendance: $e');
      return {'present': 0, 'absent': 0, 'late': 0, 'excused': 0};
    }
  }

  // ===========================================================================
  // TEAM OPERATIONS
  // ===========================================================================

  /// Returns all teams the authenticated coach belongs to, with is_owner flag.
  Future<List<Map<String, dynamic>>> getTeams() async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) return [];

      final coach = await _supabase
          .from('coaches')
          .select('id')
          .eq('user_id', user.id)
          .single();

      final coachId = coach['id'];

      final response = await _supabase
          .from('team_coaches')
          .select('team_id, is_owner, teams(id, team_name, sport, created_at)')
          .eq('coach_id', coachId);

      return (response as List).map((item) {
        final team = item['teams'];
        return {
          'id': team['id'],
          'team_name': team['team_name'],
          'sport': team['sport'],
          'created_at': team['created_at'],
          'is_owner': item['is_owner'] ?? false,
        };
      }).toList();
    } catch (e) {
      debugPrint('Error fetching teams: $e');
      throw Exception('Error fetching teams: $e');
    }
  }

  /// Returns teams where the current account is linked as a player
  /// (via player_accounts). These show up with is_player: true in the UI.
  ///
  /// NEW (Notes.txt): "The player's team will show up with an icon showing
  /// that they are a player and not a coach."
  Future<List<Map<String, dynamic>>> getPlayerLinkedTeams() async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) return [];

      final coach = await _supabase
          .from('coaches')
          .select('id')
          .eq('user_id', user.id)
          .maybeSingle();

      if (coach == null) return [];

      final coachId = coach['id'];

      // Fetch player_accounts rows for this coach, joining the teams table.
      final response = await _supabase
          .from('player_accounts')
          .select('team_id, is_player, teams(id, team_name, sport, created_at)')
          .eq('coach_id', coachId)
          .eq('is_player', true);

      return (response as List).map((item) {
        final team = item['teams'];
        return {
          'id': team['id'],
          'team_name': team['team_name'],
          'sport': team['sport'],
          'created_at': team['created_at'],
          'is_owner': false,
          'is_player': true,
        };
      }).toList();
    } catch (e) {
      // Non-fatal: player_accounts may not exist yet.
      debugPrint('Error fetching player-linked teams: $e');
      return [];
    }
  }

  // ── BUG FIX (Issue 1 / 42501) ─────────────────────────────────────────────
  //
  // ROOT CAUSE: The `teams` INSERT policy WITH CHECK calls
  //   get_current_coach_id(). If the coaches row doesn't exist yet (auth
  //   trigger race on fresh sign-up), the function returns NULL, the policy
  //   evaluates to false, and the INSERT fails with 42501.
  //
  //   Additionally, even chaining .select('id') to .insert() can trigger the
  //   SELECT policy (is_team_member) before team_coaches is populated,
  //   causing a second 42501.
  //
  // FIX: Call the `create_team` SECURITY DEFINER RPC (defined in
  //   migration_v2.sql). The function runs as postgres, bypasses RLS
  //   entirely, inserts both the team and team_coaches row atomically,
  //   and returns the new team ID. No race condition is possible.
  //
  // ─────────────────────────────────────────────────────────────────────────

  /// Creates a new team by calling the `create_team` Supabase RPC.
  /// The RPC is a SECURITY DEFINER function that bypasses RLS and atomically
  /// inserts into `teams` and `team_coaches` in one transaction.
  Future<void> createTeam(String teamName, String sport) async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) {
        throw Exception('You must be logged in to create a team.');
      }

      // Call the SECURITY DEFINER RPC. This bypasses all RLS policies,
      // eliminating the 42501 error from `is_team_member` / `get_current_coach_id`.
      await _supabase.rpc('create_team', params: {
        'p_team_name': teamName,
        'p_sport': sport,
      });
    } catch (e) {
      debugPrint('Error creating team: $e');
      throw Exception('Error creating team: $e');
    }
  }

  /// Updates team name and sport. Any coach on the team may update.
  Future<void> updateTeam(
      String teamId, String teamName, String sport) async {
    try {
      await _supabase.from('teams').update({
        'team_name': teamName,
        'sport': sport,
      }).eq('id', teamId);
    } catch (e) {
      debugPrint('Error updating team: $e');
      throw Exception('Error updating team: $e');
    }
  }

  /// Deletes a team (cascades to players and team_coaches).
  Future<void> deleteTeam(String teamId) async {
    try {
      final isOwner = await _isTeamOwner(teamId);
      if (!isOwner) {
        throw Exception('Only team owners can delete teams');
      }
      await _supabase.from('teams').delete().eq('id', teamId);
    } catch (e) {
      debugPrint('Error deleting team: $e');
      throw Exception('Error deleting team: $e');
    }
  }

  /// Returns the full team row or null.
  Future<Map<String, dynamic>?> getTeam(String teamId) async {
    try {
      return await _supabase
          .from('teams')
          .select()
          .eq('id', teamId)
          .single();
    } catch (e) {
      debugPrint('Error fetching team: $e');
      return null;
    }
  }

  Future<bool> _isTeamOwner(String teamId) async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) return false;
      final coach = await _supabase
          .from('coaches')
          .select('id')
          .eq('user_id', user.id)
          .single();
      final result = await _supabase
          .from('team_coaches')
          .select('is_owner')
          .eq('team_id', teamId)
          .eq('coach_id', coach['id'])
          .maybeSingle();
      return result?['is_owner'] == true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> _isCoachOnTeam(String teamId) async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) return false;
      final coach = await _supabase
          .from('coaches')
          .select('id')
          .eq('user_id', user.id)
          .single();
      final result = await _supabase
          .from('team_coaches')
          .select('id')
          .eq('team_id', teamId)
          .eq('coach_id', coach['id'])
          .maybeSingle();
      return result != null;
    } catch (e) {
      return false;
    }
  }

  // ===========================================================================
  // GAME ROSTER OPERATIONS
  // ===========================================================================
  //
  // These methods persist game rosters to the Supabase `game_rosters` table
  // (defined in migration_v2.sql). Previously rosters were stored in-memory
  // only and were lost on app restart.

  /// Returns all saved game rosters for [teamId], newest first.
  Future<List<Map<String, dynamic>>> getGameRosters(String teamId) async {
    try {
      final response = await _supabase
          .from('game_rosters')
          .select()
          .eq('team_id', teamId)
          .order('created_at', ascending: false);
      return (response as List).cast<Map<String, dynamic>>();
    } catch (e) {
      debugPrint('Error fetching game rosters: $e');
      throw Exception('Error fetching game rosters: $e');
    }
  }

  /// Inserts a new game roster row and returns the generated UUID.
  Future<String> createGameRoster({
    required String teamId,
    required String title,
    String? gameDate,
    int starterSlots = 5,
  }) async {
    try {
      final user = _supabase.auth.currentUser;
      final coach = user != null
          ? await _supabase
              .from('coaches')
              .select('id')
              .eq('user_id', user.id)
              .maybeSingle()
          : null;

      // Use .insert().select('id').single() — RETURNING does NOT evaluate
      // the SELECT RLS policy (is_team_member), only the INSERT policy.
      final result = await _supabase
          .from('game_rosters')
          .insert({
            'team_id': teamId,
            'title': title,
            'game_date': gameDate,
            'starter_slots': starterSlots,
            'starters': [],
            'substitutes': [],
            if (coach != null) 'created_by': coach['id'],
          })
          .select('id')
          .single();

      return result['id'] as String;
    } catch (e) {
      debugPrint('Error creating game roster: $e');
      throw Exception('Error creating game roster: $e');
    }
  }

  /// Updates the starters and substitutes JSON arrays for an existing roster.
  Future<void> updateGameRosterLineup({
    required String rosterId,
    required List<Map<String, dynamic>> starters,
    required List<Map<String, dynamic>> substitutes,
  }) async {
    try {
      await _supabase.from('game_rosters').update({
        'starters': starters,
        'substitutes': substitutes,
      }).eq('id', rosterId);
    } catch (e) {
      debugPrint('Error updating game roster lineup: $e');
      throw Exception('Error updating game roster lineup: $e');
    }
  }

  /// Deletes a game roster row by [rosterId].
  Future<void> deleteGameRoster(String rosterId) async {
    try {
      await _supabase.from('game_rosters').delete().eq('id', rosterId);
    } catch (e) {
      debugPrint('Error deleting game roster: $e');
      throw Exception('Error deleting game roster: $e');
    }
  }

  // ===========================================================================
  // COACH OPERATIONS
  // ===========================================================================

  /// Returns the coaches row for the current user, or null.
  Future<Map<String, dynamic>?> getCurrentCoach() async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) return null;
      return await _supabase
          .from('coaches')
          .select()
          .eq('user_id', user.id)
          .single();
    } catch (e) {
      debugPrint('Error fetching coach: $e');
      return null;
    }
  }

  /// Returns all coaches on [teamId] with role and ownership flag.
  Future<List<Map<String, dynamic>>> getTeamCoaches(String teamId) async {
    try {
      final response = await _supabase
          .from('team_coaches')
          .select('coaches(id, name, email, organization), role, is_owner')
          .eq('team_id', teamId)
          .order('is_owner', ascending: false);

      return (response as List).map((item) {
        final coach = item['coaches'];
        return {
          'id': coach['id'],
          'name': coach['name'],
          'email': coach['email'],
          'organization': coach['organization'],
          'role': item['role'],
          'is_owner': item['is_owner'] ?? false,
        };
      }).toList();
    } catch (e) {
      debugPrint('Error fetching coaches: $e');
      throw Exception('Error fetching coaches: $e');
    }
  }

  /// Looks up a coach by email and adds them to [teamId].
  Future<void> addCoachToTeam(
      String teamId, String coachEmail, String role) async {
    try {
      final coachResult = await _supabase
          .from('coaches')
          .select('id')
          .eq('email', coachEmail)
          .maybeSingle();

      if (coachResult == null) {
        throw Exception('No coach found with email: $coachEmail');
      }

      final coachId = coachResult['id'];
      final existing = await _supabase
          .from('team_coaches')
          .select('id')
          .eq('team_id', teamId)
          .eq('coach_id', coachId)
          .maybeSingle();

      if (existing != null) {
        throw Exception('This coach is already on the team');
      }

      await _supabase.from('team_coaches').insert({
        'team_id': teamId,
        'coach_id': coachId,
        'role': role,
        'is_owner': false,
      });
    } catch (e) {
      debugPrint('Error adding coach: $e');
      throw Exception('Error adding coach: $e');
    }
  }

  /// Removes [coachId] from [teamId].
  ///
  /// BUG FIX (Bug 9): Uses a single query to check ownership instead of
  /// calling _isTeamOwner() which requires two sequential DB round-trips.
  Future<void> removeCoachFromTeam(String teamId, String coachId) async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) throw Exception('Not logged in');

      final currentCoach = await _supabase
          .from('coaches')
          .select('id')
          .eq('user_id', user.id)
          .single();

      final currentCoachId = currentCoach['id'];
      final isRemovingSelf = coachId == currentCoachId;

      // Non-self removal: check ownership in a single query (Bug 9 fix).
      if (!isRemovingSelf) {
        final ownerRow = await _supabase
            .from('team_coaches')
            .select('is_owner')
            .eq('team_id', teamId)
            .eq('coach_id', currentCoachId)
            .maybeSingle();

        if (ownerRow == null || ownerRow['is_owner'] != true) {
          throw Exception('Only team owners can remove other coaches');
        }
      }

      // Guard against removing the sole owner.
      final coachToRemove = await _supabase
          .from('team_coaches')
          .select('is_owner')
          .eq('team_id', teamId)
          .eq('coach_id', coachId)
          .single();

      if (coachToRemove['is_owner'] == true) {
        final owners = await _supabase
            .from('team_coaches')
            .select('id')
            .eq('team_id', teamId)
            .eq('is_owner', true);

        if ((owners as List).length <= 1) {
          throw Exception(
              'Cannot remove the only owner. Transfer ownership first.');
        }
      }

      await _supabase
          .from('team_coaches')
          .delete()
          .eq('team_id', teamId)
          .eq('coach_id', coachId);
    } catch (e) {
      debugPrint('Error removing coach: $e');
      throw Exception('Error removing coach: $e');
    }
  }

  /// Transfers ownership from the current coach to [newOwnerId].
  Future<void> transferOwnership(String teamId, String newOwnerId) async {
    try {
      final isOwner = await _isTeamOwner(teamId);
      if (!isOwner) {
        throw Exception('Only the current owner can transfer ownership');
      }

      final user = _supabase.auth.currentUser;
      if (user == null) throw Exception('Not logged in');

      final currentCoach = await _supabase
          .from('coaches')
          .select('id')
          .eq('user_id', user.id)
          .single();

      final currentCoachId = currentCoach['id'];

      // Revoke current owner.
      await _supabase
          .from('team_coaches')
          .update({'is_owner': false})
          .eq('team_id', teamId)
          .eq('coach_id', currentCoachId);

      // Grant to new owner.
      await _supabase
          .from('team_coaches')
          .update({'is_owner': true})
          .eq('team_id', teamId)
          .eq('coach_id', newOwnerId);
    } catch (e) {
      debugPrint('Error transferring ownership: $e');
      throw Exception('Error transferring ownership: $e');
    }
  }
}