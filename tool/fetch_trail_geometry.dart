// Dev-time script: fetch a high-fidelity trail geometry from OpenStreetMap
// via the Overpass API and write a single GeoJSON LineString to
// assets/trails/<slug>.geojson.
//
// Usage:
//   dart run tool/fetch_trail_geometry.dart                  # default: Burke-Gilman
//   dart run tool/fetch_trail_geometry.dart burke_gilman
//   dart run tool/fetch_trail_geometry.dart sammamish_river
//
// IMPORTANT: This output is for the visual polyline overlay only. It must
// NOT be used to derive ValidTrailHexes, LaunchCorridor, capture eligibility,
// section ordering, or leaderboard. Those continue to flow from
// SeattleTrailDefinitions._burkeGilmanWaypoints.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

class TrailSpec {
  final String slug;
  final int relationId;
  final String displayName;
  const TrailSpec(this.slug, this.relationId, this.displayName);
}

const Map<String, TrailSpec> kTrails = {
  'burke_gilman': TrailSpec('burke_gilman', 2183654, 'Burke-Gilman Trail'),
  'sammamish_river': TrailSpec(
    'sammamish_river',
    16038700,
    'Sammamish River Trail',
  ),
};

const String _overpassUrl = 'https://overpass-api.de/api/interpreter';

Future<void> main(List<String> args) async {
  final slug = args.isEmpty ? 'burke_gilman' : args.first;
  final spec = kTrails[slug];
  if (spec == null) {
    stderr.writeln('Unknown trail slug: $slug');
    stderr.writeln('Known: ${kTrails.keys.join(", ")}');
    exit(2);
  }

  stdout.writeln('Fetching ${spec.displayName} (relation ${spec.relationId})…');
  final json = await _fetchOverpass(spec.relationId);
  final ways = _extractWays(json);
  stdout.writeln('Got ${ways.length} member ways.');

  final segments = _stitchWays(ways);
  final totalPts = segments.fold<int>(0, (s, seg) => s + seg.length);
  stdout.writeln(
    'Built ${segments.length} segment(s), $totalPts vertices total.',
  );

  final geojson = _toGeoJsonMultiLineString(segments, spec);
  final outPath = 'assets/trails/${spec.slug}.geojson';
  final outFile = File(outPath);
  await outFile.parent.create(recursive: true);
  await outFile.writeAsString('${jsonEncode(geojson)}\n');

  final kb = (await outFile.length()) / 1024.0;
  stdout.writeln(
    'Wrote $outPath (${kb.toStringAsFixed(1)} KB, $totalPts pts in '
    '${segments.length} segment(s)).',
  );
}

Future<Map<String, dynamic>> _fetchOverpass(int relationId) async {
  // Pull the relation, recurse to its member ways and their nodes, and
  // include lat/lon geometry inline on each way.
  final query =
      '[out:json][timeout:60];relation($relationId);(._;>;);out body geom;';

  final client = HttpClient();
  try {
    final req = await client.postUrl(Uri.parse(_overpassUrl));
    req.headers.contentType = ContentType(
      'application',
      'x-www-form-urlencoded',
    );
    req.headers.set('User-Agent', 'HexTrail-dev-script/0.1');
    req.write('data=${Uri.encodeQueryComponent(query)}');
    final resp = await req.close();
    if (resp.statusCode != 200) {
      final body = await resp.transform(utf8.decoder).join();
      throw StateError('Overpass HTTP ${resp.statusCode}: $body');
    }
    final body = await resp.transform(utf8.decoder).join();
    return jsonDecode(body) as Map<String, dynamic>;
  } finally {
    client.close(force: true);
  }
}

class _Way {
  final int id;
  final List<List<double>> coords; // [[lat, lon], ...]
  _Way(this.id, this.coords);
}

