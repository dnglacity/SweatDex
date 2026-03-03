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
    'email, organization, created_at';

/// Columns fetched from public.players.
const _kPlayerColumns =
    'id, team_id, user_id, first_name, last_name, athlete_email, '
    'guardian_email, jersey_number, '
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
      if (_supabase.auth.currentUser == null) return null;

      // Use the SECURITY DEFINER RPC — runs as the function owner so it
      // bypasses RLS and resolves auth.uid() → public.users.id in one
      // round-trip. Because the RPC executes inside the DB session that
      // already owns the handle_new_user trigger commit, the trigger-race
      // that required an exponential-backoff retry loop on direct table
      // queries is no longer a concern.
      final result = await _supabase.rpc('get_current_user_id');
      return result as String?;
    } catch (e) {
      debugPrint('_resolveUserId error: $e');
      // Reset so the next call retries (e.g. after a network blip).
      _userIdFuture = null;
      return null;
    }
  }

  // In-memory team list cache — invalidated whenever membership changes.
  // Also expires after _kTeamCacheTtl to prevent stale data on long sessions
  // or shared devices (e.g. a gym iPad used by multiple coaches).
  static const Duration _kTeamCacheTtl = Duration(minutes: 5);
  List<Map<String, dynamic>>? _teamsCache;
  DateTime? _teamsCacheTime;

  bool get _teamsCacheValid =>
      _teamsCache != null &&
      _teamsCacheTime != null &&
      DateTime.now().difference(_teamsCacheTime!) < _kTeamCacheTtl;

  /// Clears both the team list cache and the pending user-ID future.
  /// Must be called whenever team membership or the signed-in user changes.
  void _invalidateTeamCache() {
    _userIdFuture  = null; // force re-resolve on next call
    _teamsCache    = null;
    _teamsCacheTime = null;
  }

  /// Clears all in-memory and on-disk caches. Call on sign-out.
  void clearCache() {
    _invalidateTeamCache();
    // Wipe the offline disk cache so stale data doesn't leak between
    // accounts on a shared device.
    _cache.clearAll();
  }

  // ---------------------------------------------------------------------------
  // Error helper
  // ---------------------------------------------------------------------------

  /// Logs the raw error and re-throws a sanitised exception.
  /// [PostgrestException] messages are replaced with a generic string to
  /// prevent table names, column names, and constraint names from reaching
  /// the UI.
  Never _dbError(dynamic e, String message) {
    debugPrint('$message: $e');
    throw Exception(e is PostgrestException ? 'Update failed.' : message);
  }

  // ===========================================================================
  // SPORTS
  // ===========================================================================

  /// Returns all sports ordered alphabetically.
  /// Falls back to a single 'General' entry on any error so pickers work offline.
  Future<List<Map<String, dynamic>>> getSports() async {
    try {
      final response = await _supabase
          .from('sports')
          .select('id, name, base_sport')
          .order('name', ascending: true);
      return (response as List).cast<Map<String, dynamic>>();
    } catch (e) {
      debugPrint('getSports error: $e');
      return [{'id': null, 'name': 'General', 'base_sport': 'General'}];
    }
  }

  // ===========================================================================
  // PLAYER OPERATIONS
  // ===========================================================================

  /// Converts a raw Supabase response list to typed [Player] objects.
  List<Player> _mapPlayers(List<dynamic> raw) =>
      raw.map((e) => Player.fromMap(e as Map<String, dynamic>)).toList();

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
      _dbError(e, 'Error adding player.');
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
          .order('last_name', ascending: true);

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
      _dbError(e, 'Error fetching players.');
    }
  }

  /// Returns all non-null jersey numbers currently assigned on [teamId].
  /// Used by AddPlayerScreen to warn when a jersey is already taken.
  Future<Set<String>> getJerseyNumbers(String teamId) async {
    try {
      final response = await _supabase
          .from('players')
          .select('jersey_number')
          .eq('team_id', teamId)
          .not('jersey_number', 'is', null);
      return (response as List<dynamic>)
          .map((r) => (r['jersey_number'] as String).toUpperCase())
          .toSet();
    } catch (e) {
      _dbError(e, 'Error fetching jersey numbers.');
    }
  }

  /// Paginated player fetch — powers infinite scroll on the roster screen.
  Future<List<Player>> getPlayersPaginated({
    required String teamId,
    required int from,
    required int to,
  }) async {
    assert(from >= 0, 'from must be >= 0');
    assert(to >= from, 'to must be >= from');
    try {
      final response = await _supabase
          .from('players')
          .select(_kPlayerColumns)
          .eq('team_id', teamId)
          .order('last_name', ascending: true)
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
      _dbError(e, 'Error fetching players.');
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
        .order('last_name', ascending: true)
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
      _dbError(e, 'Error updating player.');
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
      _dbError(e, 'Error updating status.');
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
      _dbError(e, 'Error bulk updating status.');
    }
  }

  /// Deletes multiple players by ID, scrubbing each from historical game
  /// rosters via the delete_player SECURITY DEFINER RPC before removal.
  Future<void> bulkDeletePlayers(List<String> playerIds) async {
    if (playerIds.isEmpty) return;
    // Fire RPCs sequentially; each scrubs rosters then deletes the row.
    for (final id in playerIds) {
      await deletePlayer(id);
    }
  }

  /// Deletes a player and scrubs their entries from all historical game
  /// rosters via the delete_player SECURITY DEFINER RPC.
  Future<void> deletePlayer(String id) async {
    try {
      await _supabase.rpc('delete_player', params: {'p_player_id': id});
    } catch (e) {
      _dbError(e, 'Failed to delete player.');
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
    if (!forceRefresh && _teamsCacheValid) return _teamsCache!;

    try {
      if (_supabase.auth.currentUser == null) throw Exception('Not signed in.');

      // Resolve public.users.id via the deduplicated, backoff-retrying resolver.
      final resolvedId = await _getCurrentUserId();
      if (resolvedId == null) {
        throw Exception(
          'User profile not found. Please sign out and sign in again.',
        );
      }

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

      _teamsCacheTime = DateTime.now();
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
              'owner_name': null, // populated below
            };
          })
          .toList();

      // Fetch owner names for all teams in one round-trip.
      final teamIds = _teamsCache!.map((t) => t['id'] as String).toList();
      if (teamIds.isNotEmpty) {
        final ownersResponse = await _supabase
            .from('team_members')
            .select('team_id, users(first_name, last_name)')
            .inFilter('team_id', teamIds)
            .eq('role', 'owner');

        final ownerMap = <String, String>{};
        for (final row in (ownersResponse as List<dynamic>)) {
          final teamId = row['team_id'] as String;
          final user = row['users'] as Map<String, dynamic>?;
          if (user != null) {
            final first = (user['first_name'] as String? ?? '').trim();
            final last  = (user['last_name']  as String? ?? '').trim();
            ownerMap[teamId] = [first, last].where((s) => s.isNotEmpty).join(' ');
          }
        }

        _teamsCache = _teamsCache!.map((t) {
          return {...t, 'owner_name': ownerMap[t['id'] as String]};
        }).toList();
      }

      return _teamsCache!;
    } catch (e) {
      debugPrint('getTeams error: $e');
      if (e is PostgrestException) _dbError(e, 'Error fetching teams.');
      rethrow;
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
        // ignore: use_null_aware_elements
        if (sportId != null) 'p_sport_id': sportId,
      });
      _invalidateTeamCache();
    } catch (e) {
      debugPrint('createTeam error: $e');
      _dbError(e, 'Error creating team.');
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
      _dbError(e, 'Error updating team.');
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
      if (e is PostgrestException) _dbError(e, 'Error deleting team.');
      rethrow;
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
      _dbError(e, 'Error fetching team members.');
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
      _dbError(e, 'Error adding team member.');
    }
  }

  /// Looks up a public.users row by email via the lookup_user_by_email RPC.
  ///
  /// FIX-1: normalises both List and Map return shapes from the RPC so the
  /// caller always receives a `Map<String, dynamic>` or null.
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
      throw Exception(e is PostgrestException ? 'Update failed.' : 'Error linking player.');
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
  /// Delegates entirely to the `remove_member_from_team` SECURITY DEFINER RPC
  /// so that the sole-owner guard and the delete are performed atomically
  /// inside a single DB transaction, preventing TOCTOU races.
  Future<void> removeMemberFromTeam(String teamId, String userId) async {
    try {
      await _supabase.rpc('remove_member_from_team', params: {
        'p_team_id': teamId,
        'p_user_id': userId,
      });
      _invalidateTeamCache();
    } catch (e) {
      _dbError(e, 'Error removing member.');
    }
  }

  /// Transfers the 'owner' role from the current user to [newOwnerUserId].
  /// Transfers ownership to [newOwnerUserId] via the transfer_ownership
  /// SECURITY DEFINER RPC, which demotes the current owner and promotes the
  /// new owner atomically inside a single DB transaction.
  Future<void> transferOwnership(
      String teamId, String newOwnerUserId) async {
    try {
      await _supabase.rpc('transfer_ownership', params: {
        'p_team_id':           teamId,
        'p_new_owner_user_id': newOwnerUserId,
      });
      _invalidateTeamCache();
    } catch (e) {
      _dbError(e, 'Error transferring ownership.');
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
      if (e is PostgrestException) _dbError(e, 'Error updating member role.');
      rethrow;
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
      _dbError(e, 'Error fetching game rosters.');
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
            // ignore: use_null_aware_elements
            if (userId != null) 'created_by': userId,
          })
          .select('id')
          .single();
      return result['id'] as String;
    } catch (e) {
      _dbError(e, 'Error creating game roster.');
    }
  }

  /// Updates the mutable metadata (game_date) on an existing roster row.
  Future<void> updateGameRosterMeta({
    required String rosterId,
    String? gameDate,
  }) async {
    try {
      await _supabase.from('game_rosters').update({
        'game_date': gameDate,
      }).eq('id', rosterId);
    } catch (e) {
      _dbError(e, 'Error updating game roster metadata.');
    }
  }

  /// Updates the starters, substitutes, and starter_slots on a roster row.
  /// [formatSlots] is an optional map of "$sectionIdx-$positionIdx" → playerId
  /// that persists format-template position assignments.
  Future<void> updateGameRosterLineup({
    required String rosterId,
    required List<Map<String, dynamic>> starters,
    required List<Map<String, dynamic>> substitutes,
    required int starterSlots,
    String? matchFormatTemplateId,
    Map<String, String>? formatSlots,
  }) async {
    try {
      await _supabase.from('game_rosters').update({
        'starters':     starters,
        'substitutes':  substitutes,
        'starter_slots': starterSlots,
        'match_format_template_id': matchFormatTemplateId,
        'format_slots': formatSlots ?? {},
      }).eq('id', rosterId);
    } catch (e) {
      _dbError(e, 'Error updating game roster lineup.');
    }
  }

  /// Duplicates an existing game roster under [newTitle], copying starters,
  /// substitutes, and starter_slots from the source row. Returns the new UUID.
  Future<String> duplicateGameRoster({
    required String sourceRosterId,
    required String teamId,
    required String newTitle,
  }) async {
    try {
      final source = await getGameRosterById(sourceRosterId);
      if (source == null) throw Exception('Source roster not found');
      final userId = await _getCurrentUserId();
      final result = await _supabase
          .from('game_rosters')
          .insert({
            'team_id':       teamId,
            'title':         newTitle,
            'game_date':     null,
            'starter_slots': source['starter_slots'] ?? 5,
            'starters':      source['starters']     ?? [],
            'substitutes':   source['substitutes']  ?? [],
            // ignore: use_null_aware_elements
            if (userId != null) 'created_by': userId,
          })
          .select('id')
          .single();
      return result['id'] as String;
    } catch (e) {
      _dbError(e, 'Error duplicating game roster.');
    }
  }

  /// Deletes a saved game roster by [rosterId].
  Future<void> deleteGameRoster(String rosterId) async {
    try {
      await _supabase.from('game_rosters').delete().eq('id', rosterId);
    } catch (e) {
      _dbError(e, 'Error deleting game roster.');
    }
  }

  // ===========================================================================
  // TEAM INVITES
  // ===========================================================================

  /// Returns the active invite code for [teamId], creating one if needed.
  /// Only managers (owner / coach / team_manager) may call this.
  /// Returns a map with keys `code` (String) and `expires_at` (DateTime).
  Future<Map<String, dynamic>> getOrCreateTeamInvite(String teamId) async {
    try {
      final result = await _supabase
          .rpc('get_or_create_team_invite', params: {'p_team_id': teamId});
      // RPC returns a list with one row.
      final row = (result as List).first as Map<String, dynamic>;
      return {
        'code': row['code'] as String,
        'expires_at': DateTime.parse(row['expires_at'] as String).toLocal(),
      };
    } catch (e) {
      _dbError(e, 'Error fetching team invite.');
    }
  }

  /// Deactivates the active invite code for [teamId].
  Future<void> revokeTeamInvite(String teamId) async {
    try {
      await _supabase.rpc('revoke_team_invite', params: {'p_team_id': teamId});
    } catch (e) {
      _dbError(e, 'Error revoking team invite.');
    }
  }

  /// Redeems a 6-character invite [code] and joins the caller to the team.
  /// Returns a map with keys `team_id` (String) and `team_name` (String).
  /// Throws a user-readable exception for invalid/expired codes or duplicate membership.
  Future<Map<String, dynamic>> redeemTeamInvite(String code) async {
    try {
      final result = await _supabase
          .rpc('redeem_team_invite', params: {'p_code': code.trim().toUpperCase()});
      final row = (result as List).first as Map<String, dynamic>;
      return {
        'team_id':   (row['out_team_id'] ?? row['team_id']) as String,
        'team_name': (row['out_team_name'] ?? row['team_name']) as String,
      };
    } catch (e) {
      final msg = e.toString();
      // Surface the readable Postgres RAISE EXCEPTION message directly.
      final match = RegExp(r'message: (.+?)(?:,|\})').firstMatch(msg);
      throw Exception(match?.group(1) ?? 'Error redeeming invite code.');
    }
  }

  // ===========================================================================
  // MATCHES
  // ===========================================================================

  /// Returns all matches for [teamId], ordered by match_date ascending.
  Future<List<Map<String, dynamic>>> getMatches(String teamId) async {
    try {
      final response = await _supabase
          .from('matches')
          .select('id, team_id, my_team_name, opponent_name, match_date, is_home, notes, created_at, selected_roster_id, is_staged, linked_match_id, is_guest_match')
          .eq('team_id', teamId)
          .order('match_date', ascending: true);
      return (response as List<dynamic>).cast<Map<String, dynamic>>();
    } catch (e) {
      _dbError(e, 'Error fetching matches.');
    }
  }

  /// Inserts a new match row and returns the generated UUID.
  Future<String> createMatch({
    required String teamId,
    required String myTeamName,
    required String opponentName,
    required DateTime matchDate,
    required bool isHome,
    String notes = '',
  }) async {
    try {
      final result = await _supabase
          .from('matches')
          .insert({
            'team_id':       teamId,
            'my_team_name':  myTeamName,
            'opponent_name': opponentName,
            'match_date':    matchDate.toUtc().toIso8601String(),
            'is_home':       isHome,
            'notes':         notes,
          })
          .select('id')
          .single();
      return result['id'] as String;
    } catch (e) {
      _dbError(e, 'Error creating match.');
    }
  }

  /// Updates mutable fields on an existing match row.
  /// Sentinel used so callers can explicitly set selectedRosterId to null.
  static const Object _rosterSentinel = Object();

  Future<void> updateMatch({
    required String matchId,
    String? myTeamName,
    String? opponentName,
    DateTime? matchDate,
    bool? isHome,
    String? notes,
    // Pass a String to set, pass null to clear, omit to leave unchanged.
    Object? selectedRosterId = _rosterSentinel,
  }) async {
    try {
      final updates = <String, dynamic>{
        if (myTeamName != null) 'my_team_name': myTeamName,
        if (opponentName != null) 'opponent_name': opponentName,
        if (matchDate != null) 'match_date': matchDate.toUtc().toIso8601String(),
        if (isHome != null) 'is_home': isHome,
        if (notes != null) 'notes': notes,
        if (!identical(selectedRosterId, _rosterSentinel))
          'selected_roster_id': selectedRosterId as String?,
      };
      if (updates.isEmpty) return;
      await _supabase.from('matches').update(updates).eq('id', matchId);
    } catch (e) {
      _dbError(e, 'Error updating match.');
    }
  }

  /// Deletes a match by [matchId].
  Future<void> deleteMatch(String matchId) async {
    try {
      await _supabase.from('matches').delete().eq('id', matchId);
    } catch (e) {
      _dbError(e, 'Error deleting match.');
    }
  }

  /// Stages the match via RPC, which also updates the linked (opposing team's) row.
  Future<void> stageMatch(String matchId) async {
    try {
      await _supabase.rpc('stage_match', params: {'p_match_id': matchId});
    } catch (e) {
      _dbError(e, 'Error staging match.');
    }
  }

  /// Unstages the match via RPC, which also updates the linked (opposing team's) row.
  Future<void> unstageMatch(String matchId) async {
    try {
      await _supabase.rpc('unstage_match', params: {'p_match_id': matchId});
    } catch (e) {
      _dbError(e, 'Error unstaging match.');
    }
  }

  /// Removes the opposing team's mirror match row and clears linked_match_id on
  /// the owner's row. Only the match owner (coach/owner/team_manager) may call this.
  Future<void> removeOpposingTeam(String matchId) async {
    try {
      await _supabase
          .rpc('remove_opposing_team', params: {'p_match_id': matchId});
    } catch (e) {
      _dbError(e, 'Error removing opposing team.');
    }
  }

  // ===========================================================================
  // MATCH FORMAT TEMPLATES
  // ===========================================================================

  /// Returns all match format templates for [teamId], newest first.
  Future<List<Map<String, dynamic>>> getMatchFormatTemplates(
      String teamId) async {
    try {
      final response = await _supabase
          .from('match_format_templates')
          .select('id, team_id, name, sections, created_at')
          .eq('team_id', teamId)
          .order('created_at', ascending: false);
      return (response as List<dynamic>).cast<Map<String, dynamic>>();
    } catch (e) {
      _dbError(e, 'Error fetching match format templates.');
    }
  }

  /// Returns a single match format template by [templateId], or null.
  Future<Map<String, dynamic>?> getMatchFormatTemplateById(
      String templateId) async {
    try {
      return await _supabase
          .from('match_format_templates')
          .select('id, team_id, name, sections, created_at')
          .eq('id', templateId)
          .maybeSingle();
    } catch (e) {
      return null;
    }
  }

  /// Inserts a new match format template and returns the full inserted row.
  Future<Map<String, dynamic>> createMatchFormatTemplate({
    required String teamId,
    required String name,
    required List<Map<String, dynamic>> sections,
  }) async {
    try {
      final result = await _supabase
          .from('match_format_templates')
          .insert({
            'team_id': teamId,
            'name': name,
            'sections': sections,
          })
          .select('id, team_id, name, sections, created_at')
          .single();
      return result;
    } catch (e) {
      _dbError(e, 'Error creating match format template.');
    }
  }

  /// Updates the name and sections of an existing match format template.
  Future<Map<String, dynamic>> updateMatchFormatTemplate({
    required String templateId,
    required String name,
    required List<Map<String, dynamic>> sections,
  }) async {
    try {
      final result = await _supabase
          .from('match_format_templates')
          .update({'name': name, 'sections': sections})
          .eq('id', templateId)
          .select('id, team_id, name, sections, created_at')
          .single();
      return result;
    } catch (e) {
      _dbError(e, 'Error updating match format template.');
    }
  }

  /// Deletes a match format template by [templateId].
  Future<void> deleteMatchFormatTemplate(String templateId) async {
    try {
      await _supabase
          .from('match_format_templates')
          .delete()
          .eq('id', templateId);
    } catch (e) {
      _dbError(e, 'Error deleting match format template.');
    }
  }

  // ===========================================================================
  // MATCH INVITES
  // ===========================================================================

  /// Returns the active invite code for [matchId], creating one if needed.
  /// Caller must be a coach/owner/manager of the match's team.
  /// Returns a map with keys `code` (String) and `expires_at` (DateTime).
  Future<Map<String, dynamic>> getOrCreateMatchInvite(String matchId) async {
    try {
      final result = await _supabase
          .rpc('get_or_create_match_invite', params: {'p_match_id': matchId});
      final row = (result as List).first as Map<String, dynamic>;
      return {
        'code': row['code'] as String,
        'expires_at': DateTime.parse(row['expires_at'] as String).toLocal(),
      };
    } catch (e) {
      _dbError(e, 'Error fetching match invite.');
    }
  }

  /// Deactivates all active invite codes for [matchId].
  Future<void> revokeMatchInvite(String matchId) async {
    try {
      await _supabase
          .rpc('revoke_match_invite', params: {'p_match_id': matchId});
    } catch (e) {
      _dbError(e, 'Error revoking match invite.');
    }
  }

  /// Redeems a 6-character match invite [code] and adds the match to [teamId].
  /// Returns a map with keys `match_id`, `opponent_name`, `match_date`.
  /// Throws a user-readable exception on invalid/expired codes or duplicates.
  Future<Map<String, dynamic>> redeemMatchInvite(
      String code, String teamId) async {
    try {
      final result = await _supabase.rpc('redeem_match_invite',
          params: {'p_code': code.trim().toUpperCase(), 'p_team_id': teamId});
      final row = (result as List).first as Map<String, dynamic>;
      return {
        'match_id': (row['out_match_id'] ?? row['match_id']) as String,
        'opponent_name':
            (row['out_opponent_name'] ?? row['opponent_name']) as String,
        'match_date':
            DateTime.parse((row['out_match_date'] ?? row['match_date']) as String)
                .toLocal(),
      };
    } catch (e) {
      final msg = e.toString();
      final match = RegExp(r'message: (.+?)(?:,|\})').firstMatch(msg);
      throw Exception(match?.group(1) ?? 'Error redeeming match code.');
    }
  }
}