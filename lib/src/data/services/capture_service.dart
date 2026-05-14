import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:h3_flutter/h3_flutter.dart' as h3lib;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/notification_service.dart';
import '../../../core/constants/game_rules.dart';
import '../../../models/game_tile.dart';
import 'streak_service.dart';

/// Handles capture persistence and Supabase sync for H3 tile captures.
class CaptureService {
  CaptureService({
    required this.supabaseClient,
    required this.h3Resolution,
    StreakService? streakService,
  })  : _streakService = streakService ?? StreakService(),
        _h3 = const h3lib.H3Factory().load();

  final SupabaseClient supabaseClient;
  final int h3Resolution;
  final h3lib.H3 _h3;
  final StreakService _streakService;

  static const _prefsKeyCaptured = 'captured_h3_cells_res9_v1';

  final Set<String> capturedHexes = {};
  final Map<String, GameTile> _capturedTilesByHex = {};
  final Map<String, String> nearbyOwnerByHex = {};
  final Map<String, GameTile> _nearbyTilesByHex = {};
  final Map<String, GameTile> _corridorTilesByHex = {};

  GameTile _buildOwnedTile(
    String hexLower, {
    DateTime? capturedAt,
    DateTime? lastRefreshedAt,
    int defendCount = 0,
  }) {
    final capturedTime = capturedAt ?? DateTime.now();
    final refreshedAt = lastRefreshedAt ?? capturedTime;
    return GameTile(
      h3Index: hexLower,
      ownership: TileOwnership.mine,
      ownerId: currentUserId,
      capturedAt: capturedTime,
      lastRefreshedAt: refreshedAt,
      protectedUntil: refreshedAt.add(
        const Duration(hours: GameRules.tileProtectionHours),
      ),
      isVisible: true,
      defendCount: defendCount,
    );
  }

  void _ensureCapturedTileRecord(
    String hexLower, {
    DateTime? capturedAt,
    DateTime? lastRefreshedAt,
    int? defendCount,
  }) {
    // Always overwrite when real timestamps are provided so Supabase data
    // replaces the DateTime.now() defaults created during loadFromPrefs.
    if (capturedAt != null || lastRefreshedAt != null || defendCount != null) {
      _capturedTilesByHex[hexLower] = _buildOwnedTile(
        hexLower,
        capturedAt: capturedAt,
        lastRefreshedAt: lastRefreshedAt,
        defendCount: defendCount ?? 0,
      );
    } else {
      _capturedTilesByHex.putIfAbsent(
        hexLower,
        () => _buildOwnedTile(hexLower),
      );
    }
  }

  GameTile _buildNearbyTile(
    String hexLower,
    String ownerUserId, {
    DateTime? capturedAt,
    DateTime? lastRefreshedAt,
    DateTime? protectedUntil,
  }) {
    final refreshedAt = lastRefreshedAt ?? capturedAt;
    return GameTile(
      h3Index: hexLower,
      ownership: ownerUserId == currentUserId
          ? TileOwnership.mine
          : TileOwnership.enemy,
      ownerId: ownerUserId,
      capturedAt: capturedAt,
      lastRefreshedAt: refreshedAt,
      protectedUntil: protectedUntil ??
          refreshedAt?.add(
            const Duration(hours: GameRules.tileProtectionHours),
          ),
      isVisible: true,
    );
  }

  String? get currentUserId => supabaseClient.auth.currentUser?.id;

