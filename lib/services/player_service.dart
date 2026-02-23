import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/player.dart';
import '../models/app_user.dart';
import 'offline_cache_service.dart';

// =============================================================================
// player_service.dart  (AOD v1.7 — Bug Fix Release)
//
// ── CHANGES IN THIS VERSION ────────────────────────────────────────────────
//
// ISSUE 1 FIX (team_members_user_id_fkey FK violation on addMemberToTeam):
//   The DB-side RPC add_member_to_team is now SECURITY DEFINER with
//   SET search_path = public.  This lets it SELECT public.users by email
//   (bypassing RLS) and resolve a valid FK target before the INSERT into
//   team_members, eliminating the 23503 error.
//   No Flutter code change; the fix is in the migration SQL.
//
// ISSUE 2 FIX ("User profile not found" retry loop exhausted):
//   _userIdRetryDelay increased from 500 ms → 800 ms and _maxUserIdRetries
//   raised from 6 → 8, giving the on_auth_user_created DB trigger up to
//   6.4 s to commit the public.users row.  Additionally the trigger function
//   itself is fixed in the migration SQL (SET search_path = public).
//
// ISSUE 3 FIX (create_team FK 23503):
//   createTeam() already sends the correct payload.  The DB function is
//   fixed in the migration SQL (SECURITY DEFINER + SET search_path).
//
// ISSUE 4 FIX (lookup_user_by_email / change_user_email RPC errors):
//   Both RPC functions are rebuilt in the migration SQL with
//   SET search_path = public.  No Flutter change needed.
//
// OPTIMIZATION (v1.7): getTeams() in-memory cache avoids redundant round-trips
//   on navigation back to TeamSelectionScreen.  Cleared by clearCache().
// =============================================================================

class PlayerService {
  final _supabase = Supabase.instance.client;
  final _cache    = OfflineCacheService();

  // ===========================================================================
  // CURRENT USER HELPERS
  // ===========================================================================

  // Cache the resolved public.users.id for the lifetime of the session.
  // Nulled on clearCache() (sign-out) and between getTeams() retries.
  String? _cachedUserId;

  // ISSUE 2 FIX: raised from 6 → 8 retries and 500 ms → 800 ms delay.
  // Gives the on_auth_user_created trigger up to 6.4 s to commit.
  // This is combined with the DB-side trigger fix (SET search_path = public)
  // in the migration SQL.
  static const int      _maxUserIdRetries = 8;
  static const Duration _userIdRetryDelay = Duration(milliseconds: 800);

  /// Resolves auth.uid() → public.users.id.
  ///
  /// Returns null if the user is not signed in or the profile row does not
  /// exist yet (the DB trigger may still be committing on a fresh sign-up).
  /// Does NOT retry internally — all retry logic is in getTeams().
  Future<String?> _getCurrentUserId() async {
    // Return the cached value to avoid unnecessary DB round-trips.
    if (_cachedUserId != null) return _cachedUserId;

    try {
      final authUser = _supabase.auth.currentUser;
      if (authUser == null) return null;

      final row = await _supabase
          .from('users')
          .select('id')
          .eq('user_id', authUser.id)
          .maybeSingle();

      if (row != null) {
        _cachedUserId = row['id'] as String?;
      }
      return _cachedUserId;
    } catch (e) {
      debugPrint('_getCurrentUserId error: $e');
      return null;
    }
  }

  /// Clears all in-memory state.  Call this on sign-out so the next
  /// sign-in resolves a fresh user ID.
  void clearCache() {
    _cachedUserId = null;
    _teamsCache   = null;
  }

  // ===========================================================================
  // SPORTS OPERATIONS
  // ===========================================================================

  /// Fetches the full sports list ordered by name.
  /// Returns a fallback 'General' entry on any error so pickers still work.
  Future<List<Map<String, dynamic>>> getSports() async {
    try {
      final response = await _supabase
          .from('sports')
          .select('id, name, category')
          .order('name', ascending: true);
      return (response as List).cast<Map<String, dynamic>>();
    } catch (e) {
      debugPrint('getSports error: $e');
      return [{'id': null, 'name': 'General', 'category': 'Year-Round'}];
    }
  }

  // ===========================================================================
  // PLAYER OPERATIONS
  // ===========================================================================

