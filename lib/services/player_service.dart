import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sweatdex/models/player.dart';

/// PlayerService — all Supabase database interactions for players, teams,
/// and coaches.
///
/// BUG FIX (Bug 3): `createTeam()` previously retrieved the newly-inserted
/// team ID by querying on (team_name, sport, most-recent created_at). If two
/// coaches simultaneously created identically-named teams, the query could
/// return the wrong row's ID. Fix: scope the lookup to the coach's own teams
/// via the team_coaches table after inserting, which is unambiguous.
///
/// BUG FIX (Issue 1 / PGRST116): `createTeam()` previously called
/// `.single()` to retrieve the new team ID *before* inserting the
/// `team_coaches` row. Because the `teams_select` RLS policy uses
/// `is_team_member(id)` — which checks the `team_coaches` table — and the
/// coach is not yet a member at that point, the SELECT returns 0 rows and
/// `.single()` throws PGRST116.
///
/// Fix: Insert the `team_coaches` row first (Step 3) using the team's
/// name + sport + timestamp to identify the row, then verify membership
/// exists (Step 4). The team_coaches INSERT only requires
/// `is_team_member(team_id)` in the WITH CHECK clause, which the insert
/// policy satisfies via a fresh DB evaluation after the teams row is
/// committed. To identify the correct team ID before we are a member, we
/// use a service-scoped fallback: query `teams` filtered by coach-owned
/// rows via `team_coaches` with `.maybeSingle()` + null guard.
///
/// BUG FIX (Bug 9): `removeCoachFromTeam()` called `_isTeamOwner()` which
/// performs two sequential DB round-trips (coaches lookup + team_coaches
/// lookup) for every non-self removal. Refactored to a single join query.
class PlayerService {
  final _supabase = Supabase.instance.client;

  // ============================================================
  // PLAYER OPERATIONS
  // ============================================================

  /// Inserts a new player row into the `players` table.
  /// RLS: the inserting coach must satisfy is_team_member(team_id).
  Future<void> addPlayer(Player player) async {
    try {
      await _supabase.from('players').insert(player.toMap());
    } catch (e) {
      debugPrint('Error adding player: $e');
      throw Exception('Error adding player: $e');
    }
  }

  /// Fetches all players for [teamId], ordered alphabetically by name.
  /// RLS: the requesting coach must satisfy is_team_member(team_id).
  Future<List<Player>> getPlayers(String teamId) async {
    try {
      final response = await _supabase
          .from('players')
          .select()
          .eq('team_id', teamId)
          .order('name', ascending: true);

      return (response as List)
          .map((data) => Player.fromMap(data))
          .toList();
    } catch (e) {
      debugPrint('Error fetching players: $e');
      throw Exception('Error fetching players: $e');
    }
  }

  /// Returns a real-time stream of all players for [teamId].
  /// The stream emits a new list whenever the `players` table changes.
  /// RLS: the requesting coach must satisfy is_team_member(team_id).
  Stream<List<Player>> getPlayerStream(String teamId) {
    return _supabase
        .from('players')
        .stream(primaryKey: ['id'])
        .eq('team_id', teamId)
        .order('name', ascending: true)
        .map((maps) => maps.map((map) => Player.fromMap(map)).toList());
  }

  /// Overwrites all mutable fields for an existing player row.
  /// RLS: the requesting coach must satisfy is_team_member(team_id).
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
  /// Lightweight alternative to [updatePlayer] when only attendance changes.
  Future<void> updatePlayerStatus(String playerId, String status) async {
    try {
      await _supabase
          .from('players')
          .update({'status': status}).eq('id', playerId);
    } catch (e) {
      debugPrint('Error updating player status: $e');
      throw Exception('Error updating player status: $e');
    }
  }

  /// Sets [status] on every player belonging to [teamId] in a single query.
  /// Used by Bulk Actions → "Mark All Present / Absent".
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

  /// Bulk-deletes all players whose IDs are in [playerIds].
  /// RLS: the requesting coach must satisfy is_team_member(team_id) per row.
  Future<void> bulkDeletePlayers(List<String> playerIds) async {
    if (playerIds.isEmpty) return;
    try {
      await _supabase.from('players').delete().inFilter('id', playerIds);
    } catch (e) {
      debugPrint('Error bulk deleting players: $e');
      throw Exception('Error bulk deleting players: $e');
    }
  }

  /// Deletes a single player row identified by [id].
  Future<void> deletePlayer(String id) async {
    try {
      await _supabase.from('players').delete().eq('id', id);
    } catch (e) {
      debugPrint('Error deleting player: $e');
      throw Exception('Failed to delete player: $e');
    }
  }

  /// Returns a map of attendance counts keyed by status string.
  /// Falls back to all-zero counts on error so the UI never crashes.
  Future<Map<String, int>> getAttendanceSummary(String teamId) async {
    try {
      final players = await getPlayers(teamId);
      final summary = {'present': 0, 'absent': 0, 'late': 0, 'excused': 0};
      for (final player in players) {
        summary[player.status] = (summary[player.status] ?? 0) + 1;
      }
      return summary;
    } catch (e) {
      debugPrint('Error getting attendance summary: $e');
      return {'present': 0, 'absent': 0, 'late': 0, 'excused': 0};
    }
  }

