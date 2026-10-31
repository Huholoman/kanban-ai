import 'workflow.dart';

/// A version of the workflow configuration: equal revisions mean equal
/// content. Opaque to callers; only compare it.
final class WorkflowRevision {
  const WorkflowRevision(this.value);

  final String value;

  @override
  bool operator ==(Object other) => other is WorkflowRevision && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// The workflow and the revision of the configuration it was read from.
final class LoadedWorkflow {
  const LoadedWorkflow(this.workflow, this.revision);

  final Workflow workflow;
  final WorkflowRevision revision;
}

/// One change of the configuration: sets the value at [path] (mapping keys
/// as strings, list positions as ints; missing mappings on the way are
/// created) or removes it.
final class WorkflowEdit {
  /// Sets [path] to [value] (strings, numbers, booleans, lists and maps).
  const WorkflowEdit.set(this.path, Object this.value);

  /// Removes [path]; nothing happens when it is not there.
  const WorkflowEdit.remove(this.path) : value = null;

  final List<Object> path;

  /// The new value; null removes [path].
  final Object? value;
}

/// Where the workflow configuration of a backlog is kept (a port; the
/// `backlog.yaml` adapter is in infrastructure).
abstract interface class WorkflowSource {
  /// Where the configuration lives, for messages.
  String get location;

  /// The current revision, null when there is no configuration. Cheap enough
  /// to ask before every use, to see whether a loaded workflow is stale.
  Future<WorkflowRevision?> revision();

  /// The workflow. Throws [NotFoundException] when there is no
  /// configuration and [ConfigurationException] when it is malformed.
  Future<LoadedWorkflow> load();

  /// Applies [edits] in order and returns the new revision; everything else
  /// (comments, key order, unknown keys) is kept. Nothing is written when the
  /// result is not a valid workflow ([ConfigurationException]) or, with
  /// [expected], when the configuration changed since that revision
  /// ([UnavailableException]; load it again and retry).
  Future<WorkflowRevision> edit(List<WorkflowEdit> edits, {WorkflowRevision? expected});
}
