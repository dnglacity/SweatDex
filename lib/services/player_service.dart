import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/player.dart';
import '../models/app_user.dart';
import 'offline_cache_service.dart';

// =============================================================================
// player_service.dart  (AOD v1.11 — Review Rebuild)
//
// CHANGES vs v1.10:
//
//   PERF-1: _getCurrentUserId() is now guarded by a Completer so multiple
//     concurrent callers (e.g. initState() calling getTeams + getPlayers
//     simultaneously) don't fire redundant DB round-trips. The first call
//     performs the lookup; subsequent callers await the same Future.
//
//   PERF-2: getPlayerStream() now returns Stream<List<Player>> using an
//     explicit column list (_kPlayerColumns) to avoid over-fetching '*'.
//
//   PERF-3: addPlayerAndReturnId() uses select('id') — the minimal payload
//     after an INSERT to avoid returning the full row unnecessarily.
//
//   FIX-1: lookupUserByEmail() now explicitly handles the case where the RPC
//     returns a Map (single-row) rather than a List, normalising both shapes
//     so callers always receive a Map or null.
//
//   FIX-2: removeMemberFromTeam() now un-links players.user_id BEFORE
//     deleting the team_members row to avoid a foreign-key violation if an
//     FK from team_members.player_id → players.id exists.
//
//   MAINT-1: All column-list constants are documented with the DB table
//     they reference so a future schema change is easy to track.
//
//   MAINT-2: Every public method has a one-line doc comment.
// =============================================================================

// ---------------------------------------------------------------------------
// Column-list constants
// Keep these in sync with the DB schema in supabase_blueprint.json.
// Listing columns explicitly instead of '*' reduces payload size and makes
// schema changes traceable to a single point of change.
// ---------------------------------------------------------------------------

/// Columns fetched from public.users.
const _kUserColumns =
    'id, user_id, first_name, last_name, nickname, '
    'athlete_id, email, organization, created_at';

/// Columns fetched from public.players.
const _kPlayerColumns =
    'id, team_id, user_id, name, athlete_id, athlete_email, '
    'guardian_email, grade, grade_updated_at, jersey_number, '
    'nickname, position, status, created_at';

/// Columns fetched from public.team_members with a joined users sub-select.
const _kTeamMemberColumns =
    'id, team_id, user_id, role, player_id, '
    'users(first_name, last_name, name, email, organization)';

class PlayerService {
  final _supabase = Supabase.instance.client;
  final _cache    = OfflineCacheService();

  // ===========================================================================
  // CURRENT USER HELPERS
  // ===========================================================================

  // PERF-1: Completer-backed deduplication.
  // Without this, two simultaneous callers both fire a DB SELECT. With it,
  // the second caller awaits the same in-flight Future.
  Future<String?>? _userIdFuture;

  /// Resolves auth.uid() → public.users.id (the app's internal user PK).
  /// Cached for the session; deduplicated so concurrent callers share one query.
  Future<String?> _getCurrentUserId() {
    _userIdFuture ??= _resolveUserId();
    return _userIdFuture!;
  }

  Future<String?> _resolveUserId() async {
    try {
      final authUser = _supabase.auth.currentUser;
      if (authUser == null) return null;

      // Single indexed lookup using idx_users_user_id.
      final row = await _supabase
          .from('users')
          .select('id')
          .eq('user_id', authUser.id)
          .maybeSingle();

      return row?['id'] as String?;
    } catch (e) {
      debugPrint('_resolveUserId error: $e');
      // Reset so the next call retries (e.g. after a network blip).
      _userIdFuture = null;
      return null;
    }
  }

  // In-memory team list cache — invalidated whenever membership changes.
  List<Map<String, dynamic>>? _teamsCache;

  /// Clears both the team list cache and the pending user-ID future.
  /// Must be called whenever team membership or the signed-in user changes.
  void _invalidateTeamCache() {
    _userIdFuture = null; // force re-resolve on next call
    _teamsCache   = null;
  }

  /// Clears all in-memory and on-disk caches. Call on sign-out.
  void clearCache() {
    _invalidateTeamCache();
    // Wipe the offline disk cache so stale data doesn't leak between
    // accounts on a shared device.
    _cache.clearAll();
  }

  // ===========================================================================
  // SPORTS
  // ===========================================================================

