// Sweep client service.  Build +26.
//
// Thin client over the `sweep` Supabase Edge Function.  Splits a long
// point stream into request-sized batches (MAX_POINTS_PER_BATCH below
// must match MAX_POINTS_PER_REQUEST in the edge function) and merges
// the per-batch audit responses into a single result for the UI.
//
// Authorization: relies on the caller having an active Supabase
// session.  The supabase_flutter SDK adds the bearer token to every
// `.functions.invoke` call automatically.

import 'package:supabase_flutter/supabase_flutter.dart';

import 'sweep_models.dart';

class SweepService {
  SweepService({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  // Must match supabase/functions/sweep/index.ts MAX_POINTS_PER_REQUEST.
  static const int maxPointsPerBatch = 100000;

  /// Uploads [points] to the sweep function in batches.  Returns the
  /// merged response across all batches.  Throws on the first batch
  /// failure (caller decides whether to retry).
  Future<SweepResponse> upload({
    required SweepSource source,
    required List<SweepPoint> points,
  }) async {
    if (points.isEmpty) {
      throw ArgumentError('SweepService.upload called with empty points');
    }

    // Single-batch fast path.
    if (points.length <= maxPointsPerBatch) {
      return _invokeBatch(source: source, points: points);
    }

    // Multi-batch: chunk and merge.  We keep the last import_run_id as
    // the response id (the UI surfaces that one; the audit table holds
    // a separate row per batch which operators can correlate by
    // user_id + close timestamps).
    final responses = <SweepResponse>[];
    for (var start = 0; start < points.length; start += maxPointsPerBatch) {
      final end = (start + maxPointsPerBatch < points.length)
          ? start + maxPointsPerBatch
          : points.length;
      final batch = points.sublist(start, end);
      responses.add(await _invokeBatch(source: source, points: batch));
    }
    return _merge(responses);
  }

  Future<SweepResponse> _invokeBatch({
    required SweepSource source,
    required List<SweepPoint> points,
  }) async {
    final request = SweepRequest(source: source, points: points);
    final result = await _client.functions.invoke(
      'sweep',
      body: request.toJson(),
    );

    final data = result.data;
    if (data is! Map<String, dynamic>) {
      throw StateError(
        'sweep returned unexpected payload shape: ${data.runtimeType}',
      );
    }
    if (data.containsKey('error')) {
      throw StateError('sweep error: ${data['error']}');
    }
    return SweepResponse.fromJson(data);
  }

  SweepResponse _merge(List<SweepResponse> responses) {
    var pointsIn = 0;
    var pointsAfterAccuracy = 0;
    var pointsAfterWindow = 0;
    var hexesCaptured = 0;
    var rejectedPreInstall = 0;
    var anyPartial = false;
    var anyFailed = false;
    for (final r in responses) {
      pointsIn += r.pointsIn;
      pointsAfterAccuracy += r.pointsAfterAccuracy;
      pointsAfterWindow += r.pointsAfterWindow;
      hexesCaptured += r.hexesCaptured;
      rejectedPreInstall += r.rejectedPreInstall;
      if (r.status == 'partial') anyPartial = true;
      if (r.status == 'failed') anyFailed = true;
    }
    final status = anyFailed ? 'failed' : (anyPartial ? 'partial' : 'success');
    return SweepResponse(
      importRunId: responses.last.importRunId,
      source: responses.last.source,
      pointsIn: pointsIn,
      pointsAfterAccuracy: pointsAfterAccuracy,
      pointsAfterWindow: pointsAfterWindow,
      hexesCaptured: hexesCaptured,
      rejectedPreInstall: rejectedPreInstall,
      status: status,
      message: responses.last.message,
    );
  }
}
