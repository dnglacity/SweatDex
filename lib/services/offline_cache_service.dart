import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─────────────────────────────────────────────────────────────────────────────
// offline_cache_service.dart  (AOD v1.10 — optimized clearAll)
//
// Provides a lightweight JSON cache backed by shared_preferences.
// Used by PlayerService to persist players and game_rosters locally so
// the app remains functional in gyms with poor or no network signal.
//
// CHANGE (v1.10):
//   • clearAll() now collects matching keys first, then removes them in a
//     single Future.wait() instead of sequential awaited removes — reduces
//     disk I/O round-trips on Android SharedPreferences.
//   • Added docstring to init() clarifying it is idempotent (safe to call
//     multiple times).
//
// DEPENDENCY: pubspec.yaml must include:
//   shared_preferences: ^2.3.2
//
// DESIGN:
//   • Cache entries are stored as JSON strings under namespaced keys, e.g.:
//       "aod_cache_players_<teamId>"
//       "aod_cache_game_rosters_<teamId>"
//   • Each entry includes an ISO-8601 timestamp for staleness detection.
//   • Non-fatal on read/write errors — failures are logged and ignored.
//
// OFFLINE STRATEGY (used in PlayerService):
//   1. Try Supabase fetch.
//   2. On success → write result to cache and return it.
//   3. On failure (SocketException / network error) → read from cache.
//   4. On reconnect → overwrite the cache on next successful fetch.
// ─────────────────────────────────────────────────────────────────────────────

class OfflineCacheService {
  // ── Singleton ──────────────────────────────────────────────────────────────
  // One SharedPreferences instance is shared for the entire app lifecycle.
  static OfflineCacheService? _instance;
  SharedPreferences? _prefs;

  OfflineCacheService._();

  /// Returns the singleton instance. Call [init()] before first use.
  factory OfflineCacheService() {
    _instance ??= OfflineCacheService._();
    return _instance!;
  }

  // ── Initialisation ─────────────────────────────────────────────────────────

  /// Loads the SharedPreferences instance.
  /// Safe to call multiple times — subsequent calls are no-ops.
  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  // Namespace prefix — prevents key collisions with other packages.
  static const _prefix = 'aod_cache_';

  // ── Write ──────────────────────────────────────────────────────────────────

  /// Serialises [data] as a JSON list and stores it under [key].
  /// A timestamp is written alongside the data for staleness detection.
  Future<void> writeList(String key, List<Map<String, dynamic>> data) async {
    try {
      await _ensureInitialised();
      // Wrap the list in an envelope containing a write timestamp.
      final entry = {
        'timestamp': DateTime.now().toIso8601String(),
        'data': data,
      };
      await _prefs!.setString('$_prefix$key', jsonEncode(entry));
    } catch (e) {
      // Cache writes are non-fatal — the app continues without caching.
      debugPrint('⚠️ OfflineCacheService.writeList error: $e');
    }
  }

  // ── Read ───────────────────────────────────────────────────────────────────

  /// Returns the cached list for [key], or null if absent or expired.
  ///
  /// [maxAgeMinutes] — entries older than this many minutes are treated as
  /// expired and null is returned. Pass null to always return cached data.
  Future<List<Map<String, dynamic>>?> readList(
    String key, {
    int? maxAgeMinutes,
  }) async {
    try {
      await _ensureInitialised();
      final raw = _prefs!.getString('$_prefix$key');
      if (raw == null) return null; // nothing cached

      final entry     = jsonDecode(raw) as Map<String, dynamic>;
      final timestamp = DateTime.tryParse(entry['timestamp'] as String? ?? '');

      // Staleness check — skip if the cache is too old.
      if (maxAgeMinutes != null && timestamp != null) {
        final age = DateTime.now().difference(timestamp);
        if (age.inMinutes > maxAgeMinutes) {
          debugPrint(
            'OfflineCacheService: cache "$key" expired (${age.inMinutes}m old)',
          );
          return null;
        }
      }

      // Cast the inner list to the expected type.
      return (entry['data'] as List).cast<Map<String, dynamic>>();
    } catch (e) {
      debugPrint('⚠️ OfflineCacheService.readList error: $e');
      return null;
    }
  }

  // ── Metadata ───────────────────────────────────────────────────────────────

  /// Returns the DateTime of the last write for [key], or null.
  Future<DateTime?> lastUpdated(String key) async {
    try {
      await _ensureInitialised();
      final raw = _prefs!.getString('$_prefix$key');
      if (raw == null) return null;
      final entry = jsonDecode(raw) as Map<String, dynamic>;
      return DateTime.tryParse(entry['timestamp'] as String? ?? '');
    } catch (_) {
      return null;
    }
  }

  // ── Invalidate ─────────────────────────────────────────────────────────────

  /// Removes a single cache entry for [key].
  Future<void> invalidate(String key) async {
    try {
      await _ensureInitialised();
      await _prefs!.remove('$_prefix$key');
    } catch (e) {
      debugPrint('⚠️ OfflineCacheService.invalidate error: $e');
    }
  }

  /// Clears ALL cache entries written by this service.
  ///
  /// CHANGE (v1.10): collects matching keys first, then removes them in
  /// parallel via Future.wait() — one fewer disk commit per key vs the
  /// previous sequential-await loop on Android SharedPreferences.
  Future<void> clearAll() async {
    try {
      await _ensureInitialised();

      // Collect all keys that belong to this service (prefixed with _prefix).
      final keys = _prefs!
          .getKeys()
          .where((k) => k.startsWith(_prefix))
          .toList();

      if (keys.isEmpty) return;

      // Remove all matching keys concurrently — avoids serial disk commits.
      await Future.wait(keys.map((k) => _prefs!.remove(k)));
    } catch (e) {
      debugPrint('⚠️ OfflineCacheService.clearAll error: $e');
    }
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  /// Lazily initialises SharedPreferences if [init()] was not called explicitly.
  Future<void> _ensureInitialised() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  // ── Convenience key builders ───────────────────────────────────────────────

  /// Returns the cache key for the player list of [teamId].
  static String playersKey(String teamId)     => 'players_$teamId';

  /// Returns the cache key for the game_rosters list of [teamId].
  static String gameRostersKey(String teamId) => 'game_rosters_$teamId';
}