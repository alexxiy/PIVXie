// PIVXie against MyPIVXWallet's own test vectors (tests/unit/masterkey.spec.js
// and tests/unit/parsed_secret.json there), so a recovery phrase opens the
// same wallet in both, account by account. Plus the account helpers.
import 'package:bip39/bip39.dart' as bip39;
import 'package:coinlib_flutter/coinlib_flutter.dart' as coinlib;
import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/pages/pivx_accounts/pivx_accounts.dart';
import 'package:paymint/utilities/enums/derive_path_type_enum.dart';
import 'package:paymint/utilities/extensions/extensions.dart';
import 'package:paymint/wallets/crypto_currency/crypto_currency.dart';
import 'package:paymint/wallets/wallet/impl/pivx_wallet.dart';

const _mnemonic =
    "high fruit sick panther hospital place robust seminar maze benefit shoe bleak";

/// The phrase's BIP32 root, the same on every network.
const _xprv =
    "xprv9s21ZrQH143K3T6FKuAJ8fZ4CrnPjPGUMDA38wmpyazxn8aNrCyebV4wh9LiD5oZyQmC5zaTDSjacWgpJ4PGzkQgFK9n1AAebt4shda53wK";

/// Account 0's xpub. MyPIVXWallet writes every network's xpub with
/// Bitcoin's mainnet version bytes ("xpub"); PIVXie uses "tpub" on testnet.
const _mpwAccount0Xpub = {
  CryptoCurrencyNetwork.main: "xpub6D5vhgPg8E8gykS6mHhquBey5bVRmu96xedXKqcm2wNY2orePTj2oBtkgAGvm75jCNTNvRPXtXM7Kbi5trEQ4YGyqf4STGVm4pD62w1zgzM",
  CryptoCurrencyNetwork.test: "xpub6BsLmaiXvY1vKDpkVv39aqWHVJYiL7ft9LS1SKwJRzv7UW5gGRCMMqBSJsqJPVQuV6k6aa8Zt8vidVTdTJotHGzaaEqFag9bMwbNWHfW86q",
};

/// The first five receiving addresses of accounts 0, 1 and 2.
const _mpwAddresses = {
  CryptoCurrencyNetwork.main: {
    0: [
      "DR658aDrQviYy3rDUGM1Mzzi12WHwqQDpE",
      "DDdiX27tHmaaZqFHXkz1SnnmK81DzFJVca",
      "DEMqSgPEvqGAhWvq11oVymyLT6aJK5NQNx",
      "DFzV4XA2KdQJx4oYJw97VoSxN21xNvqwBc",
      "DCrtxnTx7UFtx1HfKLVNFXmKvcdcoepQh1",
    ],
    1: [
      "DF9Q8himXERhrqwUq4pGQkSkunkRXJiMLk",
      "DAhRJMT3u3dF5Y1QDBoBQq9fDLRNonW68z",
      "DM7hXW79nCf9FjcF8aH5oAFYfRTSQD5sck",
      "DMQRXhooJcFwE8tgnMsQBfrc4BQD2UBKd8",
      "D6nhBBnAzBhHpaqAxmiJDMph8HByM92ovX",
    ],
    2: [
      "DFEDsA5WfRSrv5FEcHtUs9u1xdksxiLYkC",
      "DN2Nj8KHyo4fP4bshXemoYfMhX7cJpE8xq",
      "DRtGvuVRFhdHtNs2skFWT52cWNN6BuPJM2",
      "D5dfPtyZp1Bh9pyEutSL43kcw2YEBhjwLf",
      "DT6Wn5rRq2fsKfMS4cdvq9EiUPwT2SGpmV",
    ],
  },
  CryptoCurrencyNetwork.test: {
    0: [
      "y5eBXdy8fhXAHFuYu3JgirBunz1SsvyQ7g",
      "yFDsWerVPm2TzekdpmuACNz2tRsCudnYmU",
      "y4Swao25gHXSELKTzn5F5is9GytZm4kkJt",
      "yBrsVZg3a3bJEoVCGTcppX2SFkGPJy7Duv",
      "y9upM38TYo79boE48NdvkdQ2Hyi2JJekRo",
    ],
    1: [
      "yAFRMPnsnCQbxRKFx6u1GhKQLafX1EHLTx",
      "yHQrYayVZxYQhBbhPxNu6C4HBSjt8AScTT",
      "xzFHoPegqHquLE8W2DMMobeRnWq11bVvMB",
      "y1bWJZST917SvrSH6ynT3keD4D3ob3VyXD",
      "xwpxLcrDywZboafRNTVvWjDXqNrw6iFDtm",
    ],
    2: [
      "y9mY3ku8SxEYEWYCK8Q1B2Sskg3pzBhBzP",
      "yDY276awC1Hg43Nxr3EuoMvHakMsX31Bgy",
      "yEKycCqkDqQs2D6DgAJWpZsN3WqmAzS5dA",
      "y5ZVwmyrBmmd4WaQjM7enqZGWT8gYYFA8P",
      "xw3MUT7M69VTdGb2WTEwMEVnFxxyrZU5GR",
    ],
  },
};

