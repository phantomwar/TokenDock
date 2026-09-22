class Quota {
  const Quota({
    required this.id,
    required this.label,
    required this.percent,
    required this.remaining,
    required this.limit,
    required this.unit,
    required this.resetAt,
  });

  final String id;
  final String label;
  final double? percent;
  final double? remaining;
  final double? limit;
  final String? unit;
  final DateTime? resetAt;
}
