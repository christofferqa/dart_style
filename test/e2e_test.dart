// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library dart_style_test.source_code_test;

import '../bin/format.dart' as Format;
import 'dart:isolate';
import 'package:scheduled_test/scheduled_test.dart';
import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;

callMain(args) {
  Format.main(args);
}

Future runTest(List<dynamic> args) {
  Completer c = new Completer();
  var exit = new ReceivePort();
  Isolate.spawn(callMain, args, onExit: exit.sendPort);
  exit.listen((data) {
    c.complete();
  });
  return c.future;
}

testFile(name) {
  test(name, () {
    schedule(() {
      var inputCode = new File(name).readAsStringSync();

      var args = ["--line-length", "80", "-w", "input.dart"];
      
      var file = new File("input.dart");
      
      file.writeAsStringSync(inputCode);

      schedule(() {
        return runTest(args);  
      });
    });
  });  
}


void main() {
  group("group", () {
    testFile("e2e-files/file1.dart");
    testFile("e2e-files/file2.dart");
    testFile("e2e-files/file3.dart");
    testFile("e2e-files/file4.dart");
    testFile("e2e-files/file5.dart");
  });
}
  