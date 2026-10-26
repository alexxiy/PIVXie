import 'dart:convert';
import 'dart:io';

import 'package:decimal/decimal.dart';
import 'package:intl/intl.dart';

import '../../app_config.dart';
import '../../l10n/l10n.dart';
import '../../models/isar/models/isar_models.dart';
import '../../networking/http.dart';
import '../../services/pivx_name/pivx_name_resolver.dart';
import '../../services/tor_service.dart';
import '../../utilities/amount/amount.dart';
import '../../utilities/assets.dart';
import '../../utilities/logger.dart';
import '../../utilities/prefs.dart';
import '../../wallets/crypto_currency/crypto_currency.dart';
import '../../wallets/models/tx_data.dart';
import '../../wallets/wallet/impl/pivx_wallet.dart';
import '../../widgets/pivx_memo_field.dart';

// "Fuel PIVXie": donations to PIVXie's developer, straight from the wallet.
// The tiers are in US dollars; the PIV amount follows the price.

/// Where donations go: a PIVX name, looked up and checked like any name
/// typed on the send screen.
const kPivxDonationName = "alexxiy.pivx";

/// Whether [coin]'s wallets can donate: where PIVX names resolve (mainnet).
/// Not on iOS: the App Store wants tips to the developer to go through
/// in-app purchase.
bool pivxDonationAvailable(CryptoCurrency coin) =>
    !Platform.isIOS && PivxNameService.forCoin(coin) != null;

/// The cheers message: what the 512-byte memo has room for after the
/// tag line (at most 63 bytes, see [pivxDonationMemo]).
const kPivxDonationMessageBytes = 448;

enum PivxDonationTier {
  tinyDrop(1, "💧", "Tiny Drop"),
  cyberMug(5, "☕️", "Cyber Mug"),
  doubleShot(10, "⚡️", "Double-Shot"),
  zeroKnowledgeNitro(20, "🕶️", "Zero-Knowledge Nitro"),
  directIv(50, "🔋", "Direct IV"),
  rocketBoost(100, "🚀", "Rocket Boost"),
  customBrew(null, "🧪", "The Custom Brew");

  const PivxDonationTier(this.usd, this.emoji, this.memoName);

  /// The price in dollars; null for the custom amount.
  final int? usd;
  final String emoji;

  /// The name in the memo, which the developer reads in English.
  final String memoName;

  static const fixed = [
    tinyDrop,
    cyberMug,
    doubleShot,
    zeroKnowledgeNitro,
    directIv,
    rocketBoost,
  ];

  bool get isCustom => usd == null;

  String get title => switch (this) {
    tinyDrop => l10n.donateTinyDrop,
    cyberMug => l10n.donateCyberMug,
    doubleShot => l10n.donateDoubleShot,
    zeroKnowledgeNitro => l10n.donateZeroKnowledgeNitro,
    directIv => l10n.donateDirectIv,
    rocketBoost => l10n.donateRocketBoost,
    customBrew => l10n.donateCustomBrew,
  };

  /// What the mascot is up to.
  String get mascot => switch (this) {
    tinyDrop => l10n.donateTinyDropMascot,
    cyberMug => l10n.donateCyberMugMascot,
    doubleShot => l10n.donateDoubleShotMascot,
    zeroKnowledgeNitro => l10n.donateZeroKnowledgeNitroMascot,
    directIv => l10n.donateDirectIvMascot,
    rocketBoost => l10n.donateRocketBoostMascot,
    customBrew => l10n.donateCustomBrewMascot,
  };

  String get description => switch (this) {
    tinyDrop => l10n.donateTinyDropText,
    cyberMug => l10n.donateCyberMugText,
    doubleShot => l10n.donateDoubleShotText,
    zeroKnowledgeNitro => l10n.donateZeroKnowledgeNitroText,
    directIv => l10n.donateDirectIvText,
    rocketBoost => l10n.donateRocketBoostText,
    customBrew => l10n.donateCustomBrewText,
  };

  /// The mascot of [usd] dollars: the biggest tier it pays for.
  static PivxDonationTier artFor(Decimal usd) => fixed.lastWhere(
    (t) => Decimal.fromInt(t.usd!) <= usd,
    orElse: () => tinyDrop,
  );

  /// The tier's picture: hooded when paid from the shielded balance,
  /// translucent from the transparent one. The custom brew has none of
  /// its own (see [artFor]).
  String art({required bool shielded}) =>
      Assets.donation.tier(usd ?? 1, shielded: shielded);
}

/// Custom amounts with a surprise.
enum PivxDonationEgg {
  /// Under a dollar.
  tapWater,

  /// Exactly $4.04.
  coffeeNotFound,

  /// $250 and up.
  madman;

  static PivxDonationEgg? of(Decimal usd) {
    if (usd <= Decimal.zero) return null;
    if (usd < Decimal.one) return tapWater;
    if ((usd * Decimal.fromInt(100)).round() == Decimal.fromInt(404)) {
      return coffeeNotFound;
    }
    if (usd >= Decimal.fromInt(250)) return madman;
    return null;
  }

