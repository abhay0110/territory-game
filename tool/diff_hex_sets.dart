// Diff script: compare ValidTrailHexes._validIds built from the existing
// encoded-polyline waypoints vs. the same algorithm fed the high-fidelity
// OSM MultiLineString from assets/trails/burke_gilman.geojson.  Read-only:
// imports production constants, mutates nothing.  Phase 2 (1-ring corridor
// expansion) and Phase 2.5 (Kenmore correction) are reproduced verbatim
// so the diff isolates *only* the impact of changing the Phase-1 source.
//
// Requires `libh3` available to dlsym.  On macOS:
//   brew install h3
// We dlopen() it at the top of main() so the symbols are available to
// production's `DynamicLibrary.process()` lookup.
//
// Usage:
//   dart run tool/diff_hex_sets.dart
//   dart run tool/diff_hex_sets.dart --verbose
//   dart run tool/diff_hex_sets.dart --libh3 /custom/path/libh3.dylib

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:h3_flutter/h3_flutter.dart' as h3lib;

import 'package:HexTrail/core/constants/launch_corridor.dart';
import 'package:HexTrail/core/constants/seattle_trails.dart';
import 'package:HexTrail/core/constants/valid_trail_hexes.dart';

const int _h3Resolution = 9;
const int _samplesPerSegment = 40;

const double _kenmoreLatMin = 47.7100;
const double _kenmoreLatMax = 47.7700;
const double _kenmoreLngMin = -122.2700;
const double _kenmoreLngMax = -122.2300;
const double _kenmoreBufferMeters = 350;

// Tighter Phase 2 gate (diff harness only — not in production).
const double _phase2MaxDistMeters = 180.0;
const double _phase25MaxDistMeters = 350.0;

late final h3lib.H3 _h3;

