/// Represents the current objective/guidance for the player in Guided mode.
class ObjectiveState {
  /// Main objective line/title
  final String title;

  /// Optional secondary line with additional context
  final String? detail;

  /// Optional CTA button label (e.g., "Capture", "Start Session")
  final String? actionLabel;

  const ObjectiveState({
    required this.title,
    this.detail,
    this.actionLabel,
  });

  @override
  String toString() => 'ObjectiveState(title: $title, detail: $detail, actionLabel: $actionLabel)';
}