  String get text => switch (this) {
    tapWater => l10n.donateEggTapWater,
    coffeeNotFound => l10n.donateEggCoffeeNotFound,
    madman => l10n.donateEggMadman,
  };
}

/// [usd] dollars in PIV at [price] dollars a PIV, rounded to three
/// significant digits (whole PIV from 100 up): 65.4 rather than 65.3594.
Decimal pivxDonationPiv(Decimal usd, Decimal price) {
  if (usd <= Decimal.zero || price <= Decimal.zero) return Decimal.zero;
  final exact = (usd / price).toDecimal(scaleOnInfinitePrecision: 12);
  var scale = 3 - exact.toBigInt().toString().length;
  if (exact < Decimal.one) {
    // Two more digits after the first one that isn't zero.
    var v = exact;
    scale = 2;
    while (v < Decimal.one && scale < 8) {
      v = v * Decimal.ten;
      scale++;
    }
  }
  return exact.round(scale: scale.clamp(0, 8));
}

/// [usd] for people: "$20", "$12.34" (in the locale's way).
String pivxDonationUsdText(Decimal usd, String locale) =>
    NumberFormat.simpleCurrency(
      locale: _intlLocale(locale),
      name: "USD",
      decimalDigits: usd.isInteger ? 0 : 2,
    ).format(usd.toDouble());

/// [piv] for people, as many decimals as it has: "65.4 PIV".
String pivxDonationPivText(Decimal piv, String ticker, String locale) {
  final number = NumberFormat("#,##0.########", _intlLocale(locale));
  return "${number.format(piv.toDouble())} $ticker";
}

String _intlLocale(String locale) =>
    NumberFormat.localeExists(locale) ? locale : "en_US";

/// The donation's shielded memo: a tag line in English for the developer
/// ("Fuel PIVXie: $20 · Zero-Knowledge Nitro"), then the cheers message.
/// Always within [kPivxMaxMemoBytes]: an absurd custom amount loses its
/// dollars from the tag, and only then is the message cut.
String pivxDonationMemo({
  required PivxDonationTier tier,
  Decimal? usd,
  String message = "",
}) {
  String tag(bool withUsd) {
    final dollars = withUsd && usd != null
        ? "\$${usd.isInteger ? usd : usd.toStringAsFixed(2)} · "
        : "";
    return "Fuel PIVXie: $dollars${tier.memoName}";
  }

  final text = message.trim();
  if (text.isEmpty) return tag(true);
  var memo = "${tag(true)}\n$text";
  if (utf8Length(memo) > kPivxMaxMemoBytes) memo = "${tag(false)}\n$text";
  return truncateUtf8(memo, kPivxMaxMemoBytes);
}

/// The donation: [amount] to [address] (the name's shield address) with
/// [memo], paid as [funding] says. The fee comes on top.
Future<TxData> preparePivxDonation(
  PivxWallet wallet, {
  required String address,
  required Amount amount,
  required String memo,
  required String note,
  required PivxFunding funding,
}) => wallet.prepareSend(
  txData: TxData(
    note: note,
    noteOnChain: "",
    memo: memo,
    recipients: [
      TxRecipient(
        address: address,
        amount: amount,
        isChange: false,
        addressType: AddressType.pivxShield,
      ),
    ],
    utxos: pivxFundingInputs(funding),
    otherData: jsonEncode(pivxFundingOtherData(funding)),
  ),
);

({Decimal value, DateTime at})? _usdPrice;

/// PIVX's price in US dollars from CoinGecko, under the rules of the
/// app's prices (only with external calls on; through Tor when Tor is
/// on). Null when it isn't known. Asked at most once a minute.
Future<Decimal?> pivxUsdPrice({HTTP client = const HTTP()}) async {
  final last = _usdPrice;
  if (last != null &&
      DateTime.now().difference(last.at) < const Duration(minutes: 1)) {
    return last.value;
  }
  if (!Prefs.instance.externalCalls ||
      !(await Prefs.instance.isExternalCallsSet())) {
    return null;
  }
  try {
    final response = await client.get(
      url: Uri.parse(
        "https://api.coingecko.com/api/v3/simple/price"
        "?ids=pivx&vs_currencies=usd",
      ),
      headers: {'Content-Type': 'application/json'},
      proxyInfo: !AppConfig.hasFeature(AppFeature.tor)
          ? null
          : Prefs.instance.useTor
          ? TorService.sharedInstance.getProxyInfo()
          : null,
    );
    final json = jsonDecode(response.body) as Map;
    final value = Decimal.parse("${(json["pivx"] as Map)["usd"]}");
    if (value <= Decimal.zero) return last?.value;
    _usdPrice = (value: value, at: DateTime.now());
    return value;
  } catch (e, s) {
    Logging.instance.w("PIVX price in USD", error: e, stackTrace: s);
    return last?.value;
  }
}
