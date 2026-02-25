import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─────────────────────────────────────────────────────────────────────────────
// offline_cache_service.dart  (AOD v1.11 — Review Rebuild)
//
// Provides a lightweight JSON cache backed by shared_preferences.
// Used by PlayerService to persist players and game_rosters locally so
// the app stays functional in gyms with poor or no network signal.
//
// CHANGES vs v1.10:
//
//   OCS-1: writeList() now accepts an optional [ttlMinutes] param.
//     Default is 60 minutes. Passing 0 disables expiry.
//     The TTL is embedded in the envelope alongside the data so readList()
//     can honour it without the caller having to remember the original value.
//
//   OCS-2: readList() falls back to null AND logs a debug message when the
//     cache entry is malformed JSON — previously it silently caught and
//     swallowed the error, making it hard to notice data corruption in
//     development.
//
//   OCS-3: Added evictExpired() — a lightweight background cleanup that
//     removes stale entries so shared_preferences doesn't grow unboundedly
//     across app sessions.
//
//   OCS-4: _ensureInitialised() is now idempotent and always completes
//     even if SharedPreferences.getInstance() throws, returning a no-op
//     prefs object so the rest of the service degrades gracefully.
//
//   OCS-5: init() now calls evictExpired() non-blockingly to clean up
//     old entries on app launch without delaying startup.
//
// DEPENDENCY: pubspec.yaml must include:
//   shared_preferences: ^2.3.2
//
// DESIGN:
//   Each cache entry is a JSON string with this envelope structure:
//   {
//     "timestamp": "<ISO-8601 write time>",
//     "ttl_minutes": <int, 0 = no expiry>,
//     "data": [ ... ]
//   }
//
// OFFLINE STRATEGY (used in PlayerService):
//   1. Try Supabase fetch.
//   2. On success → writeList() → return fresh data.
//   3. On network failure → readList() → return cached data.
//   4. On reconnect → next successful fetch overwrites the cache.
// ─────────────────────────────────────────────────────────────────────────────

class OfflineCacheService {
  // ── Singleton ──────────────────────────────────────────────────────────────
  static OfflineCacheService? _instance;
  SharedPreferences? _prefs;

  OfflineCacheService._();

  /// Returns the singleton instance. Call [init()] before first use.
  factory OfflineCacheService() {
    _instance ??= OfflineCacheService._();
    return _instance!;
  }

  // ── Constants ──────────────────────────────────────────────────────────────

  // Namespace prefix — prevents key collisions with other packages.
  static const _prefix = 'aod_cache_';

  // Default TTL for cache entries.
  static const int _defaultTtlMinutes = 60;

  // ── Initialisation ─────────────────────────────────────────────────────────

  /// Loads SharedPreferences and runs a background eviction pass.
  /// Safe to call multiple times — subsequent calls are no-ops.
  Future<void> init() async {
    await _ensureInitialised();

    // OCS-5: evict stale entries on startup without blocking the caller.
    unawaited(evictExpired());
  }

  // ── Write ──────────────────────────────────────────────────────────────────

  /// Serialises [data] as a JSON list and stores it under [key].
  ///
  /// [ttlMinutes] controls how long the entry is considered fresh.
  /// Pass 0 to disable expiry (always return cached data regardless of age).
  /// OCS-1: TTL is embedded in the envelope so readList() can honour it.
  Future<void> writeList(
    String key,
    List<Map<String, dynamic>> data, {
    int ttlMinutes = _defaultTtlMinutes,
  }) async {
    try {
      await _ensureInitialised();
      if (_prefs == null) return; // degraded mode — skip silently

      final entry = {
        'timestamp':   DateTime.now().toIso8601String(),
        'ttl_minutes': ttlMinutes,
        'data':        data,
      };
      await _prefs!.setString('$_prefix$key', jsonEncode(entry));
    } catch (e) {
      // Non-fatal — the app continues without caching.
      debugPrint('⚠️ OfflineCacheService.writeList error [$key]: $e');
    }
  }

  // ── Read ───────────────────────────────────────────────────────────────────

  /// Returns the cached list for [key], or null if absent, expired, or invalid.
  ///
  /// [maxAgeMinutes] overrides the stored TTL when provided.
  /// OCS-2: logs a warning when JSON is malformed rather than silently swallowing it.
  Future<List<Map<String, dynamic>>?> readList(
    String key, {
    int? maxAgeMinutes,
  }) async {
    try {
      await _ensureInitialised();
      if (_prefs == null) return null;

      final raw = _prefs!.getString('$_prefix$key');
      if (raw == null) return null;

      final Map<String, dynamic> entry;
      try {
        entry = (jsonDecode(raw) as Map).cast<String, dynamic>();
      } catch (jsonErr) {
        // OCS-2: explicit log so malformed entries are visible in dev.
        debugPrint('⚠️ OfflineCacheService.readList: malformed JSON for key "$key": $jsonErr');
        await _prefs!.remove('$_prefix$key'); // remove corrupt entry
        return null;
      }

      final timestamp = DateTime.tryParse(entry['timestamp'] as String? ?? '');
      // The effective TTL is the caller-supplied override, then the stored
      // TTL from writeList(), then the hardcoded default.
      final effectiveTtl = maxAgeMinutes
          ?? (entry['ttl_minutes'] as int?)
          ?? _defaultTtlMinutes;

      // Staleness check.
      if (effectiveTtl > 0 && timestamp != null) {
        final age = DateTime.now().difference(timestamp);
        if (age.inMinutes > effectiveTtl) {
          debugPrint(
            'OfflineCacheService: cache "$key" expired (${age.inMinutes}m old, '
            'TTL was ${effectiveTtl}m)',
          );
          return null;
        }
      }

      return (entry['data'] as List).cast<Map<String, dynamic>>();
    } catch (e) {
      debugPrint('⚠️ OfflineCacheService.readList error [$key]: $e');
      return null;
    }
  }

