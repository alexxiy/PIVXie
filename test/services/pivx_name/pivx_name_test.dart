import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/services/pivx_name/pivx_name.dart';

import 'pivx_name_fixtures.dart';

String _hex(String s) =>
    utf8.encode(s).map((b) => b.toRadixString(16).padLeft(2, "0")).join();

String? _verify(Map<String, dynamic> record, [String name = "alexxiy.pivx"]) =>
    verifyPivxNameRecord(record, name, liveRoot);

void main() {
  group("names", () {
    final cases = {
      "alex.pivx": true,
      "richard.secure": true,
      "hello-world.safe": true,
      "pivx-123.private": true,
      "a.pivx": true,
      "${"a" * 59}.pivx": true,
      "${"a" * 60}.pivx": false,
      "al-ex.pivx": true,
      "ALEX.pivx": false, // the registry's spelling is lowercase
      "alex.pivx2": false,
      "alex.pivx.name": false,
      "alex": false,
      "": false,
      ".pivx": false,
      "-alex.pivx": false,
      "alex-.pivx": false,
      "al--ex.pivx": false,
      "al_ex.pivx": false,
      "alex!.pivx": false,
      "alex space.pivx": false,
      "alexxiy.pivxfoo.safe": false,
      "alexxiy..pivx": false,
      "ålex.pivx": false,
    };
    cases.forEach((name, valid) {
      test("isValidPivxName($name) is $valid", () {
        expect(isValidPivxName(name), valid);
      });
    });

    test("input is trimmed and lowercased once", () {
      expect(normalizePivxName("  Alexxiy.PIVX "), "alexxiy.pivx");
      expect(normalizePivxName("bad--name.pivx"), isNull);
      expect(looksLikePivxName("bad--name.Pivx"), isTrue);
      expect(looksLikePivxName(liveTarget), isFalse);
    });

    // Extend any valid name by any byte and the zone stops being a zone.
    // Without that, the name's place in a record's hash could slide even with
    // every other length fixed, so it is checked rather than assumed.
    test("no valid name is the start of another", () {
      const chars = ["a", "b", "z", "0", "-", "."];
      for (final zone in kPivxNameZones) {
        for (final label in ["a", "ab", "a-b", "z0", "alexxiy"]) {
          final name = "$label.$zone";
          var ext = [""];
          for (var depth = 0; depth < 3; depth++) {
            ext = [
              for (final e in ext)
                for (final c in chars) e + c,
            ];
            for (final e in ext) {
              expect(isValidPivxName(name + e), isFalse, reason: name + e);
            }
          }
        }
      }
    });
  });

  group("target addresses", () {
    test("one mainnet Sapling address, exactly as the registry spells it", () {
      expect(isStrictPivxNameTarget(liveTarget), isTrue);
      for (final bad in [
        liveTarget.substring(0, liveTarget.length - 1),
        "${liveTarget}a",
        liveTarget.toUpperCase(),
        "ps1${"q" * 75}",
        // the same payload with a bech32m checksum
        "ps19wd4eft4mw2mlwad6tjrny5hlvtdxymatu2e3dge7jr6scqask0llvdsa3xhx06499vmz38d8rp",
        // a padding bit set
        "ps19wd4eft4mw2mlwad6tjrny5hlvtdxymatu2e3dge7jr6scqask0llvdsa3xhx06499vmredf7m3",
        // testnet
        "ptestsapling1${liveTarget.substring(3)}",
      ]) {
        expect(isStrictPivxNameTarget(bad), isFalse, reason: bad);
      }
    });
  });

  group("records", () {
    test("the live records verify against the chain's root", () {
      expect(_verify(liveRecord()), liveTarget);
      // listed for sale: a price that takes all 8 bytes' worth of care
      expect(
        verifyPivxNameRecord(donateRecord(), "donate.pivx", liveRoot),
        otherShieldAddress,
      );
      expect(
        verifyPivxNameRecord(
          liveRecord(),
          "alexxiy.pivx",
          "0x${liveRoot.toUpperCase()}",
        ),
        liveTarget,
      );
    });

    test("any changed field breaks it", () {
      final changes = <String, Object?>{
        "target_address": "ps1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq",
        "owner_pubkey":
            "4757ee1a8b3f10353ca6edd47b66920392b02e323dca3f3edddb5de142079a53",
        "price": 1,
        "nonce": 1786604914,
        "merkle_proof": [
          "de7b953670410e6a28bb669dbf36c92b3a1d3be8ad1053b9dfcf730049fe57ff",
          "8de7514f0d3a019a6cb017618c3c8f2774aaf063b47a0ed1fcc52e4a7080fa71",
          "48830e34174714ac8990c825d5f9b8751713207bf370b100c3e956cd16efc4cc",
        ],
        "domain_name": "alexxiy.safe",
      };
      changes.forEach((field, value) {
        expect(_verify(liveRecord({field: value})), isNull, reason: field);
      });
      // A real address of the right shape that isn't the one committed to.
      expect(
        _verify(liveRecord({"target_address": otherShieldAddress})),
        isNull,
      );
      expect(_verify(liveRecord(), "alexxiy.safe"), isNull);
    });

    test("a record folded for another name is refused", () {
      expect(
        verifyPivxNameRecord(
          liveRecord({"domain_name": "donate.pivx"}),
          "donate.pivx",
          liveRoot,
        ),
        isNull,
      );
    });

    test("the depth must match the proof, and stay within 128", () {
      expect(_verify(liveRecord({"proof_depth": 2})), isNull);
      expect(_verify(liveRecord({"proof_depth": 4})), isNull);
      expect(_verify(liveRecord({"proof_depth": "3"})), isNull);
      final deep = List.filled(129, "00" * 32);
      expect(
        _verify(liveRecord({"merkle_proof": deep, "proof_depth": 129})),
        isNull,
      );
    });

    test("only an inclusion proof resolves a name", () {
      for (final terminal in <Object?>[
        "Vacant",
        "occupied",
        null,
        <String, Object>{"Blocked": <String, Object>{}},
      ]) {
        expect(
          _verify(liveRecord({"proof_terminal": terminal})),
          isNull,
          reason: "$terminal",
        );
      }
    });

    test("incomplete or malformed records are refused", () {
      for (final field in [
        "target_address",
        "owner_pubkey",
        "price",
        "nonce",
        "smt_root",
        "merkle_proof",
        "proof_depth",
        "proof_terminal",
        "domain_name",
      ]) {
        final record = liveRecord()..remove(field);
        expect(_verify(record), isNull, reason: field);
      }
      expect(verifyPivxNameRecord(null, "alexxiy.pivx", liveRoot), isNull);
      expect(verifyPivxNameRecord("x", "alexxiy.pivx", liveRoot), isNull);
      expect(
        _verify(
          liveRecord({
            "merkle_proof": ["zz" * 32, "00" * 32, "00" * 32],
          }),
        ),
        isNull,
      );
      expect(
        _verify(
          liveRecord({
            "merkle_proof": ["00" * 31, "00" * 32, "00" * 32],
          }),
        ),
        isNull,
      );
    });

    test("price and nonce must be exact u64 values", () {
      for (final bad in [
        -1,
        1.5,
        1786604913.0,
        "0x10",
        "1e3",
        " 1",
        "18446744073709551616",
        true,
        <String, dynamic>{},
      ]) {
        expect(_verify(liveRecord({"nonce": bad})), isNull, reason: "$bad");
      }
      // The decimal-string spelling of the same value is the same value.
      expect(_verify(liveRecord({"nonce": "1786604913"})), liveTarget);
    });
  });

  // The record's hash has no length prefixes, so these all hash to the same
  // bytes as the real record. Only the fixed field shapes stop them.
  group("field boundaries", () {
    test("undecodable characters after the owner key", () {
      expect(
        _verify(liveRecord({"owner_pubkey": "${liveOwnerKey}ZZZZ"})),
        isNull,
      );
    });

    test("an owner key that swallowed the start of the address", () {
      for (final k in [1, 5, 20, 40]) {
        final record = liveRecord({
          "owner_pubkey": liveOwnerKey + _hex(liveTarget.substring(0, k)),
          "target_address": liveTarget.substring(k),
        });
        expect(_verify(record), isNull, reason: "k=$k");
      }
    });

    test("an owner key shorter than 32 bytes", () {
      expect(
        _verify(liveRecord({"owner_pubkey": liveOwnerKey.substring(0, 60)})),
        isNull,
      );
    });

    test("a name that slides into the owner key", () {
      // hash_leaf("alexxiy.pivxfoo.safe", P, ...) has the same bytes as
      // hash_leaf("alexxiy.pivx", hex("foo.safe") + P, ...).
      expect(
        _verify(liveRecord({"owner_pubkey": _hex("foo.safe") + liveOwnerKey})),
        isNull,
      );
      expect(
        verifyPivxNameRecord(
          liveRecord({"domain_name": "alexxiy.pivxfoo.safe"}),
          "alexxiy.pivxfoo.safe",
          liveRoot,
        ),
        isNull,
      );
    });
  });

  group("the root comes from the chain", () {
    test("never from the record", () {
      for (final root in ["", "not-a-root", "11" * 32, "00" * 32]) {
        expect(
          verifyPivxNameRecord(liveRecord(), "alexxiy.pivx", root),
          isNull,
          reason: root,
        );
      }
    });

    // A depth 0 proof whose root is its own leaf agrees with itself, and is
    // worth nothing against the chain's root. c1427a59… is the live record's
    // leaf hash, as MyPIVXWallet's tests compute it.
    test("a self-rooted depth 0 proof", () {
      const leaf =
          "c1427a5973e100b84eca8f44ed1e3a7be635e46a3154f076e3861e59fcbde16e";
      final selfRooted = liveRecord({
        "merkle_proof": <String>[],
        "proof_depth": 0,
        "smt_root": leaf,
      });
      expect(
        verifyPivxNameRecord(selfRooted, "alexxiy.pivx", leaf),
        liveTarget,
      );
      expect(_verify(selfRooted), isNull);
    });

    // The name rule holds on its own, whatever root the caller trusts: a
    // record for a name the registry can't hold is refused even when it is
    // consistent with its root.
    test("never for a name the registry can't hold", () {
      const name = "alexxiy.pivxfoo.safe";
      // its leaf, with the live record's other fields
      const leaf =
          "630132a6c12b1576648a66f99f75f6e565d26e8632ab5db7f14e956c69c1a31d";
      final selfRooted = liveRecord({
        "domain_name": name,
        "merkle_proof": <String>[],
        "proof_depth": 0,
        "smt_root": leaf,
      });
      expect(verifyPivxNameRecord(selfRooted, name, leaf), isNull);
    });

    test("the record's own root must be the chain's", () {
      expect(_verify(liveRecord({"smt_root": "11" * 32})), isNull);
      expect(_verify(liveRecord({"smt_root": null})), isNull);
    });
  });

  test("roots are 32 bytes of hex", () {
    expect(parsePivxNameRoot("0x${"AB" * 32}"), "ab" * 32);
    expect(parsePivxNameRoot("ab" * 31), isNull);
    expect(parsePivxNameRoot("${"ab" * 32}0"), isNull);
    expect(parsePivxNameRoot("zz" * 32), isNull);
    expect(parsePivxNameRoot(42), isNull);
  });
}