List<_Way> _extractWays(Map<String, dynamic> overpassJson) {
  final elements = (overpassJson['elements'] as List).cast<Map>();
  final relation = elements.firstWhere(
    (e) => e['type'] == 'relation',
    orElse: () => throw StateError('No relation in Overpass response'),
  );
  final memberOrder = <int>[];
  for (final m in (relation['members'] as List).cast<Map>()) {
    if (m['type'] == 'way') {
      memberOrder.add(m['ref'] as int);
    }
  }

  final waysById = <int, _Way>{};
  for (final e in elements) {
    if (e['type'] != 'way') continue;
    final id = e['id'] as int;
    final geom = e['geometry'];
    if (geom is! List) continue;
    final coords = <List<double>>[];
    for (final p in geom) {
      final lat = (p['lat'] as num).toDouble();
      final lon = (p['lon'] as num).toDouble();
      coords.add([lat, lon]);
    }
    if (coords.length >= 2) {
      waysById[id] = _Way(id, coords);
    }
  }

  return [
    for (final id in memberOrder)
      if (waysById.containsKey(id)) waysById[id]!,
  ];
}

/// Stitches member ways into one or more polyline segments.
///
/// We walk ways in the relation's nominal member order, flipping each so its
/// first vertex is the endpoint closest to the running tail.  When the join
/// distance exceeds [_maxGapMeters] we *do not* draw a chord across the gap;
/// instead we close the current segment and start a new one.  This keeps
/// every vertex from OSM (no orphan loss) while ensuring the rendered trail
/// never cuts a long straight line over water or open ground.
const double _joinSnapMeters = 1.0;
const double _maxGapMeters = 75.0;
const int _minSegmentVertices = 2;

List<List<List<double>>> _stitchWays(List<_Way> ways) {
  if (ways.isEmpty) return const [];
  final segments = <List<List<double>>>[];
  var current = <List<double>>[...ways.first.coords];
  var breaks = 0;

  for (var i = 1; i < ways.length; i++) {
    final next = ways[i].coords;
    final tail = current.last;
    final dStart = _haversineMeters(tail, next.first);
    final dEnd = _haversineMeters(tail, next.last);
    final useReversed = dEnd < dStart;
    final seq = useReversed ? next.reversed.toList() : next;
    final gap = _haversineMeters(tail, seq.first);

    if (gap <= _joinSnapMeters) {
      current.addAll(seq.skip(1));
    } else if (gap <= _maxGapMeters) {
      current.addAll(seq);
    } else {
      // Too far — close the current segment and start fresh.
      if (current.length >= _minSegmentVertices) segments.add(current);
      current = [...seq];
      breaks++;
    }
  }
  if (current.length >= _minSegmentVertices) segments.add(current);

  if (breaks > 0) {
    stdout.writeln('Broke into ${segments.length} segments at $breaks gap(s).');
  }
  return segments;
}

double _haversineMeters(List<double> a, List<double> b) {
  const r = 6371000.0;
  final lat1 = a[0] * math.pi / 180.0;
  final lat2 = b[0] * math.pi / 180.0;
  final dLat = (b[0] - a[0]) * math.pi / 180.0;
  final dLon = (b[1] - a[1]) * math.pi / 180.0;
  final s1 = math.sin(dLat / 2);
  final s2 = math.sin(dLon / 2);
  final h = s1 * s1 + math.cos(lat1) * math.cos(lat2) * s2 * s2;
  return 2 * r * math.asin(math.min(1.0, math.sqrt(h)));
}

Map<String, dynamic> _toGeoJsonMultiLineString(
  List<List<List<double>>> segments,
  TrailSpec spec,
) {
  // GeoJSON uses [lon, lat] order.
  final coords = segments
      .map((seg) => seg.map((p) => [p[1], p[0]]).toList(growable: false))
      .toList(growable: false);
  return {
    'type': 'Feature',
    'properties': {
      'name': spec.displayName,
      'osm_relation': spec.relationId,
      'source': 'OpenStreetMap (ODbL)',
      'fetched_at': DateTime.now().toUtc().toIso8601String(),
    },
    'geometry': {'type': 'MultiLineString', 'coordinates': coords},
  };
}
