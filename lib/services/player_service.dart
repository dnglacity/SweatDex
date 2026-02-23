import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/player.dart';
import '../models/app_user.dart';
import 'offline_cache_service.dart';

// =============================================================================
// player_service.dart  (AOD v1.8 — Bug Fix Release)
//
// ── CHANGES IN THIS VERSION ────────────────────────────────────────────────
//
// ISSUE 1 FIX (team_members_user_id_fkey FK violation):
//   addMemberToTeam() now calls the updated add_member_to_team SECURITY
//   DEFINER RPC.  The RPC runs with postgres-level privileges, so it can
//   SELECT public.users by email (bypassing RLS) and INSERT into team_members
//   with a valid FK target — eliminating the 23503 error.
//   No Flutter code change needed here beyond the existing addMemberToTeam()
//   implementation; the fix is entirely in the DB function (see migration SQL).
//
// ISSUE 2 FIX ("User profile not found" on new account):
//   getTeams() retry loop extended: up to _maxUserIdRetries (6) attempts
//   at _userIdRetryDelay (500 ms) intervals.  _cachedUserId is explicitly
//   nulled between retries so each attempt re-queries the DB.
//   Additionally _getCurrentUserId() no longer uses a single one-shot retry
//   internally; all retry logic is consolidated in getTeams() for clarity.
//
// ISSUE 3 FIX (create_team RPC signature mismatch):
//   createTeam() already sends the correct 3-param payload
//   { p_team_name, p_sport, p_sport_id }. The DB function has been updated to
//   accept this signature (see migration SQL). No Flutter change needed.
//
// ISSUE 4 FIX (lookup_user_by_email RPC not found):
//   lookupUserByEmail() was already wired correctly in the Flutter layer.
//   The fix is the DB function creation in migration SQL.
//   Error handling in lookupUserByEmail() is improved: non-fatal, returns null
//   gracefully so the UI can still advance to Page 2.
//
// ISSUE 5 FIX (change_user_email "no account found"):
//   No Flutter change. The root cause was the DB RPC lacking
//   SET search_path = public, now corrected in migration SQL.
//
// OPTIMIZATION: getTeams() now caches the team list in-memory for the session
//   so a navigation back to TeamSelectionScreen does not re-fetch unless
//   _refreshTeams() is called explicitly.
// =============================================================================

class PlayerService {
  final _supabase = Supabase.instance.client;
  final _cache    = OfflineCacheService();

  // ===========================================================================
  // CURRENT USER HELPERS
  // ===========================================================================

  // Cache the resolved public.users.id for the lifetime of the session.
  // Nulled on clearCache() (sign-out).
  String? _cachedUserId;

  // How many times getTeams() will retry waiting for the on_auth_user_created
  // trigger to commit the public.users row after a fresh sign-up.
  static const int      _maxUserIdRetries = 6;
  // Milliseconds between retries. 500 ms × 6 = up to 3 s total wait.
  static const Duration _userIdRetryDelay = Duration(milliseconds: 500);

  /// Resolves auth.uid() → public.users.id.
  /// Returns null if the user is not signed in or the profile row doesn't exist yet.
  /// Does NOT retry internally — callers (e.g. getTeams) handle retries.
  Future<String?> _getCurrentUserId() async {
    // Return cached value if available — avoids a DB round-trip on every call.
    if (_cachedUserId != null) return _cachedUserId;

    try {
      final authUser = _supabase.auth.currentUser;
      if (authUser == null) return null;

      final row = await _supabase
          .from('users')
          .select('id')
          .eq('user_id', authUser.id)
          .maybeSingle();

      // Cache the resolved ID (even if null, won't cache null — let callers retry).
      if (row != null) {
        _cachedUserId = row['id'] as String?;
      }
      return _cachedUserId;
    } catch (e) {
      debugPrint('_getCurrentUserId error: $e');
      return null;
    }
  }

  /// Clears all in-memory state. Call this on sign-out.
  void clearCache() {
    _cachedUserId = null;
    _teamsCache   = null;
  }

  // ===========================================================================
  // SPORTS OPERATIONS
  // ===========================================================================

