// Wire-format models for the sweep edge function.  Build +26.
//
// Mirrors the request/response shape declared in
// supabase/functions/sweep/index.ts.  Keep these two files in sync —
// any wire-shape change requires a coordinated client + server bump.

/// A single point of an activity track, normalised to UTC.
class SweepPoint {
  const SweepPoint({
    required this.ts,
    required this.lat,
    required this.lon,
    this.accuracyMeters,
  });

  final DateTime ts;
  final double lat;
  final double lon;
  final double? accuracyMeters;

  Map<String, dynamic> toJson() => {
        'ts': ts.toUtc().toIso8601String(),
        'lat': lat,
        'lon': lon,
        if (accuracyMeters != null) 'accuracy': accuracyMeters,
      };
}

/// Source kind for the [SweepRequest].  Must match the
/// VALID_SOURCES set in the edge function.
enum SweepSource {
  gpx,
  strava,
  healthkit,
  healthconnect,
  garmin;

  String get wire => switch (this) {
        SweepSource.gpx => 'gpx',
        SweepSource.strava => 'strava',
        SweepSource.healthkit => 'healthkit',
        SweepSource.healthconnect => 'healthconnect',
        SweepSource.garmin => 'garmin',
      };
}

class SweepRequest {
  const SweepRequest({required this.source, required this.points});

  final SweepSource source;
  final List<SweepPoint> points;

  Map<String, dynamic> toJson() => {
        'source': source.wire,
        'points': points.map((p) => p.toJson()).toList(growable: false),
      };
}

/// Echo of the audit row plus a human message.  See
/// supabase/functions/sweep/index.ts SweepResponse.
class SweepResponse {
  const SweepResponse({
    required this.importRunId,
    required this.source,
    required this.pointsIn,
    required this.pointsAfterAccuracy,
    required this.pointsAfterWindow,
    required this.hexesCaptured,
    required this.rejectedPreInstall,
    required this.status,
    required this.message,
  });

  final String importRunId;
  final String source;
  final int pointsIn;
  final int pointsAfterAccuracy;
  final int pointsAfterWindow;
  final int hexesCaptured;
  final int rejectedPreInstall;
  final String status; // 'success' | 'partial' | 'failed'
  final String message;

  factory SweepResponse.fromJson(Map<String, dynamic> json) {
    return SweepResponse(
      importRunId: json['import_run_id'] as String,
      source: json['source'] as String,
      pointsIn: (json['points_in'] as num).toInt(),
      pointsAfterAccuracy: (json['points_after_accuracy'] as num).toInt(),
      pointsAfterWindow: (json['points_after_window'] as num).toInt(),
      hexesCaptured: (json['hexes_captured'] as num).toInt(),
      rejectedPreInstall: (json['rejected_pre_install'] as num).toInt(),
      status: json['status'] as String,
      message: json['message'] as String? ?? '',
    );
  }
}
