import '../../models/trail_progress.dart';
import '../../models/trail_section.dart';
import 'seattle_trails.dart';

class SeattleTrailSectionDefinitions {
  static final List<TrailSectionDefinition> sections = _buildSections();

  static List<TrailSectionDefinition> _buildSections() {
    final byId = <String, TrailDefinition>{
      for (final trail in SeattleTrailDefinitions.trails) trail.id: trail,
    };

    final out = <TrailSectionDefinition>[];

    void addThirds(
      String trailId,
      List<String> sectionNames,
    ) {
      final trail = byId[trailId];
      if (trail == null) return;

      final tiles = trail.orderedH3Indexes;
      if (tiles.isEmpty) return;

      final segmentCount = sectionNames.length;
      final base = tiles.length ~/ segmentCount;
      final remainder = tiles.length % segmentCount;

      var cursor = 0;
      for (var i = 0; i < segmentCount; i++) {
        final size = base + (i < remainder ? 1 : 0);
        final start = cursor;
        final endExclusive = (cursor + size).clamp(0, tiles.length);
        final end = endExclusive - 1;

        if (size > 0 && start <= end && end < tiles.length) {
          out.add(
            TrailSectionDefinition(
              id: '${trail.id}_section_${i + 1}',
              trailId: trail.id,
              trailName: trail.name,
              name: sectionNames[i],
              startIndex: start,
              endIndex: end,
              orderedH3Indexes: tiles.sublist(start, endExclusive),
            ),
          );
        }

        cursor = endExclusive;
      }
    }

    addThirds('burke_gilman', const [
      'Burke-Gilman West',
      'Burke-Gilman Central',
      'Burke-Gilman East',
    ]);

    addThirds('sammamish_river', const [
      'Sammamish North',
      'Sammamish Central',
      'Sammamish South',
    ]);

    return out;
  }
}
