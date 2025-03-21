// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:io';

import 'package:dwds/dwds.dart';
import 'package:dwds/src/handlers/injected_handler.dart';
import 'package:dwds/src/utilities/shared.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

void main() {
  HttpServer server;
  const entryEtag = 'entry etag';
  const nonEntryEtag = 'some etag';

  group('InjectedHandlerWithoutExtension', () {
    setUp(() async {
      globalModuleStrategy = ModuleStrategy.requireJS;
      var pipeline = const Pipeline()
          .addMiddleware(createInjectedHandler(ReloadConfiguration.liveReload));
      server = await shelf_io.serve(pipeline.addHandler((request) {
        if (request.url.path.endsWith(bootstrapJsExtension)) {
          return Response.ok(
              '$entrypointExtensionMarker\n'
              '$mainExtensionMarker\n'
              'app.main.main()',
              headers: {HttpHeaders.etagHeader: entryEtag});
        } else if (request.url.path.endsWith('foo.js')) {
          return Response.ok('some js',
              headers: {HttpHeaders.etagHeader: nonEntryEtag});
        } else {
          return Response.notFound('Not found');
        }
      }), 'localhost', 0);
    });

    tearDown(() async {
      await server.close();
    });

    test('leaves non-entrypoints untouched', () async {
      var result = await http.get('http://localhost:${server.port}/foo.js');
      expect(result.body, 'some js');
    });

    test('does not update etags for non-entrypoints', () async {
      var result = await http.get('http://localhost:${server.port}/foo.js');
      expect(result.headers[HttpHeaders.etagHeader], nonEntryEtag);
    });

    test('replaces main marker with injected client', () async {
      var result = await http.get(
          'http://localhost:${server.port}/entrypoint$bootstrapJsExtension');
      expect(result.body.contains('Injected by webdev'), isTrue);
      expect(result.body.contains(mainExtensionMarker), isFalse);
    });

    test('prevents main from being called', () async {
      var result = await http.get(
          'http://localhost:${server.port}/entrypoint$bootstrapJsExtension');
      expect(result.body.contains('app.main.main()'), isFalse);
    });

    test('updates etags for injected responses', () async {
      var result = await http.get(
          'http://localhost:${server.port}/entrypoint$bootstrapJsExtension');
      expect(result.headers[HttpHeaders.etagHeader], isNot(entryEtag));
    });

    test('ignores non-js requests', () async {
      var result = await http.get('http://localhost:${server.port}/main.dart');
      expect(result.body, 'Not found');
    });

    test(
        'Does not return 304 when if-none-match etag matches the original '
        'content etag', () async {
      var result = await http.get(
          'http://localhost:${server.port}/entrypoint$bootstrapJsExtension',
          headers: {HttpHeaders.ifNoneMatchHeader: entryEtag});
      expect(result.statusCode, HttpStatus.ok);
    });

    test('Does return 304 when if-none-match etag matches the modified etag',
        () async {
      var originalResponse = await http.get(
          'http://localhost:${server.port}/entrypoint$bootstrapJsExtension');
      var cachedResponse = await http.get(
          'http://localhost:${server.port}/entrypoint$bootstrapJsExtension',
          headers: {
            HttpHeaders.ifNoneMatchHeader:
                originalResponse.headers[HttpHeaders.etagHeader]
          });
      expect(cachedResponse.statusCode, HttpStatus.notModified);
    });

    test('Does not inject the extension backend port', () async {
      var result = await http.get(
          'http://localhost:${server.port}/entrypoint$bootstrapJsExtension');
      expect(result.body.contains('extensionHostname'), isFalse);
      expect(result.body.contains('extensionPort'), isFalse);
    });
  });

  group('InjectedHandlerWithExtension', () {
    setUp(() async {
      var someExtensionHostname = 'localhost';
      var someExtensionPort = 4000;
      var pipeline = const Pipeline().addMiddleware(createInjectedHandler(
          ReloadConfiguration.liveReload,
          extensionHostname: someExtensionHostname,
          extensionPort: someExtensionPort));
      server = await shelf_io.serve(pipeline.addHandler((request) {
        return Response.ok(
            '$entrypointExtensionMarker\n'
            '$mainExtensionMarker\n'
            'app.main.main()',
            headers: {HttpHeaders.etagHeader: entryEtag});
      }), 'localhost', 0);
    });

    tearDown(() async {
      await server.close();
    });

    test('Injects the extension backend port', () async {
      var result = await http.get(
          'http://localhost:${server.port}/entrypoint$bootstrapJsExtension');
      expect(result.body.contains('extensionHostname'), isTrue);
      expect(result.body.contains('extensionPort'), isTrue);
    });
  });
}
