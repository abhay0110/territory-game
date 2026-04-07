import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:h3_flutter/h3_flutter.dart' as h3lib;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/notification_service.dart';
import '../../../core/constants/game_rules.dart';
import '../../../models/game_tile.dart';

/// Handles capture persistence and Supabase sync for H3 tile captures.
class CaptureService {
  CaptureService({
    required this.supabaseClient,
    required this.h3Resolution,
  }) : _h3 = const h3lib.H3Factory().load();

  final SupabaseClient supabaseClient;
  final int h3Resolution;
  final h3lib.H3 _h3;

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
    );
  }

  void _ensureCapturedTileRecord(
    String hexLower, {
    DateTime? capturedAt,
    DateTime? lastRefreshedAt,
  }) {
    // Always overwrite when real timestamps are provided so Supabase data
    // replaces the DateTime.now() defaults created during loadFromPrefs.
    if (capturedAt != null || lastRefreshedAt != null) {
      _capturedTilesByHex[hexLower] = _buildOwnedTile(
        hexLower,
        capturedAt: capturedAt,
        lastRefreshedAt: lastRefreshedAt,
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
        .select('h3_hex, captured_at, last_refreshed_at')
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
}

class CaptureTileResult {
  final GameTile tile;
  final bool synced;

  const CaptureTileResult({
    required this.tile,
    required this.synced,
  });
}
