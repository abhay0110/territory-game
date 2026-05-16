// Unit tests for GpxParser.  Build +26.
//
// Pure parser, no I/O — exhaustive coverage of the supported GPX
// subset and known-bad inputs.

import 'package:flutter_test/flutter_test.dart';
import 'package:HexTrail/src/data/services/sweep/gpx_parser.dart';

void main() {
  group('GpxParser.parse', () {
    test('parses a minimal well-formed track', () {
      const xml = '''
<?xml version="1.0"?>
<gpx version="1.1">
  <trk><trkseg>
    <trkpt lat="47.6500" lon="-122.3100">
      <time>2026-05-14T12:00:00Z</time>
    </trkpt>
    <trkpt lat="47.6510" lon="-122.3110">
      <ele>10.5</ele>
      <time>2026-05-14T12:00:15Z</time>
    </trkpt>
  </trkseg></trk>
</gpx>
''';
      final result = GpxParser.parse(xml);
      expect(result.points, hasLength(2));
      expect(result.skippedNoTime, 0);
      expect(result.skippedBadCoords, 0);

      expect(result.points[0].lat, closeTo(47.65, 1e-9));
      expect(result.points[0].lon, closeTo(-122.31, 1e-9));
      expect(result.points[0].ts.toUtc().toIso8601String(),
          '2026-05-14T12:00:00.000Z');

      expect(result.points[1].lat, closeTo(47.651, 1e-9));
    });

    test('skips trkpt with no <time> tag', () {
      const xml = '''
<gpx>
  <trk><trkseg>
    <trkpt lat="47.65" lon="-122.31"></trkpt>
    <trkpt lat="47.66" lon="-122.32">
      <time>2026-05-14T12:00:00Z</time>
    </trkpt>
  </trkseg></trk>
</gpx>
''';
      final result = GpxParser.parse(xml);
      expect(result.points, hasLength(1));
      expect(result.skippedNoTime, 1);
      expect(result.skippedBadCoords, 0);
      expect(result.points.single.lat, closeTo(47.66, 1e-9));
    });

    test('skips trkpt with unparseable time string', () {
      const xml = '''
<gpx><trk><trkseg>
  <trkpt lat="47.65" lon="-122.31">
    <time>not-a-date</time>
  </trkpt>
</trkseg></trk></gpx>
''';
      final result = GpxParser.parse(xml);
      expect(result.points, isEmpty);
      expect(result.skippedNoTime, 1);
    });

    test('skips trkpt with missing or out-of-range coords', () {
      const xml = '''
<gpx><trk><trkseg>
  <trkpt lat="120.0" lon="-122.0"><time>2026-05-14T12:00:00Z</time></trkpt>
  <trkpt lat="47.65" lon="200.0"><time>2026-05-14T12:00:01Z</time></trkpt>
  <trkpt lat="47.65"><time>2026-05-14T12:00:02Z</time></trkpt>
  <trkpt lat="abc" lon="-122.0"><time>2026-05-14T12:00:03Z</time></trkpt>
</trkseg></trk></gpx>
''';
      final result = GpxParser.parse(xml);
      expect(result.points, isEmpty);
      expect(result.skippedBadCoords, 4);
    });

    test('normalises non-UTC timestamps to UTC', () {
      const xml = '''
<gpx><trk><trkseg>
  <trkpt lat="47.65" lon="-122.31">
    <time>2026-05-14T05:00:00-07:00</time>
  </trkpt>
</trkseg></trk></gpx>
''';
      final result = GpxParser.parse(xml);
      expect(result.points, hasLength(1));
      expect(result.points.single.ts.isUtc, isTrue);
      expect(result.points.single.ts.toIso8601String(),
          '2026-05-14T12:00:00.000Z');
    });

    test('tolerates extra whitespace and attribute ordering', () {
      const xml = '''
<gpx><trk><trkseg>
  <trkpt   lon="-122.31"   lat="47.65"  >
    <time>  2026-05-14T12:00:00Z  </time>
  </trkpt>
</trkseg></trk></gpx>
''';
      final result = GpxParser.parse(xml);
      expect(result.points, hasLength(1));
      expect(result.points.single.lat, closeTo(47.65, 1e-9));
      expect(result.points.single.lon, closeTo(-122.31, 1e-9));
    });

    test('returns empty result on input with no trkpt elements', () {
      const xml = '<gpx><metadata><name>empty</name></metadata></gpx>';
      final result = GpxParser.parse(xml);
      expect(result.points, isEmpty);
      expect(result.skippedNoTime, 0);
      expect(result.skippedBadCoords, 0);
    });

    test('ignores wpt and rte elements (only trkpt is supported)', () {
      const xml = '''
<gpx>
  <wpt lat="47.65" lon="-122.31"><name>start</name></wpt>
  <rte><rtept lat="47.66" lon="-122.32"></rtept></rte>
  <trk><trkseg>
    <trkpt lat="47.65" lon="-122.31">
      <time>2026-05-14T12:00:00Z</time>
    </trkpt>
  </trkseg></trk>
</gpx>
''';
      final result = GpxParser.parse(xml);
      expect(result.points, hasLength(1));
    });

    test('handles a longer realistic-shape track', () {
      final buf = StringBuffer('<gpx><trk><trkseg>');
      for (var i = 0; i < 50; i++) {
        final ts =
            DateTime.utc(2026, 5, 14, 12, 0, i).toIso8601String();
        buf.write(
          '<trkpt lat="${47.65 + i * 0.0001}" lon="${-122.31 - i * 0.0001}">'
          '<time>$ts</time>'
          '</trkpt>',
        );
      }
      buf.write('</trkseg></trk></gpx>');

      final result = GpxParser.parse(buf.toString());
      expect(result.points, hasLength(50));
      expect(result.skippedNoTime, 0);
      expect(result.skippedBadCoords, 0);
    });
  });
}
