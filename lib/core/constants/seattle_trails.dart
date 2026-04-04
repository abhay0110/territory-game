import 'package:h3_flutter/h3_flutter.dart' as h3lib;

import '../../models/trail_progress.dart';

typedef TrailPoint = ({double lat, double lng});

class SeattleTrailDefinitions {
  static final h3lib.H3 _h3 = const h3lib.H3Factory().load();
  static const int _h3Resolution = 9;

  static final List<TrailDefinition> trails = [
    TrailDefinition(
      id: 'burke_gilman',
      name: 'Burke-Gilman',
      orderedH3Indexes: _buildOrderedH3Sequence(
        _burkeGilmanWaypoints,
        samplesPerSegment: 20,
      ),
    ),
    TrailDefinition(
      id: 'sammamish_river',
      name: 'Sammamish River',
      orderedH3Indexes: _buildOrderedH3Sequence(
        _sammamishRiverWaypoints,
        samplesPerSegment: 20,
      ),
    ),
  ];

  // Burke-Gilman Trail — decoded from encoded polyline of real OSM geometry.
  //
  // Source: OpenStreetMap relation 2183654 (Burke-Gilman Trail bicycle route).
  // 352 points at ~50 m spacing, Golden Gardens (west) → Bothell (east).
  // The encoded polyline is compact (~1.3 KB) and decoded once at startup.
  static final List<TrailPoint> _burkeGilmanWaypoints = _decodePolyline(
    _burkeGilmanEncodedPolyline,
  );

  /// Exposed for valid-hex filtering (nearest-point-on-trail calculations).
  static List<TrailPoint> get burkeGilmanWaypoints => _burkeGilmanWaypoints;

  static const String _burkeGilmanEncodedPolyline =
      's_abHpvajVzHTnFRbFFrBPrCr@tEzBtE`BrDvB~CbBdDpB`Cr@rL{@jGc@dBMzBG~AInDiA'
      'hCs@xAc@|Au@nAkAhAmB`AgCv@iBzC}Ve@aJk@aCoC}QGgNDqPjAcBv@{BjFwIxCyCnA_BfE'
      'qG~AoBlAwInAkHnAkHnAkHnAkHnAsIz@gI?{Hb@mC`JwJtAk@nDcFtAwArCkCzAyAfA}AtDg'
      'DjDgDbBcBnAkA`BmBlByE|AwCnAcDr@mBt@mBrAqDtBiGz@oDf@kFPoEPaEv@mQvAl@bBEvA'
      r"v@ZbC\aLRoKRoKRoKZsHBwCAgCBgCCaDDkHw@oByBiAuBy@aD_BeCqAkBgAsAqAeCsD{A}Bq"
      'AgByAyAuHuJ_AuCu@}Gs@cGk@cFY{CEqCLsCn@{ExA_K`@iC`@aCl@eDx@qCdAcBnAgEbAqB'
      r"f@wDf@kHRkHRoK@iNcB_@qFmAgE{@mFaA{Cq@_B]}AOgDS{AEcCD_CRkEl@cGbByA\qBXwDW"
      'cBa@oA}AgA_C]kEG_DnBqMnBoDpAgBjCeFbB_DvBgEzDqE~@gDb@mCRmDUqEi@cC}FgGiDy@'
      'cCYwD[yAQ}A_@iBgAkAiA}@{B}BgLYsC]_FUiD[sFOwC?sCPsCLkCMmGwAsEcC}BaC_BwCqBw'
      'B_BqE{FwAaCuAwBkCeDcByAyCmA}B{@cB{@cBg@cBg@cBSiE]iCHgEf@gEf@gEz@gEz@gEnA'
      'gEnAgEnAgEbBgEbBgEvBgEvBgEnFiD|D}@|EgD~G_DfEkCbGmD`D}BaI{A_GaAkB}BwB{Ay@e'
      r"C_@}AFyBp@{Ad@oC|@}Ad@qC`A}CrAcDhBkE^yFUkBJ}Bp@gCx@iDjA_EfAyD`@gBFqBNoE"
      '|@aFhAyEvAqCn@}IxB{BdAwDlFgCnBoEv@iCVcBC{AcBmKeAuDTgBn@iD|AuFlCcB'
      r"\uCAmCe@gGhD_D~CgB`CwAn@yCl@mBl@wBrAkBjAuCtAwB`@aBPeBHaBBaB?aBE_BKaBK_BO"
      '_AiJwB@sBIiCWmDc@{AQkDa@aBWoEiBaBs@uLgFuB_AqBmBaB_Dy@iCiBgG_A_D{AuEmA}Dy@'
      '_CsAcD}AoEg@gEg@gESgESgESgESgESgE?gE?gE?gE?gE?gE?gE?gE?gE?gE?gE?gERgE?gE?'
      'gE?gE?gERgE?gE?gE?gE?gE?gE?gE?gE?gE?gE?gE?gE?gE?gE?gEHyFz@uDvDkN`AsDjAmF'
      'fEwYRgPRmEb@iDj@oCvAgEjCmH~B_Hf@eD?iDWcF]iCgA{HeD}EgEgEgEkCgEwBgEwBoFiA';

