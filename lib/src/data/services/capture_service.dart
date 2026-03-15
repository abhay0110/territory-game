import 'dart:convert';

import 'package:h3_flutter/h3_flutter.dart' as h3lib;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
  final Map<String, String> nearbyOwnerByHex = {};

  Future<void> loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKeyCaptured);
    if (raw == null || raw.trim().isEmpty) return;

    try {
      final List<dynamic> list = jsonDecode(raw) as List<dynamic>;
      capturedHexes.clear();
      for (final item in list) {
        if (item is String && item.isNotEmpty) {
          capturedHexes.add(item.toLowerCase());
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
        .select('h3_hex')
        .eq('user_id', userId)
        .eq('h3_res', h3Resolution) as List<dynamic>?;
    if (rows == null) return;

    bool changed = false;
    for (final r in rows) {
      if (r is Map && r['h3_hex'] is String) {
        final hex = (r['h3_hex'] as String).toLowerCase();
        if (capturedHexes.add(hex)) changed = true;
      }
    }

    if (changed) {
      await saveToPrefs();
    }
  }

  Future<void> upsertCapture(String userId, String hexLower) async {
    await supabaseClient.from('user_tile_captures').upsert(
      {
        'user_id': userId,
        'h3_res': h3Resolution,
        'h3_hex': hexLower,
      },
      onConflict: 'user_id,h3_res,h3_hex',
    );
  }

  Future<void> upsertOwnership(String userId, String hexLower) async {
    await supabaseClient.from('tile_captures').upsert(
      {
        'h3_res': h3Resolution,
        'h3_hex': hexLower,
        'owner_user_id': userId,
      },
      onConflict: 'h3_res,h3_hex',
    );
  }

  Future<void> refreshNearbyOwners(String userId, List<String> hexes) async {
    final rows = await supabaseClient
        .from('tile_captures')
        .select('h3_hex, owner_user_id')
        .eq('h3_res', h3Resolution)
        .inFilter('h3_hex', hexes) as List<dynamic>?;
    if (rows == null) return;

    nearbyOwnerByHex.clear();
    for (final r in rows) {
      if (r is Map && r['h3_hex'] is String && r['owner_user_id'] is String) {
        nearbyOwnerByHex[(r['h3_hex'] as String).toLowerCase()] =
            r['owner_user_id'] as String;
      }
    }
  }

  bool isCaptured(String hex) => capturedHexes.contains(hex);

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
          (hex) => GameTile(
            h3Index: hex,
            ownership: TileOwnership.mine,
          ),
        )
        .toList();
  }

  Future<List<GameTile>> getNearbyTiles() async {
    // Replace with real query
    return [];
  }
}