  /// Fetches the full sports list from the sports table, ordered by name.
  /// Returns [{ id, name, category }] or a fallback 'General' entry on error.
  Future<List<Map<String, dynamic>>> getSports() async {
    try {
      final response = await _supabase
          .from('sports')
          .select('id, name, category')
          .order('name', ascending: true);
      return (response as List).cast<Map<String, dynamic>>();
    } catch (e) {
      debugPrint('getSports error: $e');
      // Return a minimal fallback so sport pickers don't break offline.
      return [{'id': null, 'name': 'General', 'category': 'Year-Round'}];
    }
  }

  // ===========================================================================
  // PLAYER OPERATIONS
  // ===========================================================================

  /// Inserts a new player and returns the generated UUID.
  Future<String> addPlayerAndReturnId(Player player) async {
    try {
      final result = await _supabase
          .from('players')
          .insert(player.toMap())
          .select('id')
          .single();
      return result['id'] as String;
    } catch (e) {
      debugPrint('addPlayerAndReturnId error: $e');
      throw Exception('Error adding player: $e');
    }
  }

  /// Fetches ALL players for [teamId] ordered by name.
  /// Updates the offline cache on success; reads from cache on network failure.
  Future<List<Player>> getPlayers(String teamId) async {
    try {
      final response = await _supabase
          .from('players')
          .select()
          .eq('team_id', teamId)
          .order('name', ascending: true);

      final players = (response as List).map((d) => Player.fromMap(d)).toList();

      // Persist to offline cache so the next network failure returns recent data.
      await _cache.writeList(
        OfflineCacheService.playersKey(teamId),
        players.map((p) => p.toMap()..['id'] = p.id).toList(),
      );

      return players;
    } catch (e) {
      debugPrint('getPlayers — checking cache: $e');
      if (e is SocketException || e.toString().contains('network')) {
        final cached =
            await _cache.readList(OfflineCacheService.playersKey(teamId));
        if (cached != null) {
          return cached.map((d) => Player.fromMap(d)).toList();
        }
      }
      throw Exception('Error fetching players: $e');
    }
  }

  /// Paginated player fetch using Supabase .range() — powers infinite-scroll.
  Future<List<Player>> getPlayersPaginated({
    required String teamId,
    required int from,
    required int to,
  }) async {
    try {
      final response = await _supabase
          .from('players')
          .select()
          .eq('team_id', teamId)
          .order('name', ascending: true)
          .range(from, to);
      return (response as List).map((d) => Player.fromMap(d)).toList();
    } catch (e) {
      // For the first page only, fall back to offline cache.
      if (from == 0 &&
          (e is SocketException || e.toString().contains('network'))) {
        final cached =
            await _cache.readList(OfflineCacheService.playersKey(teamId));
        if (cached != null) {
          return cached
              .map((d) => Player.fromMap(d))
              .skip(from)
              .take(to - from + 1)
              .toList();
        }
      }
      throw Exception('Error fetching players: $e');
    }
  }

  /// Returns the Player row linked to the current user on [teamId], or null.
  Future<Player?> getMyPlayerOnTeam(String teamId) async {
    try {
      final userId = await _getCurrentUserId();
      if (userId == null) return null;

      final row = await _supabase
          .from('players')
          .select()
          .eq('team_id', teamId)
          .eq('user_id', userId)
          .maybeSingle();

      return row == null ? null : Player.fromMap(row);
    } catch (e) {
      debugPrint('getMyPlayerOnTeam error: $e');
      return null;
    }
  }

  /// Real-time Supabase stream of players for [teamId].
  Stream<List<Player>> getPlayerStream(String teamId) {
    return _supabase
        .from('players')
        .stream(primaryKey: ['id'])
        .eq('team_id', teamId)
        .order('name', ascending: true)
        .map((maps) => maps.map((m) => Player.fromMap(m)).toList());
  }

  /// Overwrites all mutable fields of a player row.
  Future<void> updatePlayer(Player player) async {
    try {
      await _supabase
          .from('players')
          .update(player.toMap())
          .eq('id', player.id);
    } catch (e) {
      debugPrint('updatePlayer error: $e');
      throw Exception('Error updating player: $e');
    }
  }