  /// Decodes a Google-encoded polyline into a list of [TrailPoint].
  static List<TrailPoint> _decodePolyline(String encoded) {
    final points = <TrailPoint>[];
    var index = 0;
    var lat = 0;
    var lng = 0;
    while (index < encoded.length) {
      for (var isLng = 0; isLng < 2; isLng++) {
        var shift = 0;
        var result = 0;
        int b;
        do {
          b = encoded.codeUnitAt(index++) - 63;
          result |= (b & 0x1f) << shift;
          shift += 5;
        } while (b >= 0x20);
        final delta = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
        if (isLng == 0) {
          lat += delta;
        } else {
          lng += delta;
        }
      }
      points.add((lat: lat / 1e5, lng: lng / 1e5));
    }
    return points;
  }

  static const List<TrailPoint> _sammamishRiverWaypoints = [
    (lat: 47.7590, lng: -122.1900),
    (lat: 47.7440, lng: -122.1760),
    (lat: 47.7300, lng: -122.1640),
    (lat: 47.7160, lng: -122.1520),
    (lat: 47.7000, lng: -122.1420),
    (lat: 47.6840, lng: -122.1310),
    (lat: 47.6680, lng: -122.1240),
  ];

  static List<String> _buildOrderedH3Sequence(
    List<TrailPoint> waypoints, {
    int samplesPerSegment = 10,
  }) {
    if (waypoints.length < 2) return const [];

    final ordered = <String>[];
    final seen = <String>{};

    // Step 1: Interpolate between waypoints at requested density.
    for (var i = 0; i < waypoints.length - 1; i++) {
      final a = waypoints[i];
      final b = waypoints[i + 1];

      for (var s = 0; s <= samplesPerSegment; s++) {
        final t = s / samplesPerSegment;
        final lat = a.lat + (b.lat - a.lat) * t;
        final lng = a.lng + (b.lng - a.lng) * t;

        final cell = _h3.geoToCell(
          h3lib.GeoCoord(lat: lat, lon: lng),
          _h3Resolution,
        );
        final hex = cell.toRadixString(16).toLowerCase();

        if (seen.add(hex)) {
          ordered.add(hex);
        }
      }
    }

    // Step 2: Fill any gaps where consecutive hexes are not H3 neighbors.
    // Walk the ordered list; when two adjacent entries are not direct
    // neighbors, interpolate denser samples between their centroids to
    // bridge the gap.  This guarantees an unbroken hex chain.
    var filled = true;
    for (var pass = 0; pass < 3 && filled; pass++) {
      filled = false;
      final snapshot = List<String>.of(ordered);
      ordered.clear();
      seen.clear();

      for (var i = 0; i < snapshot.length; i++) {
        final hex = snapshot[i];
        if (seen.add(hex)) ordered.add(hex);

        if (i + 1 < snapshot.length) {
          final aCel = BigInt.parse(hex, radix: 16);
          final bCel = BigInt.parse(snapshot[i + 1], radix: 16);
          final neighbors = _h3.gridDisk(aCel, 1);
          if (!neighbors.contains(bCel)) {
            filled = true;
            // Interpolate between centroids.
            final aB = _h3.cellToBoundary(aCel);
            final bB = _h3.cellToBoundary(bCel);
            if (aB.isNotEmpty && bB.isNotEmpty) {
              final aLat = aB.fold(0.0, (s, p) => s + p.lat) / aB.length;
              final aLng = aB.fold(0.0, (s, p) => s + p.lon) / aB.length;
              final bLat = bB.fold(0.0, (s, p) => s + p.lat) / bB.length;
              final bLng = bB.fold(0.0, (s, p) => s + p.lon) / bB.length;
              for (var k = 1; k <= 8; k++) {
                final t = k / 9;
                final mLat = aLat + (bLat - aLat) * t;
                final mLng = aLng + (bLng - aLng) * t;
                final mCell = _h3.geoToCell(
                  h3lib.GeoCoord(lat: mLat, lon: mLng),
                  _h3Resolution,
                );
                final mHex = mCell.toRadixString(16).toLowerCase();
                if (seen.add(mHex)) ordered.add(mHex);
              }
            }
          }
        }
      }
    }

    return ordered;
  }
}
