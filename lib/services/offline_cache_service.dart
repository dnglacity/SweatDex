import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// ─────────────────────────────────────────────────────────────────────────────
// offline_cache_service.dart  (AOD v1.12)
//
// Provides a lightweight JSON cache backed by flutter_secure_storage.
// Used by PlayerService to persist players and game_rosters locally so
// the app stays functional in gyms with poor or no network signal.
//
// All cached data (player lists, game rosters) is PII and is stored in
// platform secure storage (iOS Keychain / Android Keystore) at rest.
//
// API is identical to the shared_preferences-backed v1.11 version so no
// callers need to change.
//
// WEB-ONLY FLAG:
//   When running on the web target (kIsWeb == true) the cache is entirely
//   disabled: writeList() is a no-op and readList() always returns null.
//   Web browsers have no secure on-device keystore comparable to iOS
//   Keychain / Android Keystore, so persisting PII there is inappropriate.
//   The app simply always fetches fresh data from Supabase on web.
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

  OfflineCacheService._();

  /// Returns the singleton instance. Call [init()] before first use.
  factory OfflineCacheService() {
    _instance ??= OfflineCacheService._();
    return _instance!;
  }

  // ── Storage ────────────────────────────────────────────────────────────────

  // Android options: use EncryptedSharedPreferences for extra protection.
  static const _androidOptions = AndroidOptions(
    encryptedSharedPreferences: true,
  );

  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: _androidOptions,
  );

  // ── Constants ──────────────────────────────────────────────────────────────

  // Namespace prefix — prevents key collisions with other packages.
  static const _prefix = 'aod_cache_';

  // Default TTL for cache entries.
  static const int _defaultTtlMinutes = 60;

  // ── Initialisation ─────────────────────────────────────────────────────────

  /// Runs a background eviction pass on startup.
  /// Safe to call multiple times.
  /// No-op on web (cache is disabled for that target).
  Future<void> init() async {
    if (kIsWeb) return;
    unawaited(evictExpired());
  }

  // ── Write ──────────────────────────────────────────────────────────────────

  /// Serialises [data] as a JSON list and stores it under [key].
  ///
  /// [ttlMinutes] controls how long the entry is considered fresh.
  /// Pass 0 to disable expiry.
  /// No-op on web (cache is disabled for that target).
  Future<void> writeList(
    String key,
    List<Map<String, dynamic>> data, {
    int ttlMinutes = _defaultTtlMinutes,
  }) async {
    if (kIsWeb) return;
    try {
      final entry = {
        'timestamp':   DateTime.now().toIso8601String(),
        'ttl_minutes': ttlMinutes,
        'data':        data,
      };
      await _storage.write(
        key:   '$_prefix$key',
        value: jsonEncode(entry),
      );
    } catch (e) {
      debugPrint('⚠️ OfflineCacheService.writeList error [$key]: $e');
    }
  }

  // ── Read ───────────────────────────────────────────────────────────────────

  /// Returns the cached list for [key], or null if absent, expired, or invalid.
  ///
  /// [maxAgeMinutes] overrides the stored TTL when provided.
  /// Always returns null on web (cache is disabled for that target).
  Future<List<Map<String, dynamic>>?> readList(
    String key, {
    int? maxAgeMinutes,
  }) async {
    if (kIsWeb) return null;
    try {
      final raw = await _storage.read(key: '$_prefix$key');
      if (raw == null) return null;

      final Map<String, dynamic> entry;
      try {
        entry = (jsonDecode(raw) as Map).cast<String, dynamic>();
      } catch (jsonErr) {
        debugPrint('⚠️ OfflineCacheService.readList: malformed JSON for key "$key": $jsonErr');
        await _storage.delete(key: '$_prefix$key');
        return null;
      }

      final timestamp = DateTime.tryParse(entry['timestamp'] as String? ?? '');
      final effectiveTtl = maxAgeMinutes
          ?? (entry['ttl_minutes'] as int?)
          ?? _defaultTtlMinutes;

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
  /// Always returns null on web (cache is disabled for that target).
  Future<DateTime?> lastUpdated(String key) async {
    if (kIsWeb) return null;
    try {
      final raw = await _storage.read(key: '$_prefix$key');
      if (raw == null) return null;
      final entry = (jsonDecode(raw) as Map).cast<String, dynamic>();
      return DateTime.tryParse(entry['timestamp'] as String? ?? '');
    } catch (_) {
      return null;
    }
  }

  // ── Invalidate ─────────────────────────────────────────────────────────────

  /// Removes a single cache entry for [key].
  /// No-op on web (cache is disabled for that target).
  Future<void> invalidate(String key) async {
    if (kIsWeb) return;
    try {
      await _storage.delete(key: '$_prefix$key');
    } catch (e) {
      debugPrint('⚠️ OfflineCacheService.invalidate error [$key]: $e');
    }
  }

  /// Clears ALL cache entries written by this service.
  /// No-op on web (cache is disabled for that target).
  Future<void> clearAll() async {
    if (kIsWeb) return;
    try {
      final all = await _storage.readAll();
      final keys = all.keys.where((k) => k.startsWith(_prefix)).toList();
      if (keys.isEmpty) return;
      await Future.wait(keys.map((k) => _storage.delete(key: k)));
    } catch (e) {
      debugPrint('⚠️ OfflineCacheService.clearAll error: $e');
    }
  }

  /// Removes only the expired entries, leaving valid ones intact.
  /// No-op on web (cache is disabled for that target).
  Future<void> evictExpired() async {
    if (kIsWeb) return;
    try {
      final all = await _storage.readAll();
      final now = DateTime.now();
      final toRemove = <String>[];

      for (final entry in all.entries) {
        if (!entry.key.startsWith(_prefix)) continue;
        try {
          final parsed = (jsonDecode(entry.value) as Map).cast<String, dynamic>();
          final timestamp = DateTime.tryParse(parsed['timestamp'] as String? ?? '');
          final ttl = (parsed['ttl_minutes'] as int?) ?? _defaultTtlMinutes;

          if (ttl > 0 && timestamp != null) {
            if (now.difference(timestamp).inMinutes > ttl) {
              toRemove.add(entry.key);
            }
          }
        } catch (_) {
          toRemove.add(entry.key); // malformed — remove
        }
      }

      if (toRemove.isEmpty) return;

      await Future.wait(toRemove.map((k) => _storage.delete(key: k)));
      debugPrint(
        'OfflineCacheService.evictExpired: removed ${toRemove.length} expired entries',
      );
    } catch (e) {
      debugPrint('⚠️ OfflineCacheService.evictExpired error: $e');
    }
  }

  // ── Convenience key builders ───────────────────────────────────────────────

  /// Cache key for the player list of [teamId].
  static String playersKey(String teamId) => 'players_$teamId';

  /// Cache key for the game_rosters list of [teamId].
  static String gameRostersKey(String teamId) => 'game_rosters_$teamId';
}

// Top-level unawaited() helper — fire-and-forget without suppressing the lint.
void unawaited(Future<void> future) {
  future.then((_) {}, onError: (Object e) {
    debugPrint('Unawaited future error: $e');
  });
}