  /// Updates only the `status` column for a single player row.
  Future<void> updatePlayerStatus(String playerId, String status) async {
    try {
      await _supabase
          .from('players')
          .update({'status': status})
          .eq('id', playerId);
    } catch (e) {
      throw Exception('Error updating status: $e');
    }
  }

  /// Bulk-sets [status] on every player in [teamId].
  Future<void> bulkUpdateStatus(String teamId, String status) async {
    try {
      await _supabase
          .from('players')
          .update({'status': status})
          .eq('team_id', teamId);
    } catch (e) {
      throw Exception('Error bulk updating status: $e');
    }
  }

  /// Deletes multiple players by ID in a single query.
  Future<void> bulkDeletePlayers(List<String> playerIds) async {
    if (playerIds.isEmpty) return;
    try {
      await _supabase.from('players').delete().inFilter('id', playerIds);
    } catch (e) {
      throw Exception('Error bulk deleting players: $e');
    }
  }

  /// Deletes a single player.
  Future<void> deletePlayer(String id) async {
    try {
      await _supabase.from('players').delete().eq('id', id);
    } catch (e) {
      throw Exception('Failed to delete player: $e');
    }
  }

  /// Returns per-status counts. Falls back to all-zeros on any error.
  Future<Map<String, int>> getAttendanceSummary(String teamId) async {
    try {
      final players = await getPlayers(teamId);
      final summary = {'present': 0, 'absent': 0, 'late': 0, 'excused': 0};
      for (final p in players) {
        summary[p.status] = (summary[p.status] ?? 0) + 1;
      }
      return summary;
    } catch (e) {
      return {'present': 0, 'absent': 0, 'late': 0, 'excused': 0};
    }
  }

  // ===========================================================================
  // TEAM OPERATIONS
  // ===========================================================================

  // Optional in-memory cache for the team list (cleared by clearCache()).
  List<Map<String, dynamic>>? _teamsCache;

  /// Returns all teams the current user belongs to (any role), sorted by name.
  ///
  /// ISSUE 2 FIX: Added a retry loop so a freshly-created account has time for
  /// the on_auth_user_created trigger to commit the public.users row before
  /// we throw "User profile not found."  Up to _maxUserIdRetries × _userIdRetryDelay.
  Future<List<Map<String, dynamic>>> getTeams({bool forceRefresh = false}) async {
    // Return in-memory cache unless a refresh is explicitly requested.
    if (!forceRefresh && _teamsCache != null) return _teamsCache!;

    try {
      String? userId;

      // Retry loop — the DB trigger that creates the public.users row may
      // not have committed immediately after sign-up.
      for (int attempt = 1; attempt <= _maxUserIdRetries; attempt++) {
        userId = await _getCurrentUserId();
        if (userId != null) break;

        if (attempt < _maxUserIdRetries) {
          debugPrint(
            'getTeams: user profile not found yet, retry $attempt of $_maxUserIdRetries…',
          );
          // Wait before retrying and clear the null cache so _getCurrentUserId
          // will re-query the DB on the next iteration.
          await Future.delayed(_userIdRetryDelay);
          _cachedUserId = null;
        }
      }

      if (userId == null) {
        throw Exception(
          'User profile not found. Please sign out and sign in again.',
        );
      }

      final response = await _supabase
          .from('team_members')
          .select(
            'team_id, role, player_id, '
            'teams(id, team_name, sport, sport_id, created_at)',
          )
          .eq('user_id', userId)
          .order('teams(team_name)', ascending: true);

      _teamsCache = (response as List).map((item) {
        final team = item['teams'] as Map<String, dynamic>;
        final role = item['role'] as String;
        return {
          'id':         team['id'],
          'team_name':  team['team_name'],
          'sport':      team['sport'],
          'sport_id':   team['sport_id'],
          'created_at': team['created_at'],
          'role':       role,
          'is_owner':   role == 'owner',
          'is_coach':   role == 'coach' || role == 'owner',
          'is_player':  role == 'player',
          'player_id':  item['player_id'],
        };
      }).toList();

      return _teamsCache!;
    } catch (e) {
      debugPrint('getTeams error: $e');
      throw Exception('Error fetching teams: $e');
    }
  }