  /// Inserts a new player row and returns the generated UUID.
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
  /// On network failure, reads from the offline cache if available.
  Future<List<Player>> getPlayers(String teamId) async {
    try {
      final response = await _supabase
          .from('players')
          .select()
          .eq('team_id', teamId)
          .order('name', ascending: true);

      final players = (response as List).map((d) => Player.fromMap(d)).toList();

      // Persist to offline cache for the next network failure.
      await _cache.writeList(
        OfflineCacheService.playersKey(teamId),
        players.map((p) => p.toMap()..['id'] = p.id).toList(),
      );

      return players;
    } catch (e) {
      debugPrint('getPlayers — checking offline cache: $e');
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

  /// Paginated player fetch — powers infinite scroll on the roster screen.
  /// Falls back to the offline cache on the first page if network is down.
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

  /// Overwrites all mutable fields on a player row.
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

  /// Updates only the `status` column for a single player.
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

  /// Sets [status] on every player in [teamId].
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

  /// Deletes multiple players by ID in one query.
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

  /// Returns per-status attendance counts. Falls back to all-zeros on error.
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
  /// ISSUE 2 FIX: Retry loop with increased limits (_maxUserIdRetries = 8,
  /// _userIdRetryDelay = 800 ms) gives the on_auth_user_created trigger up to
  /// 6.4 s to commit the public.users row after a fresh sign-up.
  /// _cachedUserId is cleared between iterations so each attempt re-queries
  /// the DB rather than reusing a cached null.
  Future<List<Map<String, dynamic>>> getTeams({bool forceRefresh = false}) async {
    // Return in-memory cache unless a refresh is explicitly requested.
    if (!forceRefresh && _teamsCache != null) return _teamsCache!;

    try {
      String? userId;

      // Retry loop — the DB trigger that creates public.users may not have
      // committed immediately after sign-up.
      for (int attempt = 1; attempt <= _maxUserIdRetries; attempt++) {
        userId = await _getCurrentUserId();
        if (userId != null) break;

        if (attempt < _maxUserIdRetries) {
          debugPrint(
            'getTeams: user profile not found yet, '
            'retry $attempt of $_maxUserIdRetries…',
          );
          await Future.delayed(_userIdRetryDelay);
          // Clear the cached null so the next _getCurrentUserId() re-queries.
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

  /// Creates a new team via the SECURITY DEFINER create_team RPC.
  ///
  /// ISSUE 3 FIX: The RPC now accepts (p_team_name, p_sport, p_sport_id) and
  /// runs SECURITY DEFINER so it can resolve the caller's public.users.id
  /// and insert into team_members without FK or RLS issues.
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

      // Invalidate cache so the new team appears on next fetch.
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
      _teamsCache = null;
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

  // ── Ownership check ─────────────────────────────────────────────────────────

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
          .order('role',              ascending: true)
          .order('users(first_name)', ascending: true);

      return (response as List).map((m) => TeamMember.fromMap(m)).toList();
    } catch (e) {
      debugPrint('getTeamMembers error: $e');
      throw Exception('Error fetching team members: $e');
    }
  }

  /// Adds a user to a team via the SECURITY DEFINER add_member_to_team RPC.
  ///
  /// ISSUE 1 FIX: The RPC is rebuilt in the migration SQL as SECURITY DEFINER
  /// with SET search_path = public so it can find any public.users row by
  /// email regardless of RLS, and the subsequent FK check passes.
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
      _teamsCache = null;
    } catch (e) {
      debugPrint('addMemberToTeam error: $e');
      throw Exception(e.toString().replaceAll('Exception: ', ''));
    }
  }

  /// Looks up a public.users row by email via the lookup_user_by_email RPC.
  ///
  /// ISSUE 4 FIX: The RPC is rebuilt in the migration SQL with
  /// SET search_path = public.  Returns null on any error so the caller
  /// can still advance to Page 2 for manual entry.
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
  /// Calls the SECURITY DEFINER link_player_to_user RPC.
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
  /// Non-fatal — the guardian may not have an account yet.
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

  /// Transfers the 'owner' role from the current user to [newOwnerUserId].
  Future<void> transferOwnership(String teamId, String newOwnerUserId) async {
    try {
      final isOwner = await _isTeamOwner(teamId);
      if (!isOwner) {
        throw Exception('Only the current owner can transfer ownership.');
      }

      final currentUserId = await _getCurrentUserId();
      if (currentUserId == null) throw Exception('Not logged in.');

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
      if (!isOwner) {
        throw Exception('Only team owners can change member roles.');
      }
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
  /// Falls back to offline cache on network failure.
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
  /// Pushes updates in real-time via WebSocket — no polling needed.
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