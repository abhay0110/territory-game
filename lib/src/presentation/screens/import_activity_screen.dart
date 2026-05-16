// Activity import screen.  Build +26.
//
// Dogfood-only entry point — gated behind
// FeatureFlags.sweepImportEnabled && FeatureFlags.sweepImportGpxEnabled
// at the call site (currently the home-screen overflow icon).
//
// MVP UX for +26:
//   1. User pastes GPX XML into a TextField (avoids adding the
//      file_picker dependency for a dogfood-only flow; revisit for
//      +27 promotion).
//   2. Tap "Parse" → shows point count + date range + skipped counters.
//   3. Tap "Upload to sweep" → invokes the sweep edge function.
//   4. Result panel shows the audit response.
//
// Per docs/sweep_product_decisions.md, hex captures are NOT yet written
// by the server in +26 (correctness lands in +27).  The UI surfaces
// this honestly via the server's response message field.

import 'package:flutter/material.dart';

import '../../../core/theme/game_ui_tokens.dart';
import '../../data/services/sweep/gpx_parser.dart';
import '../../data/services/sweep/sweep_models.dart';
import '../../data/services/sweep/sweep_service.dart';

class ImportActivityScreen extends StatefulWidget {
  const ImportActivityScreen({super.key});

  @override
  State<ImportActivityScreen> createState() => _ImportActivityScreenState();
}

class _ImportActivityScreenState extends State<ImportActivityScreen> {
  final TextEditingController _xmlController = TextEditingController();
  GpxParseResult? _parsed;
  String? _parseError;
  bool _uploading = false;
  SweepResponse? _response;
  String? _uploadError;

  @override
  void dispose() {
    _xmlController.dispose();
    super.dispose();
  }

  void _parse() {
    setState(() {
      _parseError = null;
      _response = null;
      _uploadError = null;
      try {
        final text = _xmlController.text;
        if (text.trim().isEmpty) {
          _parseError = 'Paste GPX XML first.';
          _parsed = null;
          return;
        }
        _parsed = GpxParser.parse(text);
        if (_parsed!.points.isEmpty) {
          _parseError =
              'No valid trkpt elements found. (Sweep ignores wpt/rte; '
              'each trkpt must have lat, lon, and <time>.)';
        }
      } catch (e) {
        _parseError = 'Parse failed: $e';
        _parsed = null;
      }
    });
  }

  Future<void> _upload() async {
    final parsed = _parsed;
    if (parsed == null || parsed.points.isEmpty) return;
    setState(() {
      _uploading = true;
      _uploadError = null;
      _response = null;
    });
    try {
      final result = await SweepService().upload(
        source: SweepSource.gpx,
        points: parsed.points,
      );
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _response = result;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _uploadError = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GameUiTokens.bg0,
      appBar: AppBar(
        title: const Text('Import activity (GPX)'),
        backgroundColor: GameUiTokens.bg1,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Dogfood only. Paste GPX XML below.',
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 8),
            Expanded(
              flex: 3,
              child: TextField(
                controller: _xmlController,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: const TextStyle(
                  color: Colors.white,
                  fontFamily: 'monospace',
                  fontSize: 12,
                ),
                decoration: const InputDecoration(
                  filled: true,
                  fillColor: Colors.black26,
                  hintText: '<gpx>...</gpx>',
                  hintStyle: TextStyle(color: Colors.white38),
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonal(
                    onPressed: _uploading ? null : _parse,
                    child: const Text('Parse'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: (_uploading ||
                            _parsed == null ||
                            _parsed!.points.isEmpty)
                        ? null
                        : _upload,
                    child: _uploading
                        ? const SizedBox(
                            height: 16,
                            width: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Upload to sweep'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              flex: 2,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_parseError != null)
                      _StatusLine(text: _parseError!, tone: _Tone.error),
                    if (_parsed != null && _parseError == null)
                      _ParseSummary(result: _parsed!),
                    if (_uploadError != null) ...[
                      const SizedBox(height: 8),
                      _StatusLine(text: _uploadError!, tone: _Tone.error),
                    ],
                    if (_response != null) ...[
                      const SizedBox(height: 8),
                      _UploadSummary(response: _response!),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ParseSummary extends StatelessWidget {
  const _ParseSummary({required this.result});
  final GpxParseResult result;

  @override
  Widget build(BuildContext context) {
    final firstTs =
        result.points.isEmpty ? null : result.points.first.ts;
    final lastTs = result.points.isEmpty ? null : result.points.last.ts;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Parsed ${result.points.length} points',
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w600)),
          if (firstTs != null && lastTs != null)
            Text('From ${firstTs.toIso8601String()} to ${lastTs.toIso8601String()}',
                style: const TextStyle(color: Colors.white70, fontSize: 12)),
          if (result.skippedNoTime > 0)
            Text('Skipped (missing/bad time): ${result.skippedNoTime}',
                style: const TextStyle(color: Colors.orangeAccent, fontSize: 12)),
          if (result.skippedBadCoords > 0)
            Text('Skipped (bad coords): ${result.skippedBadCoords}',
                style: const TextStyle(color: Colors.orangeAccent, fontSize: 12)),
        ],
      ),
    );
  }
}

class _UploadSummary extends StatelessWidget {
  const _UploadSummary({required this.response});
  final SweepResponse response;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.green.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.greenAccent.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Upload ${response.status}',
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w600)),
          Text('Run id: ${response.importRunId}',
              style: const TextStyle(color: Colors.white70, fontSize: 11)),
          const SizedBox(height: 6),
          Text('Points in:               ${response.pointsIn}',
              style: const TextStyle(color: Colors.white)),
          Text('Shape-valid:             ${response.pointsAfterAccuracy}',
              style: const TextStyle(color: Colors.white)),
          Text('After pre-install gate:  ${response.pointsAfterWindow}',
              style: const TextStyle(color: Colors.white)),
          Text('Rejected (pre-install):  ${response.rejectedPreInstall}',
              style: const TextStyle(color: Colors.white)),
          Text('Hexes captured:          ${response.hexesCaptured}',
              style: const TextStyle(color: Colors.white)),
          const SizedBox(height: 8),
          Text(response.message,
              style: const TextStyle(
                  color: Colors.white70, fontStyle: FontStyle.italic, fontSize: 12)),
        ],
      ),
    );
  }
}

enum _Tone { error }

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.text, required this.tone});
  final String text;
  final _Tone tone;

  @override
  Widget build(BuildContext context) {
    final color = switch (tone) {
      _Tone.error => Colors.redAccent,
    };
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(text, style: TextStyle(color: color)),
    );
  }
}
