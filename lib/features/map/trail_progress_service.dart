import 'package:h3_flutter/h3_flutter.dart' as h3lib;

import '../../core/constants/seattle_trails.dart';
import '../../models/trail_progress.dart';
import '../../src/data/services/map_render_service.dart';

class TrailProgressService {
  final List<TrailDefinition> trails;
  final h3lib.H3 _h3 = const h3lib.H3Factory().load();
  final Map<String, ({double lat, double lng})> _centroidCache = {};

  TrailProgressService({
    List<TrailDefinition>? trails,
  }) : trails = trails ?? SeattleTrailDefinitions.trails;

  ({double lat, double lng})? _cellCentroid(String hexLower) {
    final cached = _centroidCache[hexLower];
    if (cached != null) return cached;

    try {
      final cell = BigInt.parse(hexLower, radix: 16);
      final boundary = _h3.cellToBoundary(cell);
      if (boundary.isEmpty) return null;

      double latSum = 0;
      double lngSum = 0;
      for (final p in boundary) {
        latSum += p.lat;
        lngSum += p.lon;
      }

      final centroid = (
        lat: latSum / boundary.length,
        lng: lngSum / boundary.length,
      );
      _centroidCache[hexLower] = centroid;
      return centroid;
    } catch (_) {
      return null;
    }
  }

  int _longestOwnedSegment(List<bool> ownedFlags) {
    var longest = 0;
    var running = 0;
    for (final isOwned in ownedFlags) {
      if (isOwned) {
        running += 1;
        if (running > longest) longest = running;
      } else {
        running = 0;
      }
    }
    return longest;
  }

  List<TrailProgress> calculateProgress(
    Iterable<String> capturedHexes, {
    double? currentLat,
    double? currentLng,
  }) {
    final captured = capturedHexes.map((hex) => hex.toLowerCase()).toSet();

    return trails.map((trail) {
      final ordered = trail.orderedH3Indexes;
      final ownedFlags = ordered.map((hex) => captured.contains(hex)).toList();
      final owned = ownedFlags.where((isOwned) => isOwned).length;
      final longestOwnedSegmentTiles = _longestOwnedSegment(ownedFlags);
      final segments = <({int start, int end})>[];
      int? currentSegmentStart;

      for (var i = 0; i < ordered.length; i++) {
        if (ownedFlags[i]) {
          currentSegmentStart ??= i;
        } else {
          if (currentSegmentStart != null) {
            segments.add((start: currentSegmentStart, end: i - 1));
            currentSegmentStart = null;
          }
        }
      }
      if (currentSegmentStart != null) {
        segments.add((start: currentSegmentStart, end: ordered.length - 1));
      }

      String? nearestHex;
      double? nearestMeters;
      String? bestNextHex;
      double? bestNextMeters;
      TrailNextTileReason? bestNextReason;

      for (var i = 0; i < ordered.length; i++) {
        if (ownedFlags[i]) continue;
        final hex = ordered[i];

        double? meters;
        if (currentLat != null && currentLng != null) {
          final centroid = _cellCentroid(hex);
          if (centroid != null) {
            meters = MapRenderService.haversineMeters(
              currentLat,
              currentLng,
              centroid.lat,
              centroid.lng,
            );
          }
        }

        final isCloserNearest = nearestHex == null ||
            ((meters ?? double.infinity) < (nearestMeters ?? double.infinity));
        if (isCloserNearest) {
          nearestHex = hex;
          nearestMeters = meters;
        }
      }

      if (owned > 0 && !segments.isEmpty) {
        final boundaryCandidates = <int>{};
        for (final seg in segments) {
          final left = seg.start - 1;
          if (left >= 0 && !ownedFlags[left]) {
            boundaryCandidates.add(left);
          }

          final right = seg.end + 1;
          if (right < ordered.length && !ownedFlags[right]) {
            boundaryCandidates.add(right);
          }
        }

        for (final idx in boundaryCandidates) {
          final hex = ordered[idx];
          final hasOwnedLeft = idx > 0 && ownedFlags[idx - 1];
          final hasOwnedRight = idx < ordered.length - 1 && ownedFlags[idx + 1];

          final reason =
              (hasOwnedLeft && hasOwnedRight)
                  ? TrailNextTileReason.bridgeGap
                  : TrailNextTileReason.extendStreak;

          double? meters;
          if (currentLat != null && currentLng != null) {
            final centroid = _cellCentroid(hex);
            if (centroid != null) {
              meters = MapRenderService.haversineMeters(
                currentLat,
                currentLng,
                centroid.lat,
                centroid.lng,
              );
            }
          }

          final isBetter = bestNextHex == null ||
              ((meters ?? double.infinity) < (bestNextMeters ?? double.infinity));
          if (isBetter) {
            bestNextHex = hex;
            bestNextMeters = meters;
            bestNextReason = reason;
          }
        }
      }

      if (bestNextHex == null) {
        bestNextHex = nearestHex;
        bestNextMeters = nearestMeters;
        if (nearestHex != null) {
          bestNextReason =
              owned == 0
                  ? TrailNextTileReason.startTrail
                  : TrailNextTileReason.nearestMissing;
        }
      }

      var projectedOwnedSegmentTiles = longestOwnedSegmentTiles;
      var projectedGainTiles = 0;
      if (bestNextHex != null) {
        final idx = ordered.indexOf(bestNextHex);
        if (idx >= 0 && !ownedFlags[idx]) {
          final simulatedOwned = List<bool>.from(ownedFlags);
          simulatedOwned[idx] = true;
          projectedOwnedSegmentTiles = _longestOwnedSegment(simulatedOwned);
          projectedGainTiles = projectedOwnedSegmentTiles - longestOwnedSegmentTiles;
          if (projectedGainTiles < 0) projectedGainTiles = 0;
        }
      }

      return TrailProgress(
        trail: trail,
        ownedTiles: owned,
        longestOwnedSegmentTiles: longestOwnedSegmentTiles,
        projectedOwnedSegmentTiles: projectedOwnedSegmentTiles,
        projectedGainTiles: projectedGainTiles,
        bestNextTileH3: bestNextHex,
        bestNextTileDistanceMeters: bestNextMeters,
        bestNextTileReason: bestNextReason,
        nearestMissingTileHex: nearestHex,
        nearestMissingTileDistanceMeters: nearestMeters,
      );
    }).toList(growable: false);
  }
}