Future<void> main(List<String> args) async {
  // ── Pre-load libh3 so production singletons can resolve symbols ──
  String libPath = '/opt/homebrew/lib/libh3.dylib';
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '--libh3') libPath = args[i + 1];
  }
  if (Platform.isMacOS) {
    if (!File(libPath).existsSync()) {
      stderr.writeln(
        'libh3 dylib not found at $libPath.\n'
        'Install with: brew install h3   (or pass --libh3 <path>)',
      );
      exit(2);
    }
    DynamicLibrary.open(libPath); // RTLD_GLOBAL on macOS by default.
  } else if (Platform.isLinux) {
    DynamicLibrary.open('libh3.so');
  }
  _h3 = const h3lib.H3Factory().load();

  final verbose = args.contains('--verbose') || args.contains('-v');
  final buf = StringBuffer();

  final oldWaypoints = SeattleTrailDefinitions.burkeGilmanWaypoints
      .map((p) => (lat: p.lat, lng: p.lng))
      .toList(growable: false);
  buf.writeln('OLD source: encoded polyline, ${oldWaypoints.length} pts');

  final newSegments = _loadOsmSegments('assets/trails/burke_gilman.geojson');
  final newTotal = newSegments.fold<int>(0, (s, seg) => s + seg.length);
  buf.writeln(
    'NEW source: OSM GeoJSON, ${newSegments.length} segments, $newTotal pts',
  );
  buf.writeln('');

  LaunchCorridor.ensureInitialized();
  ValidTrailHexes.ensureInitialized();
  final corridor = LaunchCorridor.hexes;
  final liveValid = ValidTrailHexes.validHexIds;
  buf.writeln('Corridor (LaunchCorridor.hexes): ${corridor.length}');
  buf.writeln('Live ValidTrailHexes.validHexIds: ${liveValid.length}');
  buf.writeln('');

  final oldRes = _buildValidIds([oldWaypoints], corridor);
  // NEW: tighter Phase 2 — perpendicular distance to OSM polyline +
  // water-zone gate, instead of corridor-membership gate.
  final newRes = _buildValidIdsTight(newSegments);

  final reproVsLive = _diff(liveValid, oldRes.validIds);
  if (reproVsLive.added.isNotEmpty || reproVsLive.removed.isNotEmpty) {
    buf.writeln(
      'WARN: reimplementation drifted from live ValidTrailHexes '
      '(+${reproVsLive.added.length} / -${reproVsLive.removed.length})',
    );
  } else {
    buf.writeln('OK reimplementation matches live ValidTrailHexes exactly.');
  }
  buf.writeln('');

  buf.writeln('======== HEX SET COUNTS ========');
  _row(buf, 'Phase 1 (polyline core)', oldRes.phase1Count, newRes.phase1Count);
  _row(buf, 'Phase 2 (1-ring, gated)',     oldRes.phase2Adds,  newRes.phase2Adds);
  _row(buf, 'Phase 2.5 (Kenmore, gated)',  oldRes.phase25Adds, newRes.phase25Adds);
  _row(buf, 'TOTAL valid', oldRes.validIds.length, newRes.validIds.length);
  _row(buf, 'Core only', oldRes.coreIds.length, newRes.coreIds.length);
  buf.writeln('');

  final dValid = _diff(oldRes.validIds, newRes.validIds);
  final dCore = _diff(oldRes.coreIds, newRes.coreIds);

  buf.writeln('======== DIFF: validHexIds ========');
  buf.writeln('  added:   ${dValid.added.length}');
  buf.writeln('  removed: ${dValid.removed.length}');
  buf.writeln('  shared:  ${dValid.shared}');
  buf.writeln('');
  buf.writeln('======== DIFF: coreHexIds ========');
  buf.writeln('  added:   ${dCore.added.length}');
  buf.writeln('  removed: ${dCore.removed.length}');
  buf.writeln('  shared:  ${dCore.shared}');
  buf.writeln('');

  final sectionFor = _sectionLookup();
  final addedBySection = <String, List<String>>{};
  final removedBySection = <String, List<String>>{};
  for (final h in dValid.added) {
    addedBySection.putIfAbsent(sectionFor(h), () => []).add(h);
  }
  for (final h in dValid.removed) {
    removedBySection.putIfAbsent(sectionFor(h), () => []).add(h);
  }
  buf.writeln('======== BY TRAIL SECTION (validHexIds) ========');
  final allSections = <String>{
    ...addedBySection.keys,
    ...removedBySection.keys,
    'Burke-Gilman West',
    'Burke-Gilman Central',
    'Burke-Gilman East',
    'Off-corridor',
  };
  for (final sec in allSections) {
    final adds = addedBySection[sec]?.length ?? 0;
    final rems = removedBySection[sec]?.length ?? 0;
    if (adds == 0 && rems == 0) continue;
    buf.writeln('  $sec: +$adds / -$rems');
  }
  buf.writeln('');

  final waterRisk = <String>[];
  for (final h in dValid.added) {
    final c = _hexCentroid(h);
    if (c == null) continue;
    if (LaunchCorridor.isInWaterZone(c.lat, c.lng)) waterRisk.add(h);
  }
  String phaseOf(String h) {
    if (newRes.coreIds.contains(h)) return 'Phase1-core';
    if (newRes.phase2Ids.contains(h)) return 'Phase2';
    if (newRes.phase25Ids.contains(h)) return 'Phase2.5';
    return '?';
  }
  buf.writeln('======== WATER-ZONE RISK ========');
  if (waterRisk.isEmpty) {
    buf.writeln('  OK no newly-added hex falls inside a known water zone.');
  } else {
    final coreCount = waterRisk.where((h) => newRes.coreIds.contains(h)).length;
    final expandCount = waterRisk.length - coreCount;
    buf.writeln(
      '  ${waterRisk.length} newly-added hex(es) inside known water zone:',
    );
    buf.writeln(
      '    - $coreCount are Phase 1 core (sampled directly from OSM polyline; '
      "LaunchCorridor's water bbox overlaps the trail itself here).",
    );
    buf.writeln(
      '    - $expandCount are expansion (Phase 2 / 2.5).  '
      'These would be a real regression and should be 0.',
    );
    for (final h in waterRisk) {
      final c = _hexCentroid(h)!;
      buf.writeln(
        '    $h  (${c.lat.toStringAsFixed(5)}, '
        '${c.lng.toStringAsFixed(5)})  '
        'phase=${phaseOf(h)}  section=${sectionFor(h)}',
      );
    }
  }
  buf.writeln('');

  // ── Live-set audit: every existing validHexId measured against OSM ──
  buf.writeln('======== LIVE validHexIds AUDIT vs OSM polyline ========');
  final liveAudit = <({String hex, double lat, double lng, double dist})>[];
  for (final h in liveValid) {
    final c = _hexCentroid(h);
    if (c == null) continue;
    final d = _minDistToPolylineMeters(c.lat, c.lng, newSegments);
    liveAudit.add((hex: h, lat: c.lat, lng: c.lng, dist: d));
  }
  liveAudit.sort((a, b) => b.dist.compareTo(a.dist));
  final overThreshold = liveAudit.where((e) => e.dist > 180).toList();
  buf.writeln(
    '  Live valid hexes >180m from OSM polyline: ${overThreshold.length} '
    'of ${liveAudit.length}',
  );
  buf.writeln('  Top 15 farthest from OSM polyline:');
  for (final e in liveAudit.take(15)) {
    buf.writeln(
      '    ${e.hex}  '
      '(${e.lat.toStringAsFixed(5)}, ${e.lng.toStringAsFixed(5)})  '
      'd=${e.dist.toStringAsFixed(0)}m',
    );
  }
  buf.writeln('');

  // ── Focused audits ──
  // Kenmore → Bothell stretch: lat 47.745–47.760, lng -122.295 to -122.20
  // Show every live valid hex sorted west→east with side-of-trail info so
  // we can identify the off-trail south-of-polyline cluster (the "1-9"
  // markers in the user's annotated screenshot).
  buf.writeln('  Kenmore→Bothell live hexes (west→east), side vs OSM trail:');
  final kbLive = liveAudit
      .where((e) =>
          e.lat >= 47.745 &&
          e.lat <= 47.762 &&
          e.lng >= -122.295 &&
          e.lng <= -122.195)
      .toList()
    ..sort((a, b) => a.lng.compareTo(b.lng));
  for (final e in kbLive) {
    final near = _nearestPolylinePoint(e.lat, e.lng, newSegments);
    final side = e.lat < near.lat ? 'S' : 'N';
    buf.writeln(
      '    [$side] ${e.hex}  '
      '(${e.lat.toStringAsFixed(5)}, ${e.lng.toStringAsFixed(5)})  '
      'd=${e.dist.toStringAsFixed(0)}m  '
      'trail@(${near.lat.toStringAsFixed(5)}, ${near.lng.toStringAsFixed(5)})',
    );
  }
  buf.writeln('');

  // Candidates NORTH of polyline in the same stretch that are NOT yet
  // valid but lie within 200m of the trail (would be added by a tighter
  // Phase 2 / 2.5).  These are what the user is asking to add "north of
  // hex 7".
  buf.writeln('  Candidate NORTH-side additions (not currently valid, ≤200m):');
  final candidates = newRes.validIds
      .difference(liveValid)
      .map((h) {
        final c = _hexCentroid(h);
        if (c == null) return null;
        return (hex: h, lat: c.lat, lng: c.lng);
      })
      .whereType<({String hex, double lat, double lng})>()
      .where((e) =>
          e.lat >= 47.745 &&
          e.lat <= 47.770 &&
          e.lng >= -122.295 &&
          e.lng <= -122.195)
      .toList();
  for (final e in candidates) {
    final near = _nearestPolylinePoint(e.lat, e.lng, newSegments);
    final side = e.lat < near.lat ? 'S' : 'N';
    final d = _minDistToPolylineMeters(e.lat, e.lng, newSegments);
    buf.writeln(
      '    [$side] ${e.hex}  '
      '(${e.lat.toStringAsFixed(5)}, ${e.lng.toStringAsFixed(5)})  '
      'd=${d.toStringAsFixed(0)}m',
    );
  }
  buf.writeln('');

  // Ballard / west end: lng < -122.38.
  buf.writeln('  Ballard / west end (lng < -122.38), worst 10:');
  final ballard = liveAudit.where((e) => e.lng < -122.38).toList()
    ..sort((a, b) => b.dist.compareTo(a.dist));
  for (final e in ballard.take(10)) {
    buf.writeln(
      '    ${e.hex}  '
      '(${e.lat.toStringAsFixed(5)}, ${e.lng.toStringAsFixed(5)})  '
      'd=${e.dist.toStringAsFixed(0)}m',
    );
  }
  buf.writeln('');

  if (verbose) {
    buf.writeln('======== ADDED HEXES (full list) ========');
    for (final sec in allSections) {
      final list = addedBySection[sec] ?? const [];
      if (list.isEmpty) continue;
      buf.writeln('  $sec (${list.length}):');
      for (final h in list) {
        final c = _hexCentroid(h);
        final d = c == null
            ? double.nan
            : _minDistToPolylineMeters(c.lat, c.lng, newSegments);
        buf.writeln(
          '    $h  '
          '(${c?.lat.toStringAsFixed(5)}, ${c?.lng.toStringAsFixed(5)})  '
          'd=${d.toStringAsFixed(0)}m',
        );
      }
    }
    buf.writeln('');
    buf.writeln('======== REMOVED HEXES (full list) ========');
    for (final sec in allSections) {
      final list = removedBySection[sec] ?? const [];
      if (list.isEmpty) continue;
      buf.writeln('  $sec (${list.length}):');
      for (final h in list) {
        final c = _hexCentroid(h);
        final d = c == null
            ? double.nan
            : _minDistToPolylineMeters(c.lat, c.lng, newSegments);
        buf.writeln(
          '    $h  '
          '(${c?.lat.toStringAsFixed(5)}, ${c?.lng.toStringAsFixed(5)})  '
          'd=${d.toStringAsFixed(0)}m',
        );
      }
    }
    buf.writeln('');
  }

  final netChange = newRes.validIds.length - oldRes.validIds.length;
  buf.writeln('======== VERDICT ========');
  buf.writeln(
    '  Net validHexIds change: ${netChange >= 0 ? '+' : ''}$netChange '
    '(${(netChange / oldRes.validIds.length * 100).toStringAsFixed(1)}%)',
  );
  buf.writeln('  Added (would suddenly become valid): ${dValid.added.length}');
  buf.writeln('  Removed (would suddenly disappear):  ${dValid.removed.length}');
  buf.writeln('  Water-zone false positives in added: ${waterRisk.length}');
  buf.writeln('');
  buf.writeln('  Re-run with --verbose to dump every changed hex.');

  stdout.write(buf.toString());
}

