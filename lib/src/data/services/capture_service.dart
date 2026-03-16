import 'dart:convert';

import 'package:h3_flutter/h3_flutter.dart' as h3lib;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
    _capturedTilesByHex.putIfAbsent(
      hexLower,
      () => _buildOwnedTile(
        hexLower,
        capturedAt: capturedAt,
        lastRefreshedAt: lastRefreshedAt,
      ),
    );
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
    List<dynamic>? rows;
    try {
      rows = await supabaseClient
          .from('user_tile_captures')
          .select('h3_hex, captured_at, last_refreshed_at')
          .eq('user_id', userId)
          .eq('h3_res', h3Resolution) as List<dynamic>?;
    } catch (_) {
      rows = await supabaseClient
          .from('user_tile_captures')
          .select('h3_hex')
          .eq('user_id', userId)
          .eq('h3_res', h3Resolution) as List<dynamic>?;
    }
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

  Future<void> upsertCapture(String userId, String hexLower) async {
    await _upsertCaptureWithMetadata(
      userId: userId,
      hexLower: hexLower,
      capturedAt: null,
      lastRefreshedAt: null,
      protectedUntil: null,
    );
  }

  Future<void> upsertOwnership(String userId, String hexLower) async {
    await _upsertOwnershipWithMetadata(
      userId: userId,
      hexLower: hexLower,
      capturedAt: null,
      lastRefreshedAt: null,
      protectedUntil: null,
    );
  }

  Future<void> _upsertCaptureWithMetadata({
    required String userId,
    required String hexLower,
    required DateTime? capturedAt,
    required DateTime? lastRefreshedAt,
    required DateTime? protectedUntil,
  }) async {
    final payloadWithMetadata = {
      'user_id': userId,
      'h3_res': h3Resolution,
      'h3_hex': hexLower,
      if (capturedAt != null) 'captured_at': capturedAt.toUtc().toIso8601String(),
      if (lastRefreshedAt != null)
        'last_refreshed_at': lastRefreshedAt.toUtc().toIso8601String(),
      if (protectedUntil != null)
        'protected_until': protectedUntil.toUtc().toIso8601String(),
    };

    try {
      await supabaseClient.from('user_tile_captures').upsert(
        payloadWithMetadata,
        onConflict: 'user_id,h3_res,h3_hex',
      );
    } catch (_) {
      await supabaseClient.from('user_tile_captures').upsert(
        {
          'user_id': userId,
          'h3_res': h3Resolution,
          'h3_hex': hexLower,
        },
        onConflict: 'user_id,h3_res,h3_hex',
      );
    }
  }

  Future<void> _upsertOwnershipWithMetadata({
    required String userId,
    required String hexLower,
    required DateTime? capturedAt,
    required DateTime? lastRefreshedAt,
    required DateTime? protectedUntil,
  }) async {
    final payloadWithMetadata = {
      'h3_res': h3Resolution,
      'h3_hex': hexLower,
      'owner_user_id': userId,
      if (capturedAt != null) 'captured_at': capturedAt.toUtc().toIso8601String(),
      if (lastRefreshedAt != null)
        'last_refreshed_at': lastRefreshedAt.toUtc().toIso8601String(),
      if (protectedUntil != null)
        'protected_until': protectedUntil.toUtc().toIso8601String(),
    };

    try {
      await supabaseClient.from('tile_captures').upsert(
        payloadWithMetadata,
        onConflict: 'h3_res,h3_hex',
      );
    } catch (_) {
      await supabaseClient.from('tile_captures').upsert(
        {
          'h3_res': h3Resolution,
          'h3_hex': hexLower,
          'owner_user_id': userId,
        },
        onConflict: 'h3_res,h3_hex',
      );
    }
  }

  Future<void> refreshNearbyOwners(List<String> hexes) async {
    List<dynamic>? rows;
    try {
      rows = await supabaseClient
          .from('tile_captures')
          .select('h3_hex, owner_user_id, captured_at, last_refreshed_at, protected_until')
          .eq('h3_res', h3Resolution)
          .inFilter('h3_hex', hexes) as List<dynamic>?;
    } catch (_) {
      rows = await supabaseClient
          .from('tile_captures')
          .select('h3_hex, owner_user_id')
          .eq('h3_res', h3Resolution)
          .inFilter('h3_hex', hexes) as List<dynamic>?;
    }
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

    capturedHexes.add(normalizedHex);
    _capturedTilesByHex[normalizedHex] = capturedTile;
    _nearbyTilesByHex.remove(normalizedHex);
    nearbyOwnerByHex.remove(normalizedHex);
    await saveToPrefs();

    var synced = false;
    final userId = currentUserId;
    if (userId != null) {
      try {
        await _upsertCaptureWithMetadata(
          userId: userId,
          hexLower: normalizedHex,
          capturedAt: capturedTile.capturedAt,
          lastRefreshedAt: capturedTile.lastRefreshedAt,
          protectedUntil: capturedTile.protectedUntil,
        );
        await _upsertOwnershipWithMetadata(
          userId: userId,
          hexLower: normalizedHex,
          capturedAt: capturedTile.capturedAt,
          lastRefreshedAt: capturedTile.lastRefreshedAt,
          protectedUntil: capturedTile.protectedUntil,
        );
        synced = true;
      } catch (_) {}
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
