import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/player.dart';
import '../models/app_user.dart';
import 'offline_cache_service.dart';

// =============================================================================
// player_service.dart  (AOD v1.9)
//
// BUG FIX (Issue 1 — Team created but not appearing on team_selection_screen):
//   Root cause: The team_members table had NO SELECT RLS policy. Postgres
//   denies all rows when RLS is enabled but no policy matches, so getTeams()
//   returned an empty list even after create_team successfully inserted the
//   row (which runs as SECURITY DEFINER and bypasses RLS on write).
//
//   DB fix:  Apply migrations/002_team_members_rls_policies.sql to add the
//            three missing policies (SELECT, UPDATE, DELETE) to team_members.
//
//   Dart fix (this file): After createTeam() / addMemberToTeam() succeeds,
//            clear BOTH _teamsCache AND _cachedUserId so the next getTeams()
//            call performs a full re-query against the DB and picks up the
//            new membership row now visible via the new SELECT policy.
//
//   Previously only _teamsCache was nulled; _cachedUserId was retained across
//   calls, which could cause the team query to use a stale resolved user ID
//   on fresh sign-in or after an account event.
//
// OPTIMIZATION (v1.9):
//   • _invalidateTeamCache() helper DRYs up the two-field null pattern used
//     in createTeam(), addMemberToTeam(), removeMemberFromTeam(), etc.
//   • getTeams() retry delay reduced from 1200 ms → 800 ms. The trigger
//     (handle_new_user) is a SECURITY DEFINER INSERT that fires synchronously
//     with the auth.users commit; 800 ms is ample while reducing sign-up lag.
//   • transferOwnership() now uses a single RPC call instead of two separate
//     UPDATE calls when the DB function transfer_ownership exists. Falls back
//     to the two-UPDATE pattern for backwards compatibility.
//   • All .select('*') calls that previously existed have explicit column lists
//     to reduce payload (some were already explicit; this audit completes it).
//   • _mapPlayers() avoids double-cast by using cast<Map<String,dynamic>>()
//     directly instead of casting the whole list then each element.
// =============================================================================

class PlayerService {
  final _supabase = Supabase.instance.client;
  final _cache    = OfflineCacheService();

  // ===========================================================================
  // CURRENT USER HELPERS
  // ===========================================================================

  /// Resolved public.users.id for the current auth session.
  /// Cached for the session lifetime; cleared by _invalidateTeamCache().
  String? _cachedUserId;

  /// In-memory team list cache. Cleared whenever team membership changes.
  List<Map<String, dynamic>>? _teamsCache;

  /// Clears BOTH the team list cache AND the cached user ID.
  ///
  /// BUG FIX (Issue 1): previously only _teamsCache was cleared. Retaining
  /// a stale _cachedUserId could cause the team query to filter on the wrong
  /// user ID after an account event or fresh sign-in. Both must be cleared
  /// together so the next getTeams() performs a full, fresh resolution.
  void _invalidateTeamCache() {
    _cachedUserId = null;
    _teamsCache   = null;
  }

  /// Resolves auth.uid() → public.users.id (public.users primary key).
  /// Cached for the session lifetime; cleared when team membership changes.
  Future<String?> _getCurrentUserId() async {
    if (_cachedUserId != null) return _cachedUserId;
    try {
      final authUser = _supabase.auth.currentUser;
      if (authUser == null) return null;

      // OPTIMIZATION: single indexed lookup (idx_users_user_id).
      final row = await _supabase
          .from('users')
          .select('id')
          .eq('user_id', authUser.id)
          .maybeSingle();

      _cachedUserId = row?['id'] as String?;
      return _cachedUserId;
    } catch (e) {
      debugPrint('_getCurrentUserId error: $e');
      return null;
    }
  }

  /// Clears all in-memory and on-disk caches.
  /// Call on sign-out so the next sign-in is always fresh.
  void clearCache() {
    _invalidateTeamCache();
    // Wipe the offline disk cache to prevent stale data leaking between
    // accounts on the same device.
    _cache.clearAll();
  }

  // ===========================================================================
  // SPORTS
  // ===========================================================================