  /// Creates a new team via the updated create_team SECURITY DEFINER RPC.
  ///
  /// ISSUE 3 FIX: The DB function now accepts (p_team_name, p_sport, p_sport_id).
  /// This call matches that 3-param signature.
  Future<void> createTeam(
    String teamName,
    String sport, {
    String? sportId,
  }) async {
    try {
      final authUser = _supabase.auth.currentUser;
      if (authUser == null) {
        throw Exception('You must be logged in to create a team.');
      }

      await _supabase.rpc('create_team', params: {
        'p_team_name': teamName,
        'p_sport':     sport,
        // Omit p_sport_id entirely when null — the DB param has DEFAULT NULL.
        if (sportId != null) 'p_sport_id': sportId,
      });

      // Invalidate team list cache so the new team appears on next fetch.
      _teamsCache = null;
    } catch (e) {
      debugPrint('createTeam error: $e');
      throw Exception(e.toString().replaceAll('Exception: ', ''));
    }
  }

  /// Updates team metadata. Owner-only (enforced by DB policy).
  Future<void> updateTeam(
    String teamId,
    String teamName,
    String sport, {
    String? sportId,
  }) async {
    try {
      await _supabase.from('teams').update({
        'team_name': teamName,
        'sport':     sport,
        'sport_id':  sportId,
      }).eq('id', teamId);
      _teamsCache = null; // Invalidate cache after team update.
    } catch (e) {
      throw Exception('Error updating team: $e');
    }
  }

  /// Deletes a team (owner-only; cascades to players and team_members via FK).
  Future<void> deleteTeam(String teamId) async {
    try {
      final isOwner = await _isTeamOwner(teamId);
      if (!isOwner) throw Exception('Only team owners can delete teams.');
      await _supabase.from('teams').delete().eq('id', teamId);
      _teamsCache = null;
    } catch (e) {
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
      return null;
    }
  }

  // ── Ownership check ────────────────────────────────────────────────────────

  Future<bool> _isTeamOwner(String teamId) async {
    try {
      final userId = await _getCurrentUserId();
      if (userId == null) return false;
      final result = await _supabase
          .from('team_members')
          .select('role')
          .eq('team_id', teamId)
          .eq('user_id', userId)
          .maybeSingle();
      return result?['role'] == 'owner';
    } catch (_) {
      return false;
    }
  }

  // ===========================================================================
  // TEAM MEMBER OPERATIONS
  // ===========================================================================

  /// Returns the public.users row for the currently authenticated user.
  Future<Map<String, dynamic>?> getCurrentUser() async {
    try {
      final authUser = _supabase.auth.currentUser;
      if (authUser == null) return null;
      return await _supabase
          .from('users')
          .select()
          .eq('user_id', authUser.id)
          .single();
    } catch (e) {
      debugPrint('getCurrentUser error: $e');
      return null;
    }
  }

  /// Returns all members of [teamId] with their role and joined user profile.
  Future<List<TeamMember>> getTeamMembers(String teamId) async {
    try {
      final response = await _supabase
          .from('team_members')
          .select(
            'id, team_id, user_id, role, player_id, '
            'users(first_name, last_name, name, email, organization)',
          )
          .eq('team_id', teamId)
          .order('role',               ascending: true)
          .order('users(first_name)',  ascending: true);

      return (response as List).map((m) => TeamMember.fromMap(m)).toList();
    } catch (e) {
      debugPrint('getTeamMembers error: $e');
      throw Exception('Error fetching team members: $e');
    }
  }

  /// Adds a user to a team via the add_member_to_team SECURITY DEFINER RPC.
  ///
  /// ISSUE 1 FIX: The RPC now runs fully SECURITY DEFINER with the correct
  /// search_path so it can see any public.users row by email (bypassing RLS)
  /// and the resulting FK check on team_members.user_id succeeds.
  Future<void> addMemberToTeam({
    required String teamId,
    required String userEmail,
    required String role,
  }) async {
    try {
      await _supabase.rpc('add_member_to_team', params: {
        'p_team_id': teamId,
        'p_email':   userEmail,
        'p_role':    role,
      });
      _teamsCache = null; // Membership changed — invalidate team cache.
    } catch (e) {
      debugPrint('addMemberToTeam error: $e');
      throw Exception(e.toString().replaceAll('Exception: ', ''));
    }
  }