class _BuildResult {
  final Set<String> validIds;
  final Set<String> coreIds;
  final Set<String> phase2Ids;
  final Set<String> phase25Ids;
  final int phase1Count;
  final int phase2Adds;
  final int phase25Adds;
  _BuildResult(
    this.validIds,
    this.coreIds,
    this.phase2Ids,
    this.phase25Ids,
    this.phase1Count,
    this.phase2Adds,
    this.phase25Adds,
  );
}

_BuildResult _buildValidIds(
  List<List<({double lat, double lng})>> segments,
  Set<String> corridorSet,
) {
  // Mirror production's _blacklist via the public API so the sanity check
  // (reimplementation == live ValidTrailHexes) stays exact.
  bool isBl(String h) => ValidTrailHexes.isBlacklisted(h);
  final validIds = <String>{};
  final coreIds = <String>{};
  final phase2Ids = <String>{};
  final phase25Ids = <String>{};

  for (final seg in segments) {
    if (seg.length < 2) continue;
    for (var i = 0; i < seg.length - 1; i++) {
      final a = seg[i];
      final b = seg[i + 1];
      for (var s = 0; s <= _samplesPerSegment; s++) {
        final t = s / _samplesPerSegment;
        final lat = a.lat + (b.lat - a.lat) * t;
        final lng = a.lng + (b.lng - a.lng) * t;
        final cell = _h3.geoToCell(
          h3lib.GeoCoord(lat: lat, lon: lng),
          _h3Resolution,
        );
        final hex = cell.toRadixString(16).toLowerCase();
        if (isBl(hex)) continue;
        coreIds.add(hex);
      }
    }
  }
  final phase1Count = coreIds.length;
  validIds.addAll(coreIds);

  final beforePhase2 = validIds.length;
  for (final coreHex in coreIds) {
    final cell = BigInt.parse(coreHex, radix: 16);
    final ring = _h3.gridDisk(cell, 1);
    for (final neighbor in ring) {
      final nHex = neighbor.toRadixString(16).toLowerCase();
      if (validIds.contains(nHex)) continue;
      if (isBl(nHex)) continue;
      if (!corridorSet.contains(nHex)) continue;
      validIds.add(nHex);
      phase2Ids.add(nHex);
    }
  }
  final phase2Adds = validIds.length - beforePhase2;

  final beforePhase25 = validIds.length;
  final waypointPool = <({double lat, double lng})>[];
  for (final seg in segments) {
    waypointPool.addAll(seg);
  }
  for (final coreHex in coreIds) {
    final coreCell = BigInt.parse(coreHex, radix: 16);
    final coreBnd = _h3.cellToBoundary(coreCell);
    if (coreBnd.isEmpty) continue;
    final coreLat = coreBnd.fold(0.0, (s, p) => s + p.lat) / coreBnd.length;
    final coreLng = coreBnd.fold(0.0, (s, p) => s + p.lon) / coreBnd.length;
    if (coreLat < _kenmoreLatMin ||
        coreLat > _kenmoreLatMax ||
        coreLng < _kenmoreLngMin ||
        coreLng > _kenmoreLngMax) {
      continue;
    }
    final ring = _h3.gridDisk(coreCell, 1);
    for (final neighbor in ring) {
      final nHex = neighbor.toRadixString(16).toLowerCase();
      if (validIds.contains(nHex)) continue;
      final nBnd = _h3.cellToBoundary(neighbor);
      if (nBnd.isEmpty) continue;
      final nLat = nBnd.fold(0.0, (s, p) => s + p.lat) / nBnd.length;
      final nLng = nBnd.fold(0.0, (s, p) => s + p.lon) / nBnd.length;
      var nearTrail = false;
      for (final wp in waypointPool) {
        if (_haversineMeters(nLat, nLng, wp.lat, wp.lng) <=
            _kenmoreBufferMeters) {
          nearTrail = true;
          break;
        }
      }
      if (!nearTrail) continue;
      if (isBl(nHex)) continue;
      validIds.add(nHex);
      phase25Ids.add(nHex);
    }
  }
  final phase25Adds = validIds.length - beforePhase25;

  // Phase 3 mirror — manual whitelist.  Hardcoded here to match production
  // (kept in sync with ValidTrailHexes._whitelistCore).
  const whitelist = {'8928d54e22fffff'};
  for (final hex in whitelist) {
    if (isBl(hex)) continue;
    coreIds.add(hex);
    validIds.add(hex);
  }

  return _BuildResult(
    validIds,
    coreIds,
    phase2Ids,
    phase25Ids,
    phase1Count,
    phase2Adds,
    phase25Adds,
  );
}

