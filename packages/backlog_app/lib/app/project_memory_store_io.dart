import '../features/projects/application/project_memory.dart';

/// Outside the browser the last project lasts as long as the app.
ProjectMemory projectMemoryStore() => InMemoryProjectMemory();