const _mpwSeeds = [
  (
    mnemonic: "display item diagram flip slogan firm illness measure staff shrimp absent abandon",
    passphrase: "",
    seed:
        "2e92a1b65e77b6f1e5a77b9a5bab3be47e47cc8286a04f863d9d7829300b4f94"
        "4037b9472c9b8d578dc966c30f3d7ac81021b6cbb783f1453612d8ebccd6c4ed",
    xprv: "xprv9s21ZrQH143K35E747GySrQzeXGAS1rsfCyfMjEyFAczB4Xwy6phKaE5ps9FxcswDAaFqamX3BEAR6CePBKZqHGK5mtjUtMJ3EzevA773h6",
  ),
  (
    mnemonic: "display item diagram flip slogan firm illness measure staff shrimp absent abandon",
    passphrase: "123456",
    seed:
        "9e867a891a3420fbf2e2ee5c760cea1b27f5d920a009b6ae7582466f2b614953"
        "7be6e7f87489f11bd929e284c49e4ca98c592a8c84147f203e75ce71a0be80df",
    xprv: "xprv9s21ZrQH143K2LMsnBWQyzuwJWqeTagZ8i3hDwRNhYPVauTTmw3gmqDYDaZSthdLJ6HhvKrp6qAP4xEC3SvzofZmV4XSUPo3B7WE1JWEt8Y",
  ),
];

void main() {
  setUpAll(() async => coinlib.loadCoinlib());

  final mainnet = Pivx(CryptoCurrencyNetwork.main);

  // As PivxWallet._deriveAddress: public derivation from the account xpub.
  String receiving(Pivx coin, String accountXpub, int index) => coin
      .getAddressForPublicKey(
        publicKey: coinlib.HDPublicKey.decode(
          accountXpub,
          coin.networkParams.pubHDPrefix,
        ).derivePath("0/$index").publicKey,
        derivePathType: DerivePathType.bip44,
      )
      .address
      .toString();

  test("a phrase and passphrase give MyPIVXWallet's seed", () {
    // As PivxWallet._seed and getRootHDNode.
    for (final v in _mpwSeeds) {
      final seed = bip39.mnemonicToSeed(v.mnemonic, passphrase: v.passphrase);
      expect(seed.toHex, v.seed);
      expect(
        coinlib.HDPrivateKey.fromSeed(seed)
            .encode(mainnet.networkParams.privHDPrefix),
        v.xprv,
      );
    }
  });

  for (final network in _mpwAddresses.keys) {
    test("accounts give MyPIVXWallet's addresses on ${network.name}", () {
      final coin = Pivx(network);
      final root = coinlib.HDPrivateKey.fromSeed(
        bip39.mnemonicToSeed(_mnemonic),
      );
      expect(root.encode(mainnet.networkParams.privHDPrefix), _xprv);
      expect(
        pivxAccountXpub(root, coin, 0),
        coinlib.HDPublicKey.decode(
          _mpwAccount0Xpub[network]!,
          mainnet.networkParams.pubHDPrefix,
        ).encode(coin.networkParams.pubHDPrefix),
      );
      for (final MapEntry(key: account, value: addresses)
          in _mpwAddresses[network]!.entries) {
        final xpub = pivxAccountXpub(root, coin, account);
        for (final (i, address) in addresses.indexed) {
          expect(receiving(coin, xpub, i), address, reason: "$account/0/$i");
        }
      }
    });
  }

  test("account paths", () {
    expect(pivxAccountPath(mainnet, 0), "m/44'/119'/0'");
    expect(pivxAccountPath(mainnet, 2), "m/44'/119'/2'");
    expect(pivxAccountPath(Pivx(CryptoCurrencyNetwork.test), 1), "m/44'/1'/1'");
  });

  group("finding used accounts", () {
    Future<List<int>> find(Set<int> used) =>
        pivxFindAccounts(from: 1, isUsed: (n) async => used.contains(n));

    test("looks past two unused accounts, not three", () async {
      expect(await find({}), isEmpty);
      expect(await find({1, 2}), [1, 2]);
      expect(await find({2, 5}), [2, 5]);
      expect(await find({3}), [3]);
      expect(await find({4}), isEmpty);
    });

    test("stops after 20 accounts", () async {
      final all = await pivxFindAccounts(from: 1, isUsed: (_) async => true);
      expect(all, [for (int n = 1; n <= 20; n++) n]);
    });

    test("reads the bridge's answer", () {
      expect(pivxXpubIsUsed({}), isFalse);
      expect(pivxXpubIsUsed({"usedTokens": 0, "txs": 0}), isFalse);
      expect(pivxXpubIsUsed({"usedTokens": 2}), isTrue);
      expect(pivxXpubIsUsed({"txs": 1}), isTrue);
      expect(pivxXpubIsUsed({"unconfirmedTxs": 1}), isTrue);
    });
  });

  group("account wallets", () {
    test("the next account is the lowest one not here", () {
      expect(pivxNextAccount([]), 1);
      expect(pivxNextAccount([0]), 1);
      expect(pivxNextAccount([0, 1, 2]), 3);
      expect(pivxNextAccount([0, 2]), 1);
      expect(pivxNextAccount([1, 0, 3]), 2);
    });

    test("names", () {
      expect(pivxAccountWalletName("Savings", 1, {}), "Savings (account 1)");
      expect(
        pivxAccountWalletName("Savings (account 1)", 2, {}),
        "Savings (account 2)",
      );
      expect(
        pivxAccountWalletName("Savings", 2, {"Savings (account 2)"}),
        "Savings (account 2) 2",
      );
      expect(
        pivxAccountWalletName("Savings (account 2) 2", 3, {}),
        "Savings (account 3)",
      );
    });
  });
}
