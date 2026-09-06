import 'package:licoup/src/presentation/presentation_semantics.dart';

final class ManualTargetOptionProjection {
  const ManualTargetOptionProjection({
    required this.id,
    required this.label,
    this.supportsVirtualMachine = false,
  });

  final String id;
  final String label;
  final bool supportsVirtualMachine;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ManualTargetOptionProjection &&
          other.id == id &&
          other.label == label &&
          other.supportsVirtualMachine == supportsVirtualMachine;

  @override
  int get hashCode => Object.hash(id, label, supportsVirtualMachine);
}

final class TargetProjectionItem {
  const TargetProjectionItem({
    required this.id,
    required this.name,
    required this.typeLabel,
    required this.readinessLabel,
    required this.detail,
    required this.locationLabel,
    required this.configured,
    required this.pinned,
    required this.selected,
  });

  final String id;
  final String name;
  final String typeLabel;
  final String readinessLabel;
  final String detail;
  final String locationLabel;
  final bool configured;
  final bool pinned;
  final bool selected;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TargetProjectionItem &&
          other.id == id &&
          other.name == name &&
          other.typeLabel == typeLabel &&
          other.readinessLabel == readinessLabel &&
          other.detail == detail &&
          other.locationLabel == locationLabel &&
          other.configured == configured &&
          other.pinned == pinned &&
          other.selected == selected;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    typeLabel,
    readinessLabel,
    detail,
    locationLabel,
    configured,
    pinned,
    selected,
  );
}

final class TargetsProjection {
  TargetsProjection({
    required Iterable<TargetProjectionItem> targets,
    required this.phase,
    Iterable<ManualTargetOptionProjection> manualTargetOptions = const [],
    this.notice,
  }) : targets = immutablePresentationList(targets),
       manualTargetOptions = immutablePresentationList(manualTargetOptions);

  final List<TargetProjectionItem> targets;
  final List<ManualTargetOptionProjection> manualTargetOptions;
  final PresentationPhase phase;
  final PresentationNotice? notice;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TargetsProjection &&
          samePresentationList(other.targets, targets) &&
          samePresentationList(
            other.manualTargetOptions,
            manualTargetOptions,
          ) &&
          other.phase == phase &&
          other.notice == notice;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(targets),
    Object.hashAll(manualTargetOptions),
    phase,
    notice,
  );
}