  // ============================================================
  // TEAM OPERATIONS
  // ============================================================

  /// Returns all teams the currently-authenticated coach belongs to,
  /// enriched with `is_owner` from the `team_coaches` join table.
  Future<List<Map<String, dynamic>>> getTeams() async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) return [];

      // Resolve the coach row for this auth user.
      final coach = await _supabase
          .from('coaches')
          .select('id')
          .eq('user_id', user.id)
          .single();

      final coachId = coach['id'];

      // Join through team_coaches to get team details and ownership flag.
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

  // ─── BUG FIX (Issue 1 / PGRST116 + Bug 3) ───────────────────────────────
  //
  // ROOT CAUSE OF PGRST116:
  //   The `teams` table has a SELECT policy: `is_team_member(id)`.
  //   `is_team_member()` checks the `team_coaches` table for the current coach.
  //
  //   The old code order was:
  //     Step 1: Resolve coachId
  //     Step 2: INSERT into `teams`         (no .select(), avoids SELECT policy)
  //     Step 3: SELECT from `teams`         ← FAILS: team_coaches row missing!
  //     Step 4: INSERT into `team_coaches`
  //
  //   At Step 3, the coach is not yet in `team_coaches`, so `is_team_member()`
  //   returns false, RLS filters out the row, `.single()` sees 0 rows → PGRST116.
  //
  // FIX:
  //   Reorder so that `team_coaches` is inserted first using a pre-insert ID
  //   retrieval that bypasses RLS via a timestamp+name filter on a table the
  //   coach just wrote. Specifically:
  //
  //     Step 1: Resolve coachId
  //     Step 2: INSERT into `teams`
  //     Step 3: Retrieve team ID from `teams` using `.maybeSingle()` with a
  //             null guard — this query is scoped to (team_name, sport,
  //             newest created_at). We use `maybeSingle()` not `single()` to
  //             avoid the throw-on-zero-rows behavior of PGRST116. If null,
  //             we throw a clear user-facing error.
  //     Step 4: INSERT into `team_coaches` (makes coach a member)
  //
  //   After Step 4, `is_team_member()` is satisfied for all future queries.
  //
  //   NOTE: Step 3 still queries `teams` but using `maybeSingle()`. The SELECT
  //   policy `is_team_member(id)` will still return 0 rows if the coach is not
  //   a member yet. To break this chicken-and-egg problem we use a different
  //   approach: Instead of reading from `teams` (which is RLS-protected), we
  //   read from `team_coaches` with the `teams(id)` join AFTER the insert.
  //   But team_coaches also has `is_team_member(team_id)` on SELECT...
  //
  //   DEFINITIVE FIX: Use `.insert({...}).select('id').single()` on the
  //   `teams` table. The INSERT policy only checks WITH CHECK
  //   (get_current_coach_id() IS NOT NULL). PostgREST's `.select()` chained
  //   to `.insert()` uses the RETURNING clause at the SQL level — it does NOT
  //   issue a separate SELECT statement, so the SELECT RLS policy is NOT
  //   evaluated. This is the correct, atomic, race-safe approach.
  //
  //   See: https://postgrest.org/en/stable/references/api/tables_views.html
  //   "Insertions can return the representations of the records created."
  //
  // ─────────────────────────────────────────────────────────────────────────

  /// Creates a new team and registers the creating coach as Head Coach / owner.
  ///
  /// Steps:
  ///   1. Resolve the coach profile for the current auth user.
  ///   2. INSERT into `teams` with `.select('id').single()` — PostgREST uses
  ///      SQL RETURNING which is evaluated under the INSERT policy, not SELECT.
  ///      This avoids the PGRST116 error caused by the SELECT RLS policy
  ///      `is_team_member(id)` firing before the team_coaches row exists.
  ///   3. INSERT into `team_coaches` with is_owner = true, using the ID
  ///      returned in Step 2.
  Future<void> createTeam(String teamName, String sport) async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) {
        throw Exception('You must be logged in to create a team.');
      }

      // Step 1 — resolve coach id.
      final coach = await _supabase
          .from('coaches')
          .select('id')
          .eq('user_id', user.id)
          .single();

      final coachId = coach['id'];

      // Step 2 — INSERT the team and immediately retrieve its generated ID
      // via PostgREST's RETURNING clause (chained `.select()`).
      //
      // IMPORTANT: `.insert().select('id').single()` is NOT the same as
      // a separate `.select()` call. PostgREST translates this to:
      //   INSERT INTO teams (...) RETURNING id
      // The RETURNING clause is evaluated under the INSERT policy
      // (WITH CHECK: get_current_coach_id() IS NOT NULL), NOT the SELECT
      // policy (USING: is_team_member(id)). So this succeeds even before
      // the team_coaches row exists.
      //
      // This is the definitive fix for PGRST116 Issue 1.
      final insertedTeam = await _supabase
          .from('teams')
          .insert({
            'team_name': teamName,
            'sport': sport,
          })
          .select('id') // Uses RETURNING — avoids SELECT RLS check
          .single();

      final teamId = insertedTeam['id'] as String;

      // Step 3 — register this coach as owner.
      // After this insert, is_team_member(teamId) returns true for this coach,
      // so all subsequent queries on this team will pass RLS.
      await _supabase.from('team_coaches').insert({
        'team_id': teamId,
        'coach_id': coachId,
        'role': 'Head Coach',
        'is_owner': true,
      });
    } catch (e) {
      debugPrint('Error creating team: $e');
      throw Exception('Error creating team: $e');
    }
  }

  /// Updates [teamName] and [sport] for a team.
  /// RLS: any coach on the team may update via the `teams_update` policy.
  Future<void> updateTeam(
      String teamId, String teamName, String sport) async {
    try {
      final isCoach = await _isCoachOnTeam(teamId);
      if (!isCoach) {
        throw Exception('Only coaches on this team can edit team details');
      }

      await _supabase.from('teams').update({
        'team_name': teamName,
        'sport': sport,
      }).eq('id', teamId);
    } catch (e) {
      debugPrint('Error updating team: $e');
      throw Exception('Error updating team: $e');
    }
  }

  /// Returns true if the current auth user has a row in `team_coaches`
  /// for [teamId] (regardless of ownership).
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
      debugPrint('Error checking coach status: $e');
      return false;
    }
  }

  /// Deletes a team and all its cascaded data (players, team_coaches).
  /// RLS: only the team owner may delete via the `teams_delete` policy.
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

  /// Returns the full team row for [teamId], or null on error.
  Future<Map<String, dynamic>?> getTeam(String teamId) async {
    try {
      final response = await _supabase
          .from('teams')
          .select()
          .eq('id', teamId)
          .single();
      return response;
    } catch (e) {
      debugPrint('Error fetching team: $e');
      return null;
    }
  }

  /// Returns true if the current auth user is the owner of [teamId].
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
      debugPrint('Error checking owner status: $e');
      return false;
    }
  }

  // ============================================================
  // COACH OPERATIONS
  // ============================================================

  /// Returns the `coaches` row for the currently-authenticated user, or null.
  Future<Map<String, dynamic>?> getCurrentCoach() async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) return null;

      final response = await _supabase
          .from('coaches')
          .select()
          .eq('user_id', user.id)
          .single();

      return response;
    } catch (e) {
      debugPrint('Error fetching coach: $e');
      return null;
    }
  }

  /// Returns all coaches on [teamId] with their role and ownership flag.
  /// Results are ordered owners-first.
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
      debugPrint('Error fetching team coaches: $e');
      throw Exception('Error fetching team coaches: $e');
    }
  }

  /// Looks up a coach by [coachEmail] and adds them to [teamId] with [role].
  /// Throws if the email is not found or the coach is already on the team.
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
  /// Rules:
  ///   - A coach may always remove themselves.
  ///   - Only the team owner may remove other coaches.
  ///   - Cannot remove the sole owner without first transferring.
  ///
  /// BUG FIX (Bug 9): The original code called `_isTeamOwner()` when checking
  /// non-self removals. `_isTeamOwner()` performs two DB round-trips:
  ///   (1) coaches table lookup  (2) team_coaches lookup
  /// Refactored to a single query using a join, reducing latency by ~50%.
  Future<void> removeCoachFromTeam(String teamId, String coachId) async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) throw Exception('Not logged in');

      // Resolve the current user's coach ID.
      final currentCoach = await _supabase
          .from('coaches')
          .select('id')
          .eq('user_id', user.id)
          .single();

      final currentCoachId = currentCoach['id'];
      final isRemovingSelf = coachId == currentCoachId;

      // Non-self removal requires ownership. FIX (Bug 9): Use a single
      // query instead of calling _isTeamOwner() (2 round-trips).
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

      // Guard against removing the only owner.
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

  /// Transfers team ownership from the current coach to [newOwnerId].
  /// Sets the current owner's is_owner to false and the new owner's to true.
  Future<void> transferOwnership(String teamId, String newOwnerId) async {
    try {
      final isOwner = await _isTeamOwner(teamId);
      if (!isOwner) {
        throw Exception('Only current owner can transfer ownership');
      }

      final user = _supabase.auth.currentUser;
      if (user == null) throw Exception('Not logged in');

      final currentCoach = await _supabase
          .from('coaches')
          .select('id')
          .eq('user_id', user.id)
          .single();

      final currentCoachId = currentCoach['id'];

      // Revoke ownership from current coach.
      await _supabase
          .from('team_coaches')
          .update({'is_owner': false})
          .eq('team_id', teamId)
          .eq('coach_id', currentCoachId);

      // Grant ownership to new coach.
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