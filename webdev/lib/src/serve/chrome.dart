// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:webkit_inspection_protocol/webkit_inspection_protocol.dart';

import 'utils.dart';

const _chromeEnvironment = 'CHROME_EXECUTABLE';
const _linuxExecutable = 'google-chrome';
const _macOSExecutable =
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const _windowsExecutable = r'Google\Chrome\Application\chrome.exe';
var _windowsPrefixes = [
  Platform.environment['LOCALAPPDATA'],
  Platform.environment['PROGRAMFILES'],
  Platform.environment['PROGRAMFILES(X86)']
];

String get _executable {
  if (Platform.environment.containsKey(_chromeEnvironment)) {
    return Platform.environment[_chromeEnvironment];
  }
  if (Platform.isLinux) return _linuxExecutable;
  if (Platform.isMacOS) return _macOSExecutable;
  if (Platform.isWindows) {
    return p.join(
        _windowsPrefixes.firstWhere((prefix) {
          if (prefix == null) return false;
          var path = p.join(prefix, _windowsExecutable);
          return File(path).existsSync();
        }, orElse: () => '.'),
        _windowsExecutable);
  }
  throw StateError('Unexpected platform type.');
}

var _currentCompleter = Completer<Chrome>();

/// A class for managing an instance of Chrome.
class Chrome {
  final int debugPort;
  final Process _process;
  final Directory _dataDir;

  final ChromeConnection chromeConnection;

  Chrome._(
    this.debugPort,
    this.chromeConnection, {
    Process process,
    Directory dataDir,
  })  : _process = process,
        _dataDir = dataDir;

  Future<void> close() async {
    if (_currentCompleter.isCompleted) _currentCompleter = Completer<Chrome>();
    chromeConnection.close();
    _process?.kill(ProcessSignal.sigkill);
    await _process?.exitCode;
    try {
      // Chrome starts another process as soon as it dies that modifies the
      // profile information. Give it some time before attempting to delete
      // the directory.
      await Future.delayed(const Duration(milliseconds: 500));
      await _dataDir?.delete(recursive: true);
    } catch (_) {
      // Silently fail if we can't clean up the profile information.
      // It is a system tmp directory so it should get cleaned up eventually.
    }
  }

  /// Connects to an instance of Chrome with an open debug port.
  static Future<Chrome> fromExisting(int port) async =>
      _connect(Chrome._(port, ChromeConnection('localhost', port)));

  static Future<Chrome> get connectedInstance => _currentCompleter.future;

  /// Starts Chrome with the remote debug port enabled.
  ///
  /// Each url in [urls] will be loaded in a separate tab.
  static Future<Chrome> start(List<String> urls, {int port}) async {
    var dataDir = Directory.systemTemp.createTempSync();
    port = port == null || port == 0 ? await findUnusedPort() : port;
    var args = [
      // Using a tmp directory ensures that a new instance of chrome launches
      // allowing for the remote debug port to be enabled.
      '--user-data-dir=${dataDir.path}',
      '--remote-debugging-port=$port',
      // When the DevTools has focus we don't want to slow down the application.
      '--disable-background-timer-throttling',
      // Since we are using a temp profile, disable features that slow the
      // Chrome launch.
      '--disable-extensions',
      '--disable-popup-blocking',
      '--bwsi',
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-default-apps',
      '--disable-translate',
    ]..addAll(urls);

    var process = await Process.start(_executable, args);

    // Wait until the DevTools are listening before trying to connect.
    await process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .firstWhere((line) => line.startsWith('DevTools listening'))
        .timeout(const Duration(seconds: 60),
            onTimeout: () =>
                throw Exception('Unable to connect to Chrome DevTools.'));

    return _connect(Chrome._(
      port,
      ChromeConnection('localhost', port),
      process: process,
      dataDir: dataDir,
    ));
  }

  static Future<Chrome> _connect(Chrome chrome) async {
    if (_currentCompleter.isCompleted) {
      throw ChromeError('Only one instance of chrome can be started.');
    }
    // The connection is lazy. Try a simple call to make sure the provided
    // connection is valid.
    try {
      await chrome.chromeConnection.getTabs();
    } catch (e) {
      await chrome.close();
      throw ChromeError(
          'Unable to connect to Chrome debug port: ${chrome.debugPort}\n $e');
    }
    _currentCompleter.complete(chrome);
    return chrome;
  }
}

class ChromeError extends Error {
  final String details;
  ChromeError(this.details);

  @override
  String toString() {
    return 'ChromeError: $details';
  }
}
