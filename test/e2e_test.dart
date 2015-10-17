// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style_test.source_code_test;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../bin/format.dart' as Format;
import 'package:scheduled_test/scheduled_test.dart';
import 'package:test/test.dart' as tester;
import 'package:path/path.dart' as p;

import 'package:dynamic_type_inference/src/dynamic_analysis/runtime/runtime.dart';
import 'package:dynamic_type_inference/src/dynamic_analysis/runtime/value_tracker.dart';
import 'package:dynamic_type_inference/src/dynamic_analysis/runtime/communicators/vm_type_inference_communicator.dart';

class FakeConsole {
  void log(m) { print(m); }
  void error(m) { print(m); }
  void groupCollapsed(m) { print(m); }
  void groupEnd() {}
}

callMain(args) {
  var replyTo = args.removeLast();
  var id = args.removeLast();

  VmTypeInferenceCommunicator communicator = new VmTypeInferenceCommunicator("e2e_test-" + id);
  RuntimeConstraints.initialize("dart_style_clone", communicator, new FakeConsole(), "Mode.VM_TEST_TYPE_INFERENCE");
  EventLoop.listeners.add((x, y) {
    replyTo.send("OK");
  });

  EventLoop.callMainFunction((List<String> args) {
    tester.test("test", () {
      Format.main(args);
    });
  }, args, 'dart_style_clone');
}

Future runTest(List<dynamic> args, id) {
  RuntimeConstraints.listeners.clear();
  EventLoop.listeners.clear();

  Completer c = new Completer();
  var rp = new ReceivePort();
  
  args.add(id);
  args.add(rp.sendPort);

  Isolate.spawn(callMain, args);

  rp.listen((data) {
    switch (data) {
      case "OK": c.complete();
    }
  });

  return c.future;
}

testFile(name, id) {
  test(name, () {
    schedule(() {
      var inputCode = new File(name).readAsStringSync();
      var args = [
        "--line-length",
        "80",
        "-w",
        "input.dart"
      ];
      var file = new File("input.dart");
      file.writeAsStringSync(inputCode);
      schedule(() {
        return runTest(args, id);
      });
    });
  });
}

void main() {
  stdin
  .transform(UTF8.decoder)
  .transform(new LineSplitter())
  .listen((String line) {
    if (line == "quit") {
      exit(0);
    }
  });
  
  group("group", () {
    testFile("e2e-files/file1.unit", "file1");
    testFile("e2e-files/file2.unit", "file2");
    testFile("e2e-files/file3.unit", "file3");
    testFile("e2e-files/file4.unit", "file4");
    testFile("e2e-files/file5.unit", "file5");
  });
}