// ─── Tighter builder (diff harness only) ─────────────────────────────────
//
// Phase 1: identical to production — dense sampling per segment.
// Phase 2: REPLACES corridor-membership gate with two stricter gates:
//          (a) perpendicular distance from neighbor centroid to the
//              nearest OSM polyline SEGMENT must be ≤ _phase2MaxDistMeters
//          (b) neighbor centroid must NOT be inside any LaunchCorridor
//              water zone
// Phase 2.5: Kenmore expansion uses the same perpendicular-distance gate
//          (≤ _phase25MaxDistMeters) instead of nearest-waypoint, plus
//          the same water-zone exclusion.  Bounding box for "Kenmore"
//          and the 1-ring source set is unchanged.
//
// Distance source is always the OSM polyline segments passed in; we never
// fall back to encoded waypoints.

_BuildResult _buildValidIdsTight(
  List<List<({double lat, double lng})>> segments,
) {
  final validIds = <String>{};
  final coreIds = <String>{};
  final phase2Ids = <String>{};
  final phase25Ids = <String>{};

  // Phase 1 — unchanged from production.
  for (final seg in segments) {
    if (seg.length < 2) continue;
    for (var i = 0; i < seg.length - 1; i++) {
      final a = seg[i];
      final b = seg[i + 1];
      for (var s = 0; s <= _samplesPerSegment; s++) {
        final t = s / _samplesPerSegment;
        final lat = a.lat + (b.lat - a.lat) * t;
        final lng = a.lng + (b.lng - a.lng) * t;
        final cell = _h3.geoToCell(
          h3lib.GeoCoord(lat: lat, lon: lng),
          _h3Resolution,
        );
        coreIds.add(cell.toRadixString(16).toLowerCase());
      }
    }
  }
  final phase1Count = coreIds.length;
  validIds.addAll(coreIds);

  // Phase 2 — perpendicular distance + water-zone gate.
  final beforePhase2 = validIds.length;
  for (final coreHex in coreIds) {
    final cell = BigInt.parse(coreHex, radix: 16);
    final ring = _h3.gridDisk(cell, 1);
    for (final neighbor in ring) {
      final nHex = neighbor.toRadixString(16).toLowerCase();
      if (validIds.contains(nHex)) continue;
      final c = _hexCentroid(nHex);
      if (c == null) continue;
      if (LaunchCorridor.isInWaterZone(c.lat, c.lng)) continue;
      final d = _minDistToPolylineMeters(c.lat, c.lng, segments);
      if (d > _phase2MaxDistMeters) continue;
      validIds.add(nHex);
      phase2Ids.add(nHex);
    }
  }
  final phase2Adds = validIds.length - beforePhase2;

  // Phase 2.5 — Kenmore correction with perpendicular-distance + water gate.
  final beforePhase25 = validIds.length;
  for (final coreHex in coreIds) {
    final coreC = _hexCentroid(coreHex);
    if (coreC == null) continue;
    if (coreC.lat < _kenmoreLatMin ||
        coreC.lat > _kenmoreLatMax ||
        coreC.lng < _kenmoreLngMin ||
        coreC.lng > _kenmoreLngMax) {
      continue;
    }
    final coreCell = BigInt.parse(coreHex, radix: 16);
    final ring = _h3.gridDisk(coreCell, 1);
    for (final neighbor in ring) {
      final nHex = neighbor.toRadixString(16).toLowerCase();
      if (validIds.contains(nHex)) continue;
      final nC = _hexCentroid(nHex);
      if (nC == null) continue;
      if (LaunchCorridor.isInWaterZone(nC.lat, nC.lng)) continue;
      final d = _minDistToPolylineMeters(nC.lat, nC.lng, segments);
      if (d > _phase25MaxDistMeters) continue;
      validIds.add(nHex);
      phase25Ids.add(nHex);
    }
  }
  final phase25Adds = validIds.length - beforePhase25;

  return _BuildResult(
    validIds,
    coreIds,
    phase2Ids,
    phase25Ids,
    phase1Count,
    phase2Adds,
    phase25Adds,
  );
}