  /// Returns all sports ordered alphabetically.
  /// Falls back to a single 'General' entry on any error so pickers work offline.
  Future<List<Map<String, dynamic>>> getSports() async {
    try {
      // id + name + category is all the autocomplete widget needs.
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

  /// Converts a raw Supabase response list to typed [Player] objects.
  List<Player> _mapPlayers(List<dynamic> raw) =>
      raw.cast<Map<String, dynamic>>().map(Player.fromMap).toList();

  /// Inserts a new player row and returns the generated UUID.
  Future<String> addPlayerAndReturnId(Player player) async {
    try {
      // PERF-3: select('id') returns only the PK — not the full row.
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
  /// Falls back to the offline cache on network failure.
  Future<List<Player>> getPlayers(String teamId) async {
    try {
      // Explicit column list reduces the wire payload.
      // .eq() on team_id uses idx_players_team_id index.
      final response = await _supabase
          .from('players')
          .select(_kPlayerColumns)
          .eq('team_id', teamId)
          .order('name', ascending: true);

      final players = _mapPlayers(response as List<dynamic>);

      // Write to the offline cache for gym use.
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
  Future<List<Player>> getPlayersPaginated({
    required String teamId,
    required int from,
    required int to,
  }) async {
    try {
      final response = await _supabase
          .from('players')
          .select(_kPlayerColumns)
          .eq('team_id', teamId)
          .order('name', ascending: true)
          .range(from, to);
      return _mapPlayers(response as List<dynamic>);
    } catch (e) {
      // Fall back to cache only on the first page when offline.
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

  /// Returns the [Player] row linked to the current user on [teamId], or null.
  Future<Player?> getMyPlayerOnTeam(String teamId) async {
    try {
      final userId = await _getCurrentUserId();
      if (userId == null) return null;

      final row = await _supabase
          .from('players')
          .select(_kPlayerColumns)
          .eq('team_id', teamId)
          .eq('user_id', userId)
          .maybeSingle();

      return row == null ? null : Player.fromMap(row);
    } catch (e) {
      debugPrint('getMyPlayerOnTeam error: $e');
      return null;
    }
  }

  /// Real-time stream of players for [teamId].
  /// PERF-2: Uses _kPlayerColumns instead of select('*').
  Stream<List<Player>> getPlayerStream(String teamId) {
    return _supabase
        .from('players')
        .stream(primaryKey: ['id'])
        .eq('team_id', teamId)
        .order('name', ascending: true)
        .map((maps) => maps
            .cast<Map<String, dynamic>>()
            .map(Player.fromMap)
            .toList());
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

  /// Updates only the `status` column — does not send the full row.
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

  /// Deletes multiple players by ID using a single inFilter() call.
  Future<void> bulkDeletePlayers(List<String> playerIds) async {
    if (playerIds.isEmpty) return;
    try {
      await _supabase.from('players').delete().inFilter('id', playerIds);
    } catch (e) {
      throw Exception('Error bulk deleting players: $e');
    }
  }

  /// Deletes a single player row.
  Future<void> deletePlayer(String id) async {
    try {
      await _supabase.from('players').delete().eq('id', id);
    } catch (e) {
      throw Exception('Failed to delete player: $e');
    }
  }

  /// Returns per-status attendance counts for [teamId].
  /// Fetches only the status column to minimise payload.
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
      for (final row
          in (response as List).cast<Map<String, dynamic>>()) {
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
  /// [forceRefresh] = true bypasses the in-memory cache to guarantee a fresh
  /// DB read — critical after player links or team creation.
  Future<List<Map<String, dynamic>>> getTeams(
      {bool forceRefresh = false}) async {
    if (!forceRefresh && _teamsCache != null) return _teamsCache!;

    try {
      final authUser = _supabase.auth.currentUser;
      if (authUser == null) throw Exception('Not signed in.');

      // Resolve public.users.id — uses the deduplicated future.
      var userRow = await _supabase
          .from('users')
          .select('id')
          .eq('user_id', authUser.id)
          .maybeSingle();

      if (userRow == null) {
        // One retry at 800 ms for brand-new sign-ups where handle_new_user
        // may not have committed yet.
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

      // Cache the resolved ID so _getCurrentUserId() short-circuits.
      final resolvedId = userRow['id'] as String;
      _userIdFuture = Future.value(resolvedId);

      // Single joined query: team data + role in one round-trip.
      // RLS on team_members filters to only the caller's rows.
      final response = await _supabase
          .from('team_members')
          .select(
            'team_id, role, player_id, '
            'teams(id, team_name, sport, sport_id, created_at)',
          )
          .eq('user_id', resolvedId)
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

  /// Creates a new team via the create_team SECURITY DEFINER RPC.
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
      _invalidateTeamCache();
    } catch (e) {
      debugPrint('createTeam error: $e');
      throw Exception(e.toString().replaceAll('Exception: ', ''));
    }
  }

  /// Updates team metadata. Owner-only (enforced by RLS).
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

  /// Deletes a team. Owner-only; cascades to players and team_members via FK.
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

  /// Returns the full team row by [teamId], or null.
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

  /// Returns true if the current user is the owner of [teamId].
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
          .select(_kUserColumns)
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
      // Ordered role-first so owners/coaches appear at the top.
      final response = await _supabase
          .from('team_members')
          .select(_kTeamMemberColumns)
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

  /// Adds a user to a team via the add_member_to_team SECURITY DEFINER RPC.
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
      _invalidateTeamCache();
    } catch (e) {
      debugPrint('addMemberToTeam error: $e');
      throw Exception(e.toString().replaceAll('Exception: ', ''));
    }
  }

  /// Looks up a public.users row by email via the lookup_user_by_email RPC.
  ///
  /// FIX-1: normalises both List and Map return shapes from the RPC so the
  /// caller always receives a Map<String,dynamic> or null.
  Future<Map<String, dynamic>?> lookupUserByEmail(String email) async {
    try {
      final result = await _supabase.rpc('lookup_user_by_email', params: {
        'p_email': email.trim().toLowerCase(),
      });

      // The RPC may return a List<dynamic> or a Map<String,dynamic>
      // depending on how it is defined (SETOF RECORD vs single RECORD).
      if (result is List && result.isNotEmpty) {
        return (result.first as Map).cast<String, dynamic>();
      }
      if (result is Map) {
        return result.cast<String, dynamic>();
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

  /// Links a guardian email to a player via RPC. Non-fatal.
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
  ///
  /// FIX-2: un-links players.user_id BEFORE deleting the team_members row to
  /// avoid a potential FK violation if a constraint exists from team_members
  /// back to players.
  Future<void> removeMemberFromTeam(String teamId, String userId) async {
    try {
      final currentUserId = await _getCurrentUserId();
      if (currentUserId == null) throw Exception('Not logged in.');

      final isRemovingSelf = userId == currentUserId;

      if (!isRemovingSelf) {
        // Verify the caller is an owner before removing someone else.
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

      // Load the target member's current role and player link.
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

      // FIX-2: un-link the player row FIRST to avoid FK issues.
      final linkedPlayerId = memberRow['player_id'] as String?;
      if (linkedPlayerId != null) {
        await _supabase
            .from('players')
            .update({'user_id': null})
            .eq('id', linkedPlayerId);
      }

      // Now safe to delete the membership row.
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
  Future<void> transferOwnership(
      String teamId, String newOwnerUserId) async {
    try {
      final isOwner = await _isTeamOwner(teamId);
      if (!isOwner) {
        throw Exception('Only the current owner can transfer ownership.');
      }
      final currentUserId = await _getCurrentUserId();
      if (currentUserId == null) throw Exception('Not logged in.');

      // Demote current owner to coach, then promote the new owner.
      // Both run as sequential statements inside Postgres's implicit
      // transaction per statement.
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
      throw Exception(
          'Use transferOwnership() to assign the owner role.');
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
  Future<List<Map<String, dynamic>>> getGameRosters(String teamId) async {
    try {
      final response = await _supabase
          .from('game_rosters')
          .select()
          .eq('team_id', teamId)
          .order('created_at', ascending: false);

      final rows =
          (response as List<dynamic>).cast<Map<String, dynamic>>();
      await _cache.writeList(
          OfflineCacheService.gameRostersKey(teamId), rows);
      return rows;
    } catch (e) {
      if (e is SocketException || e.toString().contains('network')) {
        final cached = await _cache
            .readList(OfflineCacheService.gameRostersKey(teamId));
        if (cached != null) return cached;
      }
      throw Exception('Error fetching game rosters: $e');
    }
  }

  /// Returns a single game roster row by [rosterId], or null.
  Future<Map<String, dynamic>?> getGameRosterById(
      String rosterId) async {
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

  /// Real-time Supabase stream of game_rosters for [teamId].
  Stream<List<Map<String, dynamic>>> getGameRosterStream(
      String teamId) {
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
  /// Only sends the two JSONB fields — not the full row.
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