/// The prefix of kanban-ai's environment variables (`KANBAN_AI_AGENT`, …).
const toolVariablePrefix = 'KANBAN_AI_';

/// The prefix the variables had while the tool was called `backlog`
/// (`BACKLOG_AGENT`, …); still read when the new name is not set.
const legacyToolVariablePrefix = 'BACKLOG_';

/// The variable `KANBAN_AI_<name>` of [environment], else the older
/// `BACKLOG_<name>`; null when neither is set.
String? toolVariable(Map<String, String> environment, String name) =>
    environment['$toolVariablePrefix$name'] ?? environment['$legacyToolVariablePrefix$name'];

/// Both names of the variable [name] set to [value], for a program that may
/// still read only the older one.
Map<String, String> toolVariables(String name, String value) => {
  '$toolVariablePrefix$name': value,
  '$legacyToolVariablePrefix$name': value,
};