  /// Conservative incremental reconciliation of the local capture cache
  /// against authoritative server ownership.  Pure / static so it can
  /// power both the nearby-ring and corridor-batch refresh paths from
  /// one well-tested code path.
  ///
  /// Mutates [capturedHexes] and [capturedTilesByHex] IN PLACE, removing
  /// only those hexes that the server explicitly reports as owned by
  /// someone other than [currentUserId].  Returns the list of pruned
  /// hexes (lowercase) so callers can emit telemetry / UI feedback.
  ///
  /// Conservative semantics — never prunes when:
  ///   - the hex is not in [queriedHexes] (out-of-scope, could be stale);
  ///   - the hex is in [queriedHexes] but missing from
  ///     [serverOwnerByHex] (partial fetch / row deleted by admin);
  ///   - the server reports the hex as owned by [currentUserId] (no-op).
  ///
  /// Gated in production by [FeatureFlags.cacheReconciliationEnabled].
  /// Currently NOT WIRED into the live refresh path — [loadFromSupabase]
  /// is the authoritative full-prune path on app start.  This function
  /// exists as the future incremental path; wiring is deliberate work,
  /// not a side-effect of importing this method.
  static List<String> reconcileCapturedHexes({
    required Set<String> capturedHexes,
    required Map<String, GameTile> capturedTilesByHex,
    required List<String> queriedHexes,
    required Map<String, String?> serverOwnerByHex,
    required String? currentUserId,
  }) {
    final lost = <String>[];
    for (final raw in queriedHexes) {
      final hex = raw.toLowerCase();
      if (!capturedHexes.contains(hex)) continue;
      if (!serverOwnerByHex.containsKey(hex)) continue;
      final serverOwner = serverOwnerByHex[hex];
      if (serverOwner == null) continue;
      if (serverOwner == currentUserId) continue;
      capturedHexes.remove(hex);
      capturedTilesByHex.remove(hex);
      lost.add(hex);
    }
    return lost;
  }

  /// Invalidate any local optimistic-capture record for [hexId].  Used by
  /// the FCM `tile_lost` push consumer (see `tileLostEvents` in
  /// notification_service) so the moment the server tells us we lost a
  /// tile, the local map flips colour without waiting for the next
  /// periodic ownership refresh.  Returns true if anything was actually
  /// removed, so callers can avoid unnecessary rebuilds when the cache
  /// was already in sync.
  ///
  /// Note: does NOT touch SharedPreferences-backed [capturedHexes] —
  /// that set is a per-device cache pruned by [loadFromSupabase] and
  /// [reconcileCapturedHexes].  The next periodic refresh will reconcile
  /// it; the in-memory tile maps are the rendering source of truth.
  bool invalidateLocalCaptureForHex(String hexId) {
    final lower = hexId.toLowerCase();
    final hadCaptured = _capturedTilesByHex.remove(lower) != null;
    final hadNearby = _nearbyTilesByHex.remove(lower) != null;
    return hadCaptured || hadNearby;
  }

  Future<void> ensureSignedIn() async {
    if (supabaseClient.auth.currentUser != null) return;
    await supabaseClient.auth.signInAnonymously();
    await NotificationService().storeToken(
      Supabase.instance.client.auth.currentUser!.id,
    );
  }