// Minimum perpendicular distance from (lat,lng) to any segment in the
// MultiLineString.  Uses local equirectangular projection — accurate to
// well under a meter at Burke-Gilman latitudes for the small distances
// we care about.
double _minDistToPolylineMeters(
  double lat,
  double lng,
  List<List<({double lat, double lng})>> segments,
) {
  const double mPerDegLat = 111320.0;
  final mPerDegLng = mPerDegLat * math.cos(lat * math.pi / 180.0);
  final px = lng * mPerDegLng;
  final py = lat * mPerDegLat;
  double best = double.infinity;
  for (final seg in segments) {
    for (var i = 0; i < seg.length - 1; i++) {
      final a = seg[i];
      final b = seg[i + 1];
      final ax = a.lng * mPerDegLng;
      final ay = a.lat * mPerDegLat;
      final bx = b.lng * mPerDegLng;
      final by = b.lat * mPerDegLat;
      final dx = bx - ax;
      final dy = by - ay;
      final len2 = dx * dx + dy * dy;
      double t;
      if (len2 == 0) {
        t = 0;
      } else {
        t = ((px - ax) * dx + (py - ay) * dy) / len2;
        if (t < 0) t = 0;
        if (t > 1) t = 1;
      }
      final cx = ax + t * dx;
      final cy = ay + t * dy;
      final ex = px - cx;
      final ey = py - cy;
      final d2 = ex * ex + ey * ey;
      if (d2 < best) best = d2;
    }
  }
  return math.sqrt(best);
}

