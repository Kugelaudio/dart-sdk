// The platform seam: everything that differs between the Dart VM (mobile,
// desktop, server) and the browser. Only `platform_io.dart` imports
// `dart:io`, and only where `dart:io` exists.
export 'platform_stub.dart'
    if (dart.library.io) 'platform_io.dart'
    if (dart.library.js_interop) 'platform_web.dart';