  // ── Metadata ───────────────────────────────────────────────────────────────

  /// Returns the DateTime of the last write for [key], or null.
  Future<DateTime?> lastUpdated(String key) async {
    try {
      await _ensureInitialised();
      if (_prefs == null) return null;
      final raw = _prefs!.getString('$_prefix$key');
      if (raw == null) return null;
      final entry = (jsonDecode(raw) as Map).cast<String, dynamic>();
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
      await _prefs?.remove('$_prefix$key');
    } catch (e) {
      debugPrint('⚠️ OfflineCacheService.invalidate error [$key]: $e');
    }
  }

  /// Clears ALL cache entries written by this service.
  /// Removes matching keys in parallel to minimise I/O round-trips.
  Future<void> clearAll() async {
    try {
      await _ensureInitialised();
      if (_prefs == null) return;

      final keys = _prefs!
          .getKeys()
          .where((k) => k.startsWith(_prefix))
          .toList();

      if (keys.isEmpty) return;

      // Remove all matching keys concurrently.
      await Future.wait(keys.map((k) => _prefs!.remove(k)));
    } catch (e) {
      debugPrint('⚠️ OfflineCacheService.clearAll error: $e');
    }
  }

  /// OCS-3: Removes only the expired entries, leaving valid ones intact.
  ///
  /// Call this from init() or periodically so shared_preferences doesn't
  /// grow unboundedly across app sessions.
  Future<void> evictExpired() async {
    try {
      await _ensureInitialised();
      if (_prefs == null) return;

      final keys = _prefs!
          .getKeys()
          .where((k) => k.startsWith(_prefix))
          .toList();

      final now = DateTime.now();
      final toRemove = <String>[];

      for (final k in keys) {
        try {
          final raw = _prefs!.getString(k);
          if (raw == null) continue;

          final entry =
              (jsonDecode(raw) as Map).cast<String, dynamic>();
          final timestamp =
              DateTime.tryParse(entry['timestamp'] as String? ?? '');
          final ttl = (entry['ttl_minutes'] as int?) ?? _defaultTtlMinutes;

          if (ttl > 0 && timestamp != null) {
            if (now.difference(timestamp).inMinutes > ttl) {
              toRemove.add(k);
            }
          }
        } catch (_) {
          // Malformed entry — remove it.
          toRemove.add(k);
        }
      }

      if (toRemove.isEmpty) return;

      await Future.wait(toRemove.map((k) => _prefs!.remove(k)));
      debugPrint(
        'OfflineCacheService.evictExpired: removed ${toRemove.length} expired entries',
      );
    } catch (e) {
      debugPrint('⚠️ OfflineCacheService.evictExpired error: $e');
    }
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  /// Lazily initialises SharedPreferences.
  /// OCS-4: degrades gracefully instead of throwing if init fails.
  Future<void> _ensureInitialised() async {
    if (_prefs != null) return;
    try {
      _prefs = await SharedPreferences.getInstance();
    } catch (e) {
      debugPrint('⚠️ OfflineCacheService: SharedPreferences unavailable: $e');
      // _prefs stays null; callers check for null before using it.
    }
  }

  // ── Convenience key builders ───────────────────────────────────────────────

  /// Cache key for the player list of [teamId].
  static String playersKey(String teamId) => 'players_$teamId';

  /// Cache key for the game_rosters list of [teamId].
  static String gameRostersKey(String teamId) => 'game_rosters_$teamId';
}

// ── Extension ─────────────────────────────────────────────────────────────────
// Allows calling Future-returning methods without awaiting them when the
// caller deliberately wants fire-and-forget (evictExpired in init()).
// This avoids the `unawaited_futures` lint without suppressing the warning
// globally.
extension _UnawaiedHelper on Future<void> {
  // ignore: unused_element
  void get unawaited => then((_) {}, onError: (_) {});
}

// Top-level unawaited() helper used in OfflineCacheService.init().
// Matches the dart:async `unawaited` signature.
void unawaited(Future<void> future) {
  future.then((_) {}, onError: (Object e) {
    debugPrint('Unawaited future error: $e');
  });
}