// Returns the closest point on any segment of `segments` to (lat,lng).
({double lat, double lng}) _nearestPolylinePoint(
  double lat,
  double lng,
  List<List<({double lat, double lng})>> segments,
) {
  const double mPerDegLat = 111320.0;
  final mPerDegLng = mPerDegLat * math.cos(lat * math.pi / 180.0);
  final px = lng * mPerDegLng;
  final py = lat * mPerDegLat;
  double best = double.infinity;
  double bestX = px;
  double bestY = py;
  for (final seg in segments) {
    for (var i = 0; i < seg.length - 1; i++) {
      final a = seg[i];
      final b = seg[i + 1];
      final ax = a.lng * mPerDegLng;
      final ay = a.lat * mPerDegLat;
      final bx = b.lng * mPerDegLng;
      final by = b.lat * mPerDegLat;
      final dx = bx - ax;
      final dy = by - ay;
      final len2 = dx * dx + dy * dy;
      double t;
      if (len2 == 0) {
        t = 0;
      } else {
        t = ((px - ax) * dx + (py - ay) * dy) / len2;
        if (t < 0) t = 0;
        if (t > 1) t = 1;
      }
      final cx = ax + t * dx;
      final cy = ay + t * dy;
      final ex = px - cx;
      final ey = py - cy;
      final d2 = ex * ex + ey * ey;
      if (d2 < best) {
        best = d2;
        bestX = cx;
        bestY = cy;
      }
    }
  }
  return (lat: bestY / mPerDegLat, lng: bestX / mPerDegLng);
}

