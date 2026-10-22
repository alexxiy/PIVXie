import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/db/hive/db.dart';
import 'package:paymint/utilities/desktop_password_service.dart';

void main() {
  late Directory dir;

  setUp(() async {
    await DB.instance.hive.close();
    dir = await Directory.systemTemp.createTemp("dps_test");
    DB.instance.hive.init(dir.path);
  });

  tearDown(() async {
    await DB.instance.hive.close();
    await Process.run("chmod", ["700", dir.path]);
    await dir.delete(recursive: true);
  });

  test("a new password opens again after a restart", () async {
    final dps = DPS();
    await dps.initFromNew("first password");
    expect(await dps.hasPassword(), isTrue);

    final restarted = DPS();
    await restarted.initFromExisting("first password");
    expect(await restarted.verifyPassphrase("first password"), isTrue);
    expect(await restarted.verifyPassphrase("other password"), isFalse);
  });

  test("a password that can't be saved isn't kept", () async {
    // Nothing can be written to the data folder.
    expect((await Process.run("chmod", ["500", dir.path])).exitCode, 0);

    final dps = DPS();
    await expectLater(dps.initFromNew("first password"), throwsA(anything));
    expect(() => dps.handler, throwsException);

    await Process.run("chmod", ["700", dir.path]);
    expect(await dps.hasPassword(), isFalse);
    await dps.initFromNew("first password");
    expect(await DPS().verifyPassphrase("first password"), isTrue);
  });

  test("a changed password replaces the old one", () async {
    final dps = DPS();
    await dps.initFromNew("old password");
    expect(await dps.changePassphrase("wrong password", "new"), isFalse);
    expect(await dps.changePassphrase("old password", "new password"), isTrue);

    final restarted = DPS();
    await restarted.initFromExisting("new password");
    expect(await restarted.verifyPassphrase("old password"), isFalse);
  });
}
