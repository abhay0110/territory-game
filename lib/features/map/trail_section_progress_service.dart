import 'package:h3_flutter/h3_flutter.dart' as h3lib;

import '../../core/constants/seattle_trail_sections.dart';
import '../../models/trail_progress.dart';
import '../../models/trail_section.dart';
import '../../src/data/services/map_render_service.dart';

class TrailSectionProgressService {
  final List<TrailSectionDefinition> sections;
  final h3lib.H3 _h3 = const h3lib.H3Factory().load();
  final Map<String, ({double lat, double lng})> _centroidCache = {};

  TrailSectionProgressService({
    List<TrailSectionDefinition>? sections,
  }) : sections = sections ?? SeattleTrailSectionDefinitions.sections;

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

  List<TrailSectionProgress> calculateProgress({
    required Iterable<String> capturedHexes,
    required Map<String, String> knownOwnerByHex,
    String? currentUserId,
    double? currentLat,
    double? currentLng,
  }) {
    final captured = capturedHexes.map((hex) => hex.toLowerCase()).toSet();
    final yourOwnerId = currentUserId ?? '__local_player__';

    return sections.map((section) {
      final ordered = section.orderedH3Indexes;
      final ownedFlags = ordered.map((hex) => captured.contains(hex)).toList();
      final ownedTiles = ownedFlags.where((b) => b).length;

      final ownerCounts = <String, int>{};
      for (final hex in ordered) {
        final owner = knownOwnerByHex[hex];
        if (owner == null || owner.isEmpty) continue;
        ownerCounts[owner] = (ownerCounts[owner] ?? 0) + 1;
      }

      final yourCount = ownerCounts[yourOwnerId] ?? ownedTiles;

      String? topRivalOwnerId;
      var topRivalCount = 0;
      ownerCounts.forEach((ownerId, count) {
        if (ownerId == yourOwnerId) return;
        if (count > topRivalCount) {
          topRivalCount = count;
          topRivalOwnerId = ownerId;
        }
      });

      var rivalTiles = 0;
      for (var i = 0; i < ordered.length; i++) {
        if (ownedFlags[i]) continue;
        final owner = knownOwnerByHex[ordered[i]];
        if (owner != null && owner.isNotEmpty && owner != yourOwnerId) {
          rivalTiles += 1;
        }
      }

      final controlState = switch ((yourCount, topRivalCount)) {
        (0, 0) => SectionControlState.unclaimed,
        _ when yourCount > topRivalCount => SectionControlState.you,
        _ when topRivalCount > yourCount => SectionControlState.rival,
        _ => SectionControlState.contested,
      };

      final leadingOwnerId = switch (controlState) {
        SectionControlState.you => yourOwnerId,
        SectionControlState.rival => topRivalOwnerId,
        _ => null,
      };

      final tilesToTakeControl =
          yourCount > topRivalCount ? 0 : (topRivalCount - yourCount + 1);
      final tilesToLoseControl =
          yourCount > topRivalCount ? (yourCount - topRivalCount) : 0;
      final isAtRisk =
          controlState == SectionControlState.you && (yourCount - topRivalCount) <= 1;
      final canFlipWithNextCapture =
          controlState == SectionControlState.contested ||
          tilesToTakeControl == 1 ||
          tilesToLoseControl == 1;

      final longestOwnedSegmentTiles = _longestOwnedSegment(ownedFlags);

      final segments = <({int start, int end})>[];
      int? segmentStart;
      for (var i = 0; i < ordered.length; i++) {
        if (ownedFlags[i]) {
          segmentStart ??= i;
        } else {
          if (segmentStart != null) {
            segments.add((start: segmentStart, end: i - 1));
            segmentStart = null;
          }
        }
      }
      if (segmentStart != null) {
        segments.add((start: segmentStart, end: ordered.length - 1));
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

      if (ownedTiles > 0 && segments.isNotEmpty) {
        final boundaryCandidates = <int>{};
        for (final seg in segments) {
          final left = seg.start - 1;
          if (left >= 0 && !ownedFlags[left]) boundaryCandidates.add(left);
          final right = seg.end + 1;
          if (right < ordered.length && !ownedFlags[right]) {
            boundaryCandidates.add(right);
          }
        }

        for (final idx in boundaryCandidates) {
          final hex = ordered[idx];
          final hasOwnedLeft = idx > 0 && ownedFlags[idx - 1];
          final hasOwnedRight = idx < ordered.length - 1 && ownedFlags[idx + 1];
          final reason = (hasOwnedLeft && hasOwnedRight)
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
          bestNextReason = ownedTiles == 0
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

      return TrailSectionProgress(
        section: section,
        ownedTiles: ownedTiles,
        rivalTiles: rivalTiles,
        leadingOwnerId: leadingOwnerId,
        tilesToTakeControl: tilesToTakeControl,
        tilesToLoseControl: tilesToLoseControl,
        isAtRisk: isAtRisk,
        canFlipWithNextCapture: canFlipWithNextCapture,
        longestOwnedSegmentTiles: longestOwnedSegmentTiles,
        projectedOwnedSegmentTiles: projectedOwnedSegmentTiles,
        projectedGainTiles: projectedGainTiles,
        controlState: controlState,
        bestNextTileH3: bestNextHex,
        bestNextTileDistanceMeters: bestNextMeters,
        bestNextTileReason: bestNextReason,
        nearestMissingTileHex: nearestHex,
        nearestMissingTileDistanceMeters: nearestMeters,
      );
    }).toList(growable: false);
  }
}