  /// Looks up a public.users row by email via SECURITY DEFINER RPC.
  ///
  /// ISSUE 4 FIX: The lookup_user_by_email function is created by the
  /// migration SQL. Returns { id, first_name, last_name, athlete_id } or null.
  /// Non-fatal — returns null on any error so add_player_screen can still
  /// advance to Page 2 for manual entry.
  Future<Map<String, dynamic>?> lookupUserByEmail(String email) async {
    try {
      final result = await _supabase.rpc('lookup_user_by_email', params: {
        'p_email': email.trim().toLowerCase(),
      });

      // The RPC returns a SETOF (array); take the first element if present.
      if (result is List && result.isNotEmpty) {
        return result.first as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      debugPrint('lookupUserByEmail error: $e');
      return null; // Non-fatal — caller advances to Page 2 anyway.
    }
  }

  /// Links a player row to the app account for [playerEmail].
  /// Calls the link_player_to_user SECURITY DEFINER RPC.
  Future<void> linkPlayerToAccount({
    required String teamId,
    required String playerId,
    required String playerEmail,
  }) async {
    try {
      await _supabase.rpc('link_player_to_user', params: {
        'p_team_id':      teamId,
        'p_player_id':    playerId,
        'p_player_email': playerEmail,
      });
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('No user found')) {
        throw Exception(
          'No account found for $playerEmail. The athlete must sign up first.',
        );
      } else if (msg.contains('No player found')) {
        throw Exception('Player not found on this team.');
      }
      throw Exception('Error linking player: $e');
    }
  }

  /// Links a guardian email to a player via the link_guardian_to_player RPC.
  Future<void> linkGuardianToPlayer({
    required String playerId,
    required String guardianEmail,
  }) async {
    try {
      await _supabase.rpc('link_guardian_to_player', params: {
        'p_player_id':      playerId,
        'p_guardian_email': guardianEmail,
      });
    } catch (e) {
      // Non-fatal — guardian may not have an account yet.
      debugPrint('linkGuardianToPlayer error (non-fatal): $e');
    }
  }

  /// Removes [userId] (public.users.id) from [teamId].
  Future<void> removeMemberFromTeam(String teamId, String userId) async {
    try {
      final currentUserId = await _getCurrentUserId();
      if (currentUserId == null) throw Exception('Not logged in.');

      final isRemovingSelf = userId == currentUserId;

      if (!isRemovingSelf) {
        // Only owners can remove other members.
        final ownerRow = await _supabase
            .from('team_members')
            .select('role')
            .eq('team_id', teamId)
            .eq('user_id', currentUserId)
            .maybeSingle();
        if (ownerRow == null || ownerRow['role'] != 'owner') {
          throw Exception('Only team owners can remove other members.');
        }
      }

      final memberRow = await _supabase
          .from('team_members')
          .select('role, player_id')
          .eq('team_id', teamId)
          .eq('user_id', userId)
          .single();

      // Prevent removing the sole owner.
      if (memberRow['role'] == 'owner') {
        final owners = await _supabase
            .from('team_members')
            .select('id')
            .eq('team_id', teamId)
            .eq('role', 'owner');
        if ((owners as List).length <= 1) {
          throw Exception(
            'Cannot remove the only owner. Transfer ownership first.',
          );
        }
      }

      // Un-link any player row associated with this membership.
      final linkedPlayerId = memberRow['player_id'] as String?;
      if (linkedPlayerId != null) {
        await _supabase
            .from('players')
            .update({'user_id': null})
            .eq('id', linkedPlayerId);
      }

      await _supabase
          .from('team_members')
          .delete()
          .eq('team_id', teamId)
          .eq('user_id', userId);

      _teamsCache = null;
    } catch (e) {
      throw Exception('Error removing member: $e');
    }
  }

