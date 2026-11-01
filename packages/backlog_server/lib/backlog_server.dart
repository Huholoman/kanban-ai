/// HTTP server over one or more backlog folders: REST API, change events over WebSocket
/// and the built web app.
library;

export 'src/backlog_host.dart';
export 'src/backlog_server.dart';
export 'src/events/agent_log_socket.dart';
export 'src/http/api_handler.dart';
export 'src/http/client_filter.dart';
export 'src/http/dto_mapper.dart';
export 'src/http/middleware.dart' show generateToken;
export 'src/mcp/mcp_handler.dart';
export 'src/mcp/mcp_tools.dart';
export 'src/preview/process_server_control.dart';
export 'src/projects/backlog_autocommit.dart';
export 'src/projects/hosted_project.dart';
export 'src/projects/project_hub.dart';
export 'src/projects/registry_watcher.dart';
