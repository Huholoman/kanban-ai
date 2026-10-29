import 'package:yaml/yaml.dart';

import '../../shared/errors.dart';
import '../domain/workflow.dart';

/// Parses the `backlog.yaml` format into a [Workflow].
///
/// Every section is optional; missing ones fall back to [Workflow.standard].
Workflow parseWorkflowYaml(String source, {String origin = 'backlog.yaml'}) {
  final Object? document;
  try {
    document = loadYaml(source);
  } on YamlException catch (e) {
    throw ConfigurationException('$origin: ${e.message}');
  }
  if (document == null) return Workflow.standard();
  if (document is! YamlMap) {
    throw ConfigurationException('$origin: expected a mapping at the top level.');
  }

  final standard = Workflow.standard();
  final id = _map(document['id'], 'id', origin);
  final defaults = _map(document['defaults'], 'defaults', origin);
  final claims = _map(document['claims'], 'claims', origin);

  final statusNodes = document['statuses'];
  final statuses = statusNodes == null
      ? standard.statuses
      : _list(statusNodes, 'statuses', origin).map((node) {
          final status = _map(node, 'statuses[]', origin);
          return StatusDefinition(
            _string(status['id'], 'statuses[].id', origin),
            StatusCategory.parse(_string(status['category'], 'statuses[].category', origin)),
            pickable: status['pickable'] == true,
          );
        }).toList();

  final milestones = _list(document['milestones'] ?? const [], 'milestones', origin).map((node) {
    if (node is! YamlMap) {
      return MilestoneDefinition(_string(node, 'milestones[]', origin));
    }
    return MilestoneDefinition(
      _string(node['id'], 'milestones[].id', origin),
      title: node['title']?.toString(),
      due: node['due']?.toString(),
    );
  }).toList();

  final leaseMinutes = claims['lease_minutes'];
  if (leaseMinutes != null && leaseMinutes is! int) {
    throw ConfigurationException('$origin: claims.lease_minutes must be an integer.');
  }
  final idLength = id['length'];
  if (idLength != null && idLength is! int) {
    throw ConfigurationException('$origin: id.length must be an integer.');
  }

  return Workflow(
    statuses: statuses,
    priorities: document['priorities'] == null
        ? standard.priorities
        : _strings(document['priorities'], 'priorities', origin),
    types: document['types'] == null ? standard.types : _strings(document['types'], 'types', origin),
    milestones: milestones,
    idPrefix: id['prefix']?.toString() ?? standard.idPrefix,
    idLength: (idLength as int?) ?? standard.idLength,
    defaultStatus: defaults['status']?.toString() ?? (statusNodes == null ? standard.defaultStatus : null),
    defaultPriority:
        defaults['priority']?.toString() ?? (document['priorities'] == null ? standard.defaultPriority : null),
    defaultType: defaults['type']?.toString() ?? (document['types'] == null ? standard.defaultType : null),
    claimLease: leaseMinutes == null ? standard.claimLease : Duration(minutes: leaseMinutes as int),
  );
}

YamlMap _map(Object? node, String path, String origin) {
  if (node == null) return YamlMap();
  if (node is YamlMap) return node;
  throw ConfigurationException('$origin: "$path" must be a mapping.');
}

List<Object?> _list(Object? node, String path, String origin) {
  if (node is List) return node;
  throw ConfigurationException('$origin: "$path" must be a list.');
}

List<String> _strings(Object? node, String path, String origin) =>
    _list(node, path, origin).map((v) => _string(v, '$path[]', origin)).toList();

String _string(Object? node, String path, String origin) {
  if (node == null || node is Map || node is List) {
    throw ConfigurationException('$origin: "$path" must be a scalar value.');
  }
  final value = node.toString().trim();
  if (value.isEmpty) {
    throw ConfigurationException('$origin: "$path" must not be empty.');
  }
  return value;
}

/// The commented `backlog.yaml` that `backlog init` writes.
String workflowTemplate({String idPrefix = 'T'}) =>
    '''
# Backlog configuration. Items live in items/, saved views in views/.

id:
  prefix: $idPrefix      # new items get ids like $idPrefix-7f3a
  length: 4

# Board order. category: open | active | done
# pickable: agents may take items in this status as ready work.
statuses:
  - id: backlog
    category: open
  - id: todo
    category: open
    pickable: true
  - id: in-progress
    category: active
  - id: review
    category: active
  - id: done
    category: done
  - id: cancelled
    category: done

# From the most urgent.
priorities: [p0, p1, p2, p3]

types: [task, story, epic, bug, decision, idea]

# Leave empty to allow any milestone name.
milestones: []
#  - id: launch
#    title: Production launch
#    due: 2026-12-01

defaults:
  status: backlog
  priority: p2
  type: task

claims:
  lease_minutes: 240   # a claim without heartbeat expires after this
''';