List<List<({double lat, double lng})>> _loadOsmSegments(String assetPath) {
  final file = File(assetPath);
  if (!file.existsSync()) {
    stderr.writeln('Missing asset: $assetPath');
    exit(2);
  }
  final raw = file.readAsStringSync();
  final decoded = jsonDecode(raw) as Map;
  final geometry = decoded['geometry'] as Map;
  final type = geometry['type'];
  final rawCoords = geometry['coordinates'] as List;

  List<List<dynamic>> rawSegments;
  if (type == 'LineString') {
    rawSegments = [rawCoords];
  } else if (type == 'MultiLineString') {
    rawSegments = rawCoords.cast<List<dynamic>>();
  } else {
    throw StateError('Unsupported geometry type: $type');
  }

  final out = <List<({double lat, double lng})>>[];
  for (final seg in rawSegments) {
    final pts = <({double lat, double lng})>[];
    for (final pair in seg) {
      if (pair is! List || pair.length < 2) continue;
      final lng = (pair[0] as num).toDouble();
      final lat = (pair[1] as num).toDouble();
      pts.add((lat: lat, lng: lng));
    }
    if (pts.length >= 2) out.add(pts);
  }
  return out;
}

class _DiffResult {
  final List<String> added;
  final List<String> removed;
  final int shared;
  _DiffResult(this.added, this.removed, this.shared);
}

_DiffResult _diff(Set<String> oldSet, Set<String> newSet) {
  final added = newSet.difference(oldSet).toList()..sort();
  final removed = oldSet.difference(newSet).toList()..sort();
  final shared = oldSet.intersection(newSet).length;
  return _DiffResult(added, removed, shared);
}

String Function(String hex) _sectionLookup() {
  final waypoints = SeattleTrailDefinitions.burkeGilmanWaypoints;
  final lngs = waypoints.map((p) => p.lng).toList()..sort();
  final lo = lngs.first;
  final hi = lngs.last;
  final third = (hi - lo) / 3.0;
  final westMax = lo + third;
  final centralMax = lo + 2 * third;
  return (String hex) {
    final c = _hexCentroid(hex);
    if (c == null) return 'Off-corridor';
    if (c.lng <= westMax) return 'Burke-Gilman West';
    if (c.lng <= centralMax) return 'Burke-Gilman Central';
    return 'Burke-Gilman East';
  };
}

({double lat, double lng})? _hexCentroid(String hexLower) {
  try {
    final cell = BigInt.parse(hexLower, radix: 16);
    final boundary = _h3.cellToBoundary(cell);
    if (boundary.isEmpty) return null;
    final lat = boundary.fold(0.0, (s, p) => s + p.lat) / boundary.length;
    final lng = boundary.fold(0.0, (s, p) => s + p.lon) / boundary.length;
    return (lat: lat, lng: lng);
  } catch (_) {
    return null;
  }
}

void _row(StringBuffer buf, String label, int oldVal, int newVal) {
  final delta = newVal - oldVal;
  final sign = delta > 0 ? '+' : (delta < 0 ? '' : ' ');
  buf.writeln(
    '  ${label.padRight(32)} '
    '${oldVal.toString().padLeft(5)}  ->  '
    '${newVal.toString().padLeft(5)}  '
    '($sign$delta)',
  );
}

double _haversineMeters(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371000.0;
  final dLat = (lat2 - lat1) * math.pi / 180.0;
  final dLng = (lng2 - lng1) * math.pi / 180.0;
  final a =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180.0) *
          math.cos(lat2 * math.pi / 180.0) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}