  Future<void> loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKeyCaptured);
    if (raw == null || raw.trim().isEmpty) return;

    try {
      final List<dynamic> list = jsonDecode(raw) as List<dynamic>;
      capturedHexes.clear();
      _capturedTilesByHex.clear();
      for (final item in list) {
        if (item is String && item.isNotEmpty) {
          final hexLower = item.toLowerCase();
          capturedHexes.add(hexLower);
          _ensureCapturedTileRecord(hexLower);
        }
      }
    } catch (_) {
      // ignore malformed data
    }
  }

  Future<void> saveToPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final list = capturedHexes.toList()..sort();
    await prefs.setString(_prefsKeyCaptured, jsonEncode(list));
  }

  Future<void> loadFromSupabase(String userId) async {
    final rows = await supabaseClient
        .from('user_tile_captures')
        .select('h3_hex, captured_at, last_refreshed_at, defend_count')
        .eq('user_id', userId)
        .eq('h3_res', h3Resolution) as List<dynamic>?;
    if (rows == null) return;

    bool changed = false;
    for (final r in rows) {
      if (r is Map && r['h3_hex'] is String) {
        final hex = (r['h3_hex'] as String).toLowerCase();
        if (capturedHexes.add(hex)) changed = true;
        _ensureCapturedTileRecord(
          hex,
          capturedAt: _parseDateTime(r['captured_at']),
          lastRefreshedAt: _parseDateTime(r['last_refreshed_at']),
          defendCount: _parseDefendCount(r['defend_count']),
        );
      }
    }

    if (changed) {
      await saveToPrefs();
    }
  }

  Future<void> _upsertCaptureWithMetadata({
    required String userId,
    required String hexLower,
    required DateTime capturedAt,
    required DateTime lastRefreshedAt,
    required DateTime protectedUntil,
  }) async {
    await supabaseClient.from('user_tile_captures').upsert(
      {
        'user_id': userId,
        'h3_res': h3Resolution,
        'h3_hex': hexLower,
        'captured_at': capturedAt.toUtc().toIso8601String(),
        'last_refreshed_at': lastRefreshedAt.toUtc().toIso8601String(),
        'protected_until': protectedUntil.toUtc().toIso8601String(),
      },
      onConflict: 'user_id,h3_res,h3_hex',
    );
    debugPrint('[Capture] user_tile_captures upsert OK for $hexLower');
  }

  Future<void> _upsertOwnershipWithMetadata({
    required String userId,
    required String hexLower,
    required DateTime capturedAt,
    required DateTime lastRefreshedAt,
    required DateTime protectedUntil,
  }) async {
    await supabaseClient.from('tile_captures').upsert(
      {
        'h3_res': h3Resolution,
        'h3_hex': hexLower,
        'owner_user_id': userId,
        'captured_at': capturedAt.toUtc().toIso8601String(),
        'last_refreshed_at': lastRefreshedAt.toUtc().toIso8601String(),
        'protected_until': protectedUntil.toUtc().toIso8601String(),
      },
      onConflict: 'h3_res,h3_hex',
    );
    debugPrint('[Capture] tile_captures upsert OK for $hexLower (owner=$userId)');
  }

  Future<void> refreshNearbyOwners(List<String> hexes) async {
    final rows = await supabaseClient
        .from('tile_captures')
        .select('h3_hex, owner_user_id, captured_at, last_refreshed_at, protected_until')
        .eq('h3_res', h3Resolution)
        .inFilter('h3_hex', hexes) as List<dynamic>?;
    if (rows == null) return;

    nearbyOwnerByHex.clear();
    _nearbyTilesByHex.clear();
    for (final r in rows) {
      if (r is Map && r['h3_hex'] is String && r['owner_user_id'] is String) {
        final hexLower = (r['h3_hex'] as String).toLowerCase();
        final ownerUserId = r['owner_user_id'] as String;

        nearbyOwnerByHex[hexLower] = ownerUserId;

        final capturedAt = _parseDateTime(r['captured_at']);
        final lastRefreshedAt = _parseDateTime(r['last_refreshed_at']);
        final protectedUntil = _parseDateTime(r['protected_until']);

        _nearbyTilesByHex[hexLower] = _buildNearbyTile(
          hexLower,
          ownerUserId,
          capturedAt: capturedAt,
          lastRefreshedAt: lastRefreshedAt,
          protectedUntil: protectedUntil,
        );
      }
    }
  }

  DateTime? _parseDateTime(dynamic raw) {
    if (raw is! String || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  /// Tolerant parse for `defend_count` from a Supabase row. Defaults to 0
  /// when missing, null, or not a number — older rows predating the
  /// Phase 1.2a column will surface as 0 (no badge), which is the
  /// correct collapsed state.
  int _parseDefendCount(dynamic raw) {
    if (raw is int) return raw < 0 ? 0 : raw;
    if (raw is num) return raw.toInt() < 0 ? 0 : raw.toInt();
    if (raw is String) {
      final parsed = int.tryParse(raw);
      if (parsed != null) return parsed < 0 ? 0 : parsed;
    }
    return 0;
  }

  Future<void> refreshNearbyOwnersForHex(
    String currentHex, {
    int ringSize = 7,
  }) async {
    final currentCell = BigInt.parse(currentHex, radix: 16);
    final neighbors = _h3.gridDisk(currentCell, ringSize);
    final hexes = neighbors.map((c) => c.toRadixString(16).toLowerCase()).toList();

    await refreshNearbyOwners(hexes);
  }

  Future<bool> markTileCaptured(String hexLower) async {
    final added = capturedHexes.add(hexLower);
    if (added) {
      _capturedTilesByHex[hexLower] = _buildOwnedTile(hexLower);
      await saveToPrefs();
    }
    return added;
  }

  Future<CaptureTileResult> captureTile(String hexLower) async {
    final normalizedHex = hexLower.toLowerCase();
    final existingTile = getTileByHex(normalizedHex);
    final now = DateTime.now();
    final capturedAt = (existingTile != null &&
            existingTile.ownership == TileOwnership.mine)
        ? (existingTile.capturedAt ?? now)
        : now;

    final capturedTile = _buildOwnedTile(
      normalizedHex,
      capturedAt: capturedAt,
      lastRefreshedAt: now,
    );

    debugPrint('[Capture] captureTile($normalizedHex) — userId=$currentUserId');

    // Optimistically update local state so the capture attempt can proceed.
    final wasAlreadyCaptured = capturedHexes.contains(normalizedHex);
    final previousCapturedTile = _capturedTilesByHex[normalizedHex];
    final previousNearbyTile = _nearbyTilesByHex[normalizedHex];
    final previousNearbyOwner = nearbyOwnerByHex[normalizedHex];

    capturedHexes.add(normalizedHex);
    _capturedTilesByHex[normalizedHex] = capturedTile;
    _nearbyTilesByHex.remove(normalizedHex);
    nearbyOwnerByHex.remove(normalizedHex);

    var synced = false;
    final userId = currentUserId;
    if (userId != null) {
      try {
        await _upsertCaptureWithMetadata(
          userId: userId,
          hexLower: normalizedHex,
          capturedAt: capturedTile.capturedAt!,
          lastRefreshedAt: capturedTile.lastRefreshedAt!,
          protectedUntil: capturedTile.protectedUntil!,
        );
        await _upsertOwnershipWithMetadata(
          userId: userId,
          hexLower: normalizedHex,
          capturedAt: capturedTile.capturedAt!,
          lastRefreshedAt: capturedTile.lastRefreshedAt!,
          protectedUntil: capturedTile.protectedUntil!,
        );
        synced = true;
        debugPrint('[Capture] ✅ Supabase sync OK for $normalizedHex');

        // Record streak day-of-capture (Phase 1.1 — runs regardless of
        // FeatureFlags.streakSystemEnabled so the count is meaningful
        // when the UI flag flips on later).  Fire-and-forget: must
        // never block the capture path.
        unawaited(_streakService.recordCaptureToday());

        // ── Gameplay notifications (fire-and-forget) ──
        // Trigger 1: notify previous owner their tile was taken.
        if (previousNearbyOwner != null && previousNearbyOwner != userId) {
          NotificationService().notifyTileLost(
            previousOwnerId: previousNearbyOwner,
            h3Hex: normalizedHex,
          );
        }
        // Trigger 2: schedule "tile vulnerable" local reminder.
        if (capturedTile.protectedUntil != null) {
          NotificationService().scheduleVulnerableReminder(
            h3Hex: normalizedHex,
            protectedUntil: capturedTile.protectedUntil!,
          );
        }
      } catch (e) {
        debugPrint('[Capture] ❌ Supabase sync FAILED for $normalizedHex: $e');
        // Roll back local state — capture did not persist to shared world.
        if (!wasAlreadyCaptured) {
          capturedHexes.remove(normalizedHex);
          _capturedTilesByHex.remove(normalizedHex);
        } else if (previousCapturedTile != null) {
          _capturedTilesByHex[normalizedHex] = previousCapturedTile;
        }
        if (previousNearbyTile != null) {
          _nearbyTilesByHex[normalizedHex] = previousNearbyTile;
        }
        if (previousNearbyOwner != null) {
          nearbyOwnerByHex[normalizedHex] = previousNearbyOwner;
        }
        // Weak-signal grace: remember the intent so a brief connectivity
        // drop does not unfairly discard legitimate on-trail progress.
        // Truth-first: no local ownership is awarded here — this queue
        // only replays the same Supabase upsert on the next refresh.
        _enqueuePending(
          hexLower: normalizedHex,
          userId: userId,
          capturedAt: capturedTile.capturedAt!,
          previousNearbyOwner: previousNearbyOwner,
        );
      }
    } else {
      debugPrint('[Capture] ⚠️ No userId — cannot sync $normalizedHex');
      // No user = no shared-world persistence. Roll back.
      if (!wasAlreadyCaptured) {
        capturedHexes.remove(normalizedHex);
        _capturedTilesByHex.remove(normalizedHex);
      } else if (previousCapturedTile != null) {
        _capturedTilesByHex[normalizedHex] = previousCapturedTile;
      }
      if (previousNearbyTile != null) {
        _nearbyTilesByHex[normalizedHex] = previousNearbyTile;
      }
      if (previousNearbyOwner != null) {
        nearbyOwnerByHex[normalizedHex] = previousNearbyOwner;
      }
    }

    // Only persist locally if the capture actually synced.
    if (synced) {
      await saveToPrefs();
    }

    return CaptureTileResult(
      tile: capturedTile,
      synced: synced,
    );
  }

  bool isCaptured(String hex) => capturedHexes.contains(hex);

  GameTile? getTileByHex(String hex) {
    final normalizedHex = hex.toLowerCase();
    return _capturedTilesByHex[normalizedHex] ?? _nearbyTilesByHex[normalizedHex];
  }

  /// Returns the H3 hex string for the given [lat]/[lng] at [h3Resolution].
  Future<String> getCurrentHexForPosition(double lat, double lng) async {
    final cell = _h3.geoToCell(
      h3lib.GeoCoord(lat: lat, lon: lng),
      h3Resolution,
    );
    return cell.toRadixString(16).toLowerCase();
  }

  Future<List<GameTile>> getCapturedTilesForCurrentUser() async {
    return capturedHexes
      .map(
        (hex) =>
        _capturedTilesByHex[hex] ?? _buildOwnedTile(hex),
      )
        .toList();
  }

  Future<List<GameTile>> getNearbyTiles() async {
    final tiles = <GameTile>[];
    for (final entry in nearbyOwnerByHex.entries) {
      final hexLower = entry.key;
      if (capturedHexes.contains(hexLower)) continue;

      tiles.add(
        _nearbyTilesByHex[hexLower] ?? _buildNearbyTile(hexLower, entry.value),
      );
    }

    tiles.sort((a, b) => a.h3Index.compareTo(b.h3Index));
    return tiles;
  }

  /// Fetches ownership for corridor hex IDs from the shared [tile_captures]
  /// table.  Results are stored separately from the nearby ring so they
  /// survive [refreshNearbyOwners] clears.
  Future<void> refreshCorridorOwners(List<String> hexes) async {
    if (hexes.isEmpty) return;

    _corridorTilesByHex.clear();

    // Batch to stay within Supabase REST URL-length limits.
    const batchSize = 200;
    for (var i = 0; i < hexes.length; i += batchSize) {
      final batch = hexes.sublist(i, math.min(i + batchSize, hexes.length));
      final rows = await supabaseClient
          .from('tile_captures')
          .select('h3_hex, owner_user_id, captured_at, last_refreshed_at, protected_until')
          .eq('h3_res', h3Resolution)
          .inFilter('h3_hex', batch) as List<dynamic>?;
      if (rows == null) continue;

      for (final r in rows) {
        if (r is Map && r['h3_hex'] is String && r['owner_user_id'] is String) {
          final hexLower = (r['h3_hex'] as String).toLowerCase();
          final ownerUserId = r['owner_user_id'] as String;
          _corridorTilesByHex[hexLower] = _buildNearbyTile(
            hexLower,
            ownerUserId,
            capturedAt: _parseDateTime(r['captured_at']),
            lastRefreshedAt: _parseDateTime(r['last_refreshed_at']),
            protectedUntil: _parseDateTime(r['protected_until']),
          );
        }
      }
    }
  }

  /// Returns corridor tiles not already covered by [capturedHexes] or
  /// [nearbyOwnerByHex] (those are already in their respective lists).
  Future<List<GameTile>> getCorridorTiles() async {
    return _corridorTilesByHex.entries
        .where((e) =>
            !capturedHexes.contains(e.key) &&
            !nearbyOwnerByHex.containsKey(e.key))
        .map((e) => e.value)
        .toList();
  }

  Map<String, String> getKnownOwnerByHex() {
    final known = <String, String>{};
    final mineOwner = currentUserId ?? '__local_player__';

    for (final hex in capturedHexes) {
      known[hex] = mineOwner;
    }

    for (final entry in nearbyOwnerByHex.entries) {
      if (!known.containsKey(entry.key)) {
        known[entry.key] = entry.value;
      }
    }

    return known;
  }

  // ── Weak-signal grace / pending capture queue ───────────────────────────
  //
  // Short connectivity drops during a legitimate session should not
  // discard on-trail progress outright.  When captureTile() fails to sync
  // we roll back local state (truth-first) but record the intent here.
  // flushPendingCaptures() re-runs the same Supabase upsert on the next
  // refresh; only confirmed entries award shared ownership.  Bounded in
  // size and age so this never becomes a full offline mode.

  static const int _maxPendingCaptures = 5;
  static const Duration _pendingCaptureTtl = Duration(minutes: 3);

  final List<_PendingCapture> _pendingCaptures = [];

  bool get hasPendingCaptures => _pendingCaptures.isNotEmpty;
  int get pendingCaptureCount => _pendingCaptures.length;

  void _enqueuePending({
    required String hexLower,
    required String userId,
    required DateTime capturedAt,
    String? previousNearbyOwner,
  }) {
    // De-dupe by hex: latest intent wins.
    _pendingCaptures.removeWhere((p) => p.hexLower == hexLower);
    _pendingCaptures.add(_PendingCapture(
      hexLower: hexLower,
      userId: userId,
      capturedAt: capturedAt,
      previousNearbyOwner: previousNearbyOwner,
    ));
    // Drop oldest if over cap.
    while (_pendingCaptures.length > _maxPendingCaptures) {
      _pendingCaptures.removeAt(0);
    }
    debugPrint(
      '[Capture] pending queue now ${_pendingCaptures.length} (added $hexLower)',
    );
  }

  /// Attempts to re-sync any queued pending captures.  Called opportunistically
  /// from the refresh cycle.  Returns the number of entries that were
  /// confirmed (shared-world sync succeeded on this pass).
  Future<int> flushPendingCaptures() async {
    if (_pendingCaptures.isEmpty) return 0;

    final userId = currentUserId;
    if (userId == null) return 0;

    final now = DateTime.now();
    // Drop expired entries — no long-session backfill.
    _pendingCaptures.removeWhere(
      (p) => now.difference(p.capturedAt) > _pendingCaptureTtl,
    );
    if (_pendingCaptures.isEmpty) return 0;

    // Replay in original order to preserve event sequence.
    final snapshot = List<_PendingCapture>.from(_pendingCaptures);
    var confirmed = 0;

    for (final pending in snapshot) {
      // Only the signed-in user may flush their own queue entries.
      if (pending.userId != userId) {
        _pendingCaptures.remove(pending);
        continue;
      }

      final lastRefreshedAt = DateTime.now();
      final protectedUntil = lastRefreshedAt.add(
        const Duration(hours: GameRules.tileProtectionHours),
      );

      try {
        await _upsertCaptureWithMetadata(
          userId: userId,
          hexLower: pending.hexLower,
          capturedAt: pending.capturedAt,
          lastRefreshedAt: lastRefreshedAt,
          protectedUntil: protectedUntil,
        );
        await _upsertOwnershipWithMetadata(
          userId: userId,
          hexLower: pending.hexLower,
          capturedAt: pending.capturedAt,
          lastRefreshedAt: lastRefreshedAt,
          protectedUntil: protectedUntil,
        );

        // Shared-world truth landed — only now finalize locally.
        capturedHexes.add(pending.hexLower);
        _capturedTilesByHex[pending.hexLower] = _buildOwnedTile(
          pending.hexLower,
          capturedAt: pending.capturedAt,
          lastRefreshedAt: lastRefreshedAt,
        );
        _nearbyTilesByHex.remove(pending.hexLower);
        nearbyOwnerByHex.remove(pending.hexLower);

        _pendingCaptures.remove(pending);
        confirmed++;
        debugPrint(
          '[Capture] ✅ pending capture confirmed for ${pending.hexLower}',
        );

        // Same notifications as a live capture (fire-and-forget).
        if (pending.previousNearbyOwner != null &&
            pending.previousNearbyOwner != userId) {
          NotificationService().notifyTileLost(
            previousOwnerId: pending.previousNearbyOwner!,
            h3Hex: pending.hexLower,
          );
        }
        NotificationService().scheduleVulnerableReminder(
          h3Hex: pending.hexLower,
          protectedUntil: protectedUntil,
        );
      } catch (e) {
        // Still offline or server rejected — leave in queue (if within
        // TTL it'll be retried next cycle).  Stop early to avoid
        // hammering the network during a bad patch.
        debugPrint(
          '[Capture] pending capture retry failed for ${pending.hexLower}: $e',
        );
        break;
      }
    }

    if (confirmed > 0) {
      await saveToPrefs();
    }
    return confirmed;
  }
}

/// In-memory record of a capture attempt whose shared-world sync failed.
/// Replayed by [CaptureService.flushPendingCaptures] on the next refresh.
class _PendingCapture {
  final String hexLower;
  final String userId;
  final DateTime capturedAt;
  final String? previousNearbyOwner;

  const _PendingCapture({
    required this.hexLower,
    required this.userId,
    required this.capturedAt,
    this.previousNearbyOwner,
  });
}

class CaptureTileResult {
  final GameTile tile;
  final bool synced;

  const CaptureTileResult({
    required this.tile,
    required this.synced,
  });
}
