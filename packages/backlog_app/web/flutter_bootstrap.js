{{flutter_js}}
{{flutter_build_config}}

// No service worker: backlog-server revalidates every file by ETag, so a
// cache in a worker would only delay the first start (it downloaded
// main.dart.js before the app could) and could serve an outdated build.
// The build still writes an empty flutter_service_worker.js
// (--pwa-strategy=none) that replaces the worker of older builds.
_flutter.loader.load();
