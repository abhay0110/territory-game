// GPX parser for the sweep upload path.  Build +26.
//
// We deliberately do NOT add the `xml` package as a dependency.  GPX
// is a fixed schema and we only need three fields per point
// (lat, lon, time), so a focused regex parser is simpler, faster,
// and one less surface to audit.
//
// Supported tags (everything else is ignored):
//   <trkpt lat="47.65" lon="-122.31">
//     <ele>10.5</ele>            (optional, ignored — sweep is 2D)
//     <time>2026-05-14T12:00:00Z</time>  (REQUIRED — points without
//                                         a time are rejected because
//                                         sweep needs first-rode-at)
//   </trkpt>
//
// We do NOT yet read `<wpt>` (waypoints) or `<rte>` (routes) — both
// would need different semantics (no time on `<wpt>`, ordered list for
// `<rte>`).  Sweep is for recorded TRACKS only.
//
// The parser is lenient on whitespace and tag ordering inside
// <trkpt>, strict on lat/lon attribute presence and time presence.

import '../sweep/sweep_models.dart';

class GpxParseResult {
  GpxParseResult({
    required this.points,
    required this.skippedNoTime,
    required this.skippedBadCoords,
  });

  final List<SweepPoint> points;
  final int skippedNoTime;
  final int skippedBadCoords;
}

class GpxParser {
  // Matches a full <trkpt ...>...</trkpt> block.  Captures the opening
  // tag attribute string and the inner body so we can pull lat/lon and
  // the nested <time>.
  static final RegExp _trkptRe = RegExp(
    r'<trkpt\b([^>]*)>(.*?)</trkpt>',
    multiLine: true,
    dotAll: true,
    caseSensitive: false,
  );

  static final RegExp _latRe = RegExp(
    r'''\blat\s*=\s*["']([^"']+)["']''',
    caseSensitive: false,
  );

  static final RegExp _lonRe = RegExp(
    r'''\blon\s*=\s*["']([^"']+)["']''',
    caseSensitive: false,
  );

  static final RegExp _timeRe = RegExp(
    r'<time\b[^>]*>\s*([^<]+?)\s*</time>',
    caseSensitive: false,
  );

  /// Parses the GPX XML text and returns the recovered points.
  /// Never throws on malformed input — bad points are skipped and
  /// counted so the caller can surface them to the user.
  static GpxParseResult parse(String xml) {
    final points = <SweepPoint>[];
    int skippedNoTime = 0;
    int skippedBadCoords = 0;

    for (final match in _trkptRe.allMatches(xml)) {
      final attrs = match.group(1) ?? '';
      final body = match.group(2) ?? '';

      final latStr = _latRe.firstMatch(attrs)?.group(1);
      final lonStr = _lonRe.firstMatch(attrs)?.group(1);
      final lat = latStr == null ? null : double.tryParse(latStr);
      final lon = lonStr == null ? null : double.tryParse(lonStr);

      if (lat == null ||
          lon == null ||
          lat < -90 ||
          lat > 90 ||
          lon < -180 ||
          lon > 180) {
        skippedBadCoords++;
        continue;
      }

      final timeStr = _timeRe.firstMatch(body)?.group(1);
      if (timeStr == null) {
        skippedNoTime++;
        continue;
      }
      final ts = DateTime.tryParse(timeStr);
      if (ts == null) {
        skippedNoTime++;
        continue;
      }

      points.add(SweepPoint(ts: ts.toUtc(), lat: lat, lon: lon));
    }

    return GpxParseResult(
      points: points,
      skippedNoTime: skippedNoTime,
      skippedBadCoords: skippedBadCoords,
    );
  }
}
