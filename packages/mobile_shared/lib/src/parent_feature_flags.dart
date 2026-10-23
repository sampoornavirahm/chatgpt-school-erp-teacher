class ParentFeatureFlags {
  const ParentFeatureFlags({
    this.courses = false,
    this.transport = false,
    this.ai = false,
  });

  final bool courses;
  final bool transport;
  final bool ai;

  factory ParentFeatureFlags.fromWire(Object? value) {
    if (value is! Map) return const ParentFeatureFlags();
    return ParentFeatureFlags(
      courses: value['courses'] == true,
      transport: value['transport'] == true,
      ai: value['ai'] == true,
    );
  }
}
