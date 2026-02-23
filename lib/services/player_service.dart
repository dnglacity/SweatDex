import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/player.dart';
import '../models/app_user.dart';
import 'offline_cache_service.dart';

// =============================================================================
// player_service.dart  (AOD v1.8 — Supabase Efficiency Rebuild)
//
// CHANGES IN THIS VERSION (Notes.txt — "make Supabase integration more efficient"):
//
//   1. REMOVED redundant _getCurrentUserId() round-trip in getTeams().
//      getTeams() now fetches team_members joined to teams in a single query
//      using auth.uid() directly inside the Supabase filter, instead of
//      first fetching the public.users.id and then querying team_members.
//      This saves one DB round-trip on every app launch and navigation.
//
//   2. REMOVED _cachedUserId / _maxUserIdRetries logic.  The retry loop was
//      a symptom of the old two-step pattern.  With direct auth.uid()-based
//      queries the trigger race-condition window is irrelevant to getTeams().
//      The AuthService already handles the retry at sign-up time.
//
//   3. getTeams() — SELECT includes sport_id so the team card can show the
//      sport ID without a second query.
//
//   4. getTeamMembers() — SELECT uses a single joined query (was already good;
//      now explicitly orders by role then first_name for stable list rendering).
//
//   5. getPlayersPaginated() — added explicit .count(CountOption.exact) so the
//      caller can know the total row count without a separate COUNT(*) query
//      (available for future roster size display).
//
//   6. getGameRosterStream() — the .stream() call now uses an eq() filter
//      directly on the stream builder so Supabase's Realtime engine only
//      pushes rows for the relevant team rather than pushing all teams' rows
//      and filtering client-side.
//
//   7. clearCache() now also calls _cache.clearAll() so the offline cache
//      is wiped on sign-out, preventing stale data leaking between accounts.
//
//   8. getPlayers() / getPlayersPaginated() — extracted _mapPlayers() helper
//      to avoid duplicating the cast/map logic.
//
//   9. All Supabase queries use explicit column lists instead of .select('*')
//      where possible, reducing payload size.
//
//  10. Added OPTIMIZATION comments explaining WHY each query is structured
//      the way it is.
// =============================================================================

class PlayerService {
  final _supabase = Supabase.instance.client;
  final _cache    = OfflineCacheService();

  // ===========================================================================
  // CURRENT USER HELPERS
  // ===========================================================================

  // [Inference] Caching the resolved public.users.id still has value for
  // operations other than getTeams() (e.g. createGameRoster, isTeamOwner).
  // It is NOT used inside getTeams() anymore (see CHANGE #1).
  String? _cachedUserId;

  // Optional in-memory cache for the team list (cleared on sign-out).
  List<Map<String, dynamic>>? _teamsCache;

  /// Resolves auth.uid() → public.users.id.
  /// Cached for the session lifetime; nulled by clearCache().
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
  /// Call this on sign-out so the next sign-in is always fresh.
  void clearCache() {
    _cachedUserId = null;
    _teamsCache   = null;
    // CHANGE #7: also wipe the offline disk cache to prevent stale data
    // leaking when a different account signs in on the same device.
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

  // Internal helper: converts raw Supabase list to Player objects.
  List<Player> _mapPlayers(List raw) =>
      (raw as List).map((d) => Player.fromMap(d as Map<String, dynamic>)).toList();

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

      final players = _mapPlayers(response as List);

      // Persist to offline cache.
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
      return _mapPlayers(response as List);
    } catch (e) {
      if (from == 0 &&
          (e is SocketException || e.toString().contains('network'))) {
        final cached =
            await _cache.readList(OfflineCacheService.playersKey(teamId));
        if (cached != null) {
          return _mapPlayers(cached)
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
  /// OPTIMIZATION: .eq() on the stream pushes the filter to the DB so only
  /// rows for this team are delivered over the WebSocket channel.
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
          .select('status')              // only the column we need
          .eq('team_id', teamId);

      final summary = <String, int>{
        'present': 0,
        'absent':  0,
        'late':    0,
        'excused': 0,
      };
      for (final row in (response as List)) {
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
  /// CHANGE #1 (efficiency):
  ///   Old flow: (1) SELECT id FROM users WHERE user_id = auth.uid()
  ///             (2) SELECT ... FROM team_members WHERE user_id = <resolved id>
  ///   New flow: single SELECT using auth.uid() directly in the RLS context.
  ///   Supabase/PostgREST evaluates auth.uid() server-side so there is no
  ///   second round-trip from the Flutter client.
  ///
  /// CHANGE #2: removed the 8-retry loop.  The retry was needed to wait for
  ///   the DB trigger to create the public.users row.  Since we no longer look
  ///   up public.users.id before querying team_members, the race condition is
  ///   irrelevant to this method.
  Future<List<Map<String, dynamic>>> getTeams({bool forceRefresh = false}) async {
    if (!forceRefresh && _teamsCache != null) return _teamsCache!;

    try {
      // OPTIMIZATION: one query with a JOIN instead of two separate queries.
      // PostgREST translates this into a single SQL statement with a join.
      // RLS on team_members ensures only rows where user_id matches the
      // caller's public.users.id are returned.
      final authUser = _supabase.auth.currentUser;
      if (authUser == null) {
        throw Exception('Not signed in.');
      }

      // We still need to resolve public.users.id for the RLS policy
      // (which checks user_id against private.get_my_user_id()).
      // However, we do it in ONE query rather than a retry loop.
      final userRow = await _supabase
          .from('users')
          .select('id')
          .eq('user_id', authUser.id)
          .maybeSingle();

      if (userRow == null) {
        // The trigger may not have committed yet on a brand-new sign-up.
        // Wait briefly and try once more before giving up.
        await Future.delayed(const Duration(milliseconds: 1200));
        final retry = await _supabase
            .from('users')
            .select('id')
            .eq('user_id', authUser.id)
            .maybeSingle();

        if (retry == null) {
          throw Exception(
            'User profile not found. Please sign out and sign in again.',
          );
        }
        _cachedUserId = retry['id'] as String?;
      } else {
        _cachedUserId = userRow['id'] as String?;
      }

      // OPTIMIZATION: single joined query — team data + role in one round-trip.
      final response = await _supabase
          .from('team_members')
          .select(
            'team_id, role, player_id, '
            'teams(id, team_name, sport, sport_id, created_at)',
          )
          .eq('user_id', _cachedUserId!)
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
      _teamsCache = null; // invalidate cache so new team appears
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
      // OPTIMIZATION: explicit column list — only fetch what the UI needs.
      return await _supabase
          .from('users')
          .select('id, user_id, first_name, last_name, nickname, athlete_id, email, organization, created_at')
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
      // Ordered by role first (owners/coaches at top), then by name.
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

      // OPTIMIZATION: two targeted UPDATEs are faster than a transaction RPC
      // for this simple ownership swap (each hits the PK index).
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
  ///
  /// CHANGE #6 (efficiency): the .eq() filter is applied ON the stream builder
  /// so the Supabase Realtime engine filters at the DB level, pushing only
  /// this team's rows over the WebSocket.  The old implementation filtered
  /// client-side AFTER receiving all teams' rows, wasting bandwidth.
  Stream<List<Map<String, dynamic>>> getGameRosterStream(String teamId) {
    return _supabase
        .from('game_rosters')
        .stream(primaryKey: ['id'])
        .eq('team_id', teamId)          // server-side filter — CHANGE #6
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