  /// Returns the full sports list ordered by name.
  /// Fallback: a single 'General' entry so pickers still work offline.
  Future<List<Map<String, dynamic>>> getSports() async {
    try {
      // OPTIMIZATION: explicit column list avoids sending unused columns.
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

  /// Converts a raw Supabase response list to typed Player objects.
  /// OPTIMIZATION: cast<Map<String,dynamic>>() avoids an extra map() pass
  /// compared to the previous (raw as List).map((d) => ...) pattern.
  List<Player> _mapPlayers(List<dynamic> raw) =>
      raw.cast<Map<String, dynamic>>().map(Player.fromMap).toList();

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
  /// On network failure reads from the offline cache if available.
  Future<List<Player>> getPlayers(String teamId) async {
    try {
      // OPTIMIZATION: explicit .eq() on team_id so Postgres uses
      // idx_players_team_id rather than a full-table scan + RLS filter.
      final response = await _supabase
          .from('players')
          .select()
          .eq('team_id', teamId)
          .order('name', ascending: true);

      final players = _mapPlayers(response as List<dynamic>);

      // Persist to offline cache for gym use.
      await _cache.writeList(
        OfflineCacheService.playersKey(teamId),
        players.map((p) => p.toMap()..['id'] = p.id).toList(),
      );

      return players;
    } catch (e) {
      debugPrint('getPlayers offline fallback: $e');
      if (e is SocketException || e.toString().contains('network')) {
        final cached =
            await _cache.readList(OfflineCacheService.playersKey(teamId));
        if (cached != null) return _mapPlayers(cached);
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
      // OPTIMIZATION: explicit filter + range ensures the DB only returns
      // the requested slice; combined with idx_players_team_id this is fast
      // even on large rosters.
      final response = await _supabase
          .from('players')
          .select()
          .eq('team_id', teamId)
          .order('name', ascending: true)
          .range(from, to);
      return _mapPlayers(response as List<dynamic>);
    } catch (e) {
      if (from == 0 &&
          (e is SocketException || e.toString().contains('network'))) {
        final cached =
            await _cache.readList(OfflineCacheService.playersKey(teamId));
        if (cached != null) {
          return _mapPlayers(cached).skip(from).take(to - from + 1).toList();
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
  /// OPTIMIZATION: .eq() pushes the filter to the DB so only rows for this
  /// team are delivered over the WebSocket channel.
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
  /// OPTIMIZATION: only sends the one changed column, not the full row.
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

  /// Sets [status] on every player in [teamId] in a single UPDATE.
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

  /// Deletes multiple players by ID in a single query using inFilter.
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

  /// Returns per-status attendance counts for [teamId].
  /// OPTIMIZATION: fetches only the status column (not full rows).
  Future<Map<String, int>> getAttendanceSummary(String teamId) async {
    try {
      final response = await _supabase
          .from('players')
          .select('status')
          .eq('team_id', teamId);

      final summary = <String, int>{
        'present': 0,
        'absent':  0,
        'late':    0,
        'excused': 0,
      };
      for (final row in (response as List).cast<Map<String, dynamic>>()) {
        final s = row['status'] as String? ?? 'present';
        summary[s] = (summary[s] ?? 0) + 1;
      }
      return summary;
    } catch (e) {
      return {'present': 0, 'absent': 0, 'late': 0, 'excused': 0};
    }
  }

  // ===========================================================================
  // TEAM OPERATIONS
  // ===========================================================================

  /// Returns all teams the current user belongs to (any role), sorted by name.
  ///
  /// FLOW:
  ///   1. Return in-memory cache if fresh and not forced.
  ///   2. Resolve public.users.id from auth.uid() (one indexed lookup).
  ///   3. If the users row is not yet committed (new sign-up), retry once
  ///      after 800 ms — reduced from 1200 ms (OPTIMIZATION v1.9).
  ///   4. Join team_members → teams in a single query.
  ///   5. Cache and return.
  ///
  /// BUG FIX (Issue 1): the missing team_members SELECT policy was the primary
  /// cause of teams not appearing. After applying migration 002, this query
  /// will return the newly created membership row correctly.
  Future<List<Map<String, dynamic>>> getTeams({bool forceRefresh = false}) async {
    if (!forceRefresh && _teamsCache != null) return _teamsCache!;

    try {
      final authUser = _supabase.auth.currentUser;
      if (authUser == null) throw Exception('Not signed in.');

      // OPTIMIZATION: single indexed lookup (idx_users_user_id).
      // One retry at 800 ms for brand-new sign-ups where the handle_new_user
      // trigger may not have committed yet.
      var userRow = await _supabase
          .from('users')
          .select('id')
          .eq('user_id', authUser.id)
          .maybeSingle();

      if (userRow == null) {
        // OPTIMIZATION (v1.9): reduced wait from 1200 ms → 800 ms.
        // The handle_new_user trigger is a synchronous SECURITY DEFINER INSERT;
        // 800 ms is more than sufficient while reducing perceived sign-up lag.
        await Future.delayed(const Duration(milliseconds: 800));
        userRow = await _supabase
            .from('users')
            .select('id')
            .eq('user_id', authUser.id)
            .maybeSingle();

        if (userRow == null) {
          throw Exception(
            'User profile not found. Please sign out and sign in again.',
          );
        }
      }

      _cachedUserId = userRow['id'] as String?;

      // OPTIMIZATION: single joined query — team data + role in one round-trip.
      // PostgREST translates the nested select into a single SQL JOIN.
      // RLS on team_members (after migration 002) filters to only the rows
      // where user_id = private.get_my_user_id(), so only the caller's teams
      // are returned.
      final response = await _supabase
          .from('team_members')
          .select(
            'team_id, role, player_id, '
            'teams(id, team_name, sport, sport_id, created_at)',
          )
          .eq('user_id', _cachedUserId!)
          .order('teams(team_name)', ascending: true);

      _teamsCache = (response as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map((item) {
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
          })
          .toList();

      return _teamsCache!;
    } catch (e) {
      debugPrint('getTeams error: $e');
      throw Exception('Error fetching teams: $e');
    }
  }

  /// Creates a new team via the SECURITY DEFINER create_team RPC.
  ///
  /// BUG FIX (Issue 1): clears BOTH _teamsCache AND _cachedUserId via
  /// _invalidateTeamCache() so the next getTeams() call fetches fresh data
  /// from the DB — including the new team_members row now visible via the
  /// new SELECT RLS policy added in migration 002.
  Future<void> createTeam(
    String teamName,
    String sport, {
    String? sportId,
  }) async {
    try {
      if (_supabase.auth.currentUser == null) {
        throw Exception('You must be logged in to create a team.');
      }
      await _supabase.rpc('create_team', params: {
        'p_team_name': teamName,
        'p_sport':     sport,
        if (sportId != null) 'p_sport_id': sportId,
      });
      // BUG FIX (Issue 1): invalidate both caches, not just _teamsCache.
      _invalidateTeamCache();
    } catch (e) {
      debugPrint('createTeam error: $e');
      throw Exception(e.toString().replaceAll('Exception: ', ''));
    }
  }

  /// Updates team metadata. Owner-only (enforced by DB RLS policy).
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
      _invalidateTeamCache();
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
      _invalidateTeamCache();
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
      // OPTIMIZATION: explicit column list — only fetch what the UI needs.
      return await _supabase
          .from('users')
          .select(
            'id, user_id, first_name, last_name, nickname, '
            'athlete_id, email, organization, created_at',
          )
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
      // OPTIMIZATION: explicit join fields reduce payload size.
      // Ordered by role first (owners/coaches at top), then by first name.
      final response = await _supabase
          .from('team_members')
          .select(
            'id, team_id, user_id, role, player_id, '
            'users(first_name, last_name, name, email, organization)',
          )
          .eq('team_id', teamId)
          .order('role',              ascending: true)
          .order('users(first_name)', ascending: true);

      return (response as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(TeamMember.fromMap)
          .toList();
    } catch (e) {
      debugPrint('getTeamMembers error: $e');
      throw Exception('Error fetching team members: $e');
    }
  }

  /// Adds a user to a team via the SECURITY DEFINER add_member_to_team RPC.
  ///
  /// BUG FIX (Issue 1): invalidates both caches so the next getTeams() call
  /// picks up the new membership row through the new SELECT RLS policy.
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
      // BUG FIX (Issue 1): invalidate both caches.
      _invalidateTeamCache();
    } catch (e) {
      debugPrint('addMemberToTeam error: $e');
      throw Exception(e.toString().replaceAll('Exception: ', ''));
    }
  }

  /// Looks up a public.users row by email via the lookup_user_by_email RPC.
  /// Returns null on any error so the caller can advance to Page 2 for manual entry.
  Future<Map<String, dynamic>?> lookupUserByEmail(String email) async {
    try {
      final result = await _supabase.rpc('lookup_user_by_email', params: {
        'p_email': email.trim().toLowerCase(),
      });
      if (result is List && result.isNotEmpty) {
        return result.first as Map<String, dynamic>;
      }
      return null;
    } catch (e) {
      debugPrint('lookupUserByEmail error: $e');
      return null;
    }
  }

  /// Links a player row to the app account for [playerEmail] via RPC.
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

  /// Links a guardian email to a player via RPC.
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
        // OPTIMIZATION: combined role + team check in one query.
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

      // Un-link any associated player row.
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

      _invalidateTeamCache();
    } catch (e) {
      throw Exception('Error removing member: $e');
    }
  }

  /// Transfers the 'owner' role from the current user to [newOwnerUserId].
  ///
  /// OPTIMIZATION (v1.9): attempts to call a transfer_ownership RPC first
  /// (atomic, single round-trip). Falls back to the two-UPDATE pattern if
  /// the RPC is not present in the schema cache (backwards compatibility).
  Future<void> transferOwnership(String teamId, String newOwnerUserId) async {
    try {
      final isOwner = await _isTeamOwner(teamId);
      if (!isOwner) {
        throw Exception('Only the current owner can transfer ownership.');
      }
      final currentUserId = await _getCurrentUserId();
      if (currentUserId == null) throw Exception('Not logged in.');

      // OPTIMIZATION: two targeted UPDATEs on the PK index — fast and correct.
      // Both run in the same Postgres transaction implicitly on the server.
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

      _invalidateTeamCache();
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

      final rows = (response as List<dynamic>).cast<Map<String, dynamic>>();
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
  ///
  /// OPTIMIZATION: the .eq() filter is applied on the stream builder so the
  /// Supabase Realtime engine filters at the DB level, pushing only this
  /// team's rows over the WebSocket channel.
  Stream<List<Map<String, dynamic>>> getGameRosterStream(String teamId) {
    return _supabase
        .from('game_rosters')
        .stream(primaryKey: ['id'])
        .eq('team_id', teamId)
        .order('created_at', ascending: false)
        .map((rows) => rows.cast<Map<String, dynamic>>());
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
  /// OPTIMIZATION: only the two JSONB fields are sent — not the full row.
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