  /// Transfers the 'owner' role to [newOwnerUserId].
  Future<void> transferOwnership(String teamId, String newOwnerUserId) async {
    try {
      final isOwner = await _isTeamOwner(teamId);
      if (!isOwner) throw Exception('Only the current owner can transfer ownership.');

      final currentUserId = await _getCurrentUserId();
      if (currentUserId == null) throw Exception('Not logged in.');

      // Demote current owner → coach, promote new owner.
      await _supabase
          .from('team_members')
          .update({'role': 'coach'})
          .eq('team_id', teamId)
          .eq('user_id', currentUserId);

      await _supabase
          .from('team_members')
          .update({'role': 'owner'})
          .eq('team_id', teamId)
          .eq('user_id', newOwnerUserId);

      _teamsCache = null;
    } catch (e) {
      throw Exception('Error transferring ownership: $e');
    }
  }

  /// Changes the role of an existing non-owner team member (owner-only).
  Future<void> updateMemberRole({
    required String teamId,
    required String userId,
    required String newRole,
  }) async {
    if (newRole == 'owner') {
      throw Exception('Use transferOwnership() to assign the owner role.');
    }
    try {
      final isOwner = await _isTeamOwner(teamId);
      if (!isOwner) throw Exception('Only team owners can change member roles.');
      await _supabase
          .from('team_members')
          .update({'role': newRole})
          .eq('team_id', teamId)
          .eq('user_id', userId);
    } catch (e) {
      throw Exception('Error updating member role: $e');
    }
  }

  // ===========================================================================
  // GAME ROSTER OPERATIONS
  // ===========================================================================

  /// Returns all saved game rosters for [teamId], newest first.
  Future<List<Map<String, dynamic>>> getGameRosters(String teamId) async {
    try {
      final response = await _supabase
          .from('game_rosters')
          .select()
          .eq('team_id', teamId)
          .order('created_at', ascending: false);

      final rows = (response as List).cast<Map<String, dynamic>>();
      await _cache.writeList(OfflineCacheService.gameRostersKey(teamId), rows);
      return rows;
    } catch (e) {
      if (e is SocketException || e.toString().contains('network')) {
        final cached =
            await _cache.readList(OfflineCacheService.gameRostersKey(teamId));
        if (cached != null) return cached;
      }
      throw Exception('Error fetching game rosters: $e');
    }
  }

  /// Returns a single game roster row by [rosterId], or null.
  Future<Map<String, dynamic>?> getGameRosterById(String rosterId) async {
    try {
      return await _supabase
          .from('game_rosters')
          .select()
          .eq('id', rosterId)
          .maybeSingle();
    } catch (e) {
      return null;
    }
  }

  /// Supabase Realtime stream of game_rosters for [teamId].
  /// The .stream() API pushes updates in real-time via WebSocket.
  Stream<List<Map<String, dynamic>>> getGameRosterStream(String teamId) {
    return _supabase
        .from('game_rosters')
        .stream(primaryKey: ['id'])
        .order('created_at', ascending: false)
        .map((rows) => rows
            .where((r) => r['team_id'] == teamId)
            .cast<Map<String, dynamic>>()
            .toList());
  }

  /// Inserts a new game roster row and returns the generated UUID.
  Future<String> createGameRoster({
    required String teamId,
    required String title,
    String? gameDate,
    int starterSlots = 5,
  }) async {
    try {
      final userId = await _getCurrentUserId();
      final result = await _supabase
          .from('game_rosters')
          .insert({
            'team_id':       teamId,
            'title':         title,
            'game_date':     gameDate,
            'starter_slots': starterSlots,
            'starters':      [],
            'substitutes':   [],
            if (userId != null) 'created_by': userId,
          })
          .select('id')
          .single();
      return result['id'] as String;
    } catch (e) {
      throw Exception('Error creating game roster: $e');
    }
  }

  /// Updates the starters and substitutes JSONB arrays on a roster row.
  Future<void> updateGameRosterLineup({
    required String rosterId,
    required List<Map<String, dynamic>> starters,
    required List<Map<String, dynamic>> substitutes,
  }) async {
    try {
      await _supabase.from('game_rosters').update({
        'starters':    starters,
        'substitutes': substitutes,
      }).eq('id', rosterId);
    } catch (e) {
      throw Exception('Error updating game roster lineup: $e');
    }
  }

  /// Deletes a saved game roster by [rosterId].
  Future<void> deleteGameRoster(String rosterId) async {
    try {
      await _supabase.from('game_rosters').delete().eq('id', rosterId);
    } catch (e) {
      throw Exception('Error deleting game roster: $e');
    }
  }
}