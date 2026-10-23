import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:paymint/pages/pivx_donation/pivx_donation.dart';
import 'package:paymint/widgets/pivx_memo_field.dart';

Decimal _d(String s) => Decimal.parse(s);

void main() {
  group("pivxDonationPiv", () {
    final price = _d("0.306");

    test("three significant digits", () {
      expect(pivxDonationPiv(_d("1"), price), _d("3.27"));
      expect(pivxDonationPiv(_d("20"), price), _d("65.4"));
    });

    test("whole PIV from 100 up", () {
      expect(pivxDonationPiv(_d("100"), price), _d("327"));
      expect(pivxDonationPiv(_d("1000"), price), _d("3268"));
    });

    test("below 1 PIV, two digits after the first that isn't zero", () {
      expect(pivxDonationPiv(_d("0.01"), _d("0.327")), _d("0.0306"));
      expect(pivxDonationPiv(_d("0.1"), _d("0.2")), _d("0.5"));
    });

    test("nothing for nothing", () {
      expect(pivxDonationPiv(Decimal.zero, price), Decimal.zero);
      expect(pivxDonationPiv(_d("5"), Decimal.zero), Decimal.zero);
    });
  });

  test("the surprises", () {
    expect(PivxDonationEgg.of(Decimal.zero), null);
    expect(PivxDonationEgg.of(_d("0.5")), PivxDonationEgg.tapWater);
    expect(PivxDonationEgg.of(_d("1")), null);
    expect(PivxDonationEgg.of(_d("4.04")), PivxDonationEgg.coffeeNotFound);
    expect(PivxDonationEgg.of(_d("4.05")), null);
    expect(PivxDonationEgg.of(_d("249.99")), null);
    expect(PivxDonationEgg.of(_d("250")), PivxDonationEgg.madman);
  });

  test("a custom amount gets the biggest tier it pays for", () {
    expect(PivxDonationTier.artFor(_d("0.5")), PivxDonationTier.tinyDrop);
    expect(PivxDonationTier.artFor(_d("1")), PivxDonationTier.tinyDrop);
    expect(PivxDonationTier.artFor(_d("7")), PivxDonationTier.cyberMug);
    expect(
      PivxDonationTier.artFor(_d("20")),
      PivxDonationTier.zeroKnowledgeNitro,
    );
    expect(PivxDonationTier.artFor(_d("99.99")), PivxDonationTier.directIv);
    expect(PivxDonationTier.artFor(_d("1000")), PivxDonationTier.moonBoost);
  });

  test("dollars", () {
    expect(pivxDonationUsdText(_d("20"), "en"), r"$20");
    expect(pivxDonationUsdText(_d("12.5"), "en"), r"$12.50");
    expect(pivxDonationUsdText(_d("1234"), "xx"), r"$1,234");
  });

  group("pivxDonationMemo", () {
    test("a tag line for the developer", () {
      expect(
        pivxDonationMemo(
          tier: PivxDonationTier.zeroKnowledgeNitro,
          usd: _d("20"),
        ),
        r"Fuel PIVXie: $20 · Zero-Knowledge Nitro",
      );
      expect(
        pivxDonationMemo(tier: PivxDonationTier.customBrew, usd: _d("12.5")),
        r"Fuel PIVXie: $12.50 · The Custom Brew",
      );
      expect(
        pivxDonationMemo(tier: PivxDonationTier.customBrew),
        "Fuel PIVXie: The Custom Brew",
      );
    });

    test("then the cheers message, trimmed", () {
      expect(
        pivxDonationMemo(
          tier: PivxDonationTier.cyberMug,
          usd: _d("5"),
          message: "  Great work! 🚀\n",
        ),
        "Fuel PIVXie: \$5 · Cyber Mug\nGreat work! 🚀",
      );
      expect(
        pivxDonationMemo(
          tier: PivxDonationTier.cyberMug,
          usd: _d("5"),
          message: "   ",
        ),
        r"Fuel PIVXie: $5 · Cyber Mug",
      );
    });

    test("a full cheers message fits with the longest tag", () {
      final message = "😀" * (kPivxDonationMessageBytes ~/ 4);
      final memo = pivxDonationMemo(
        tier: PivxDonationTier.customBrew,
        usd: _d("999999999999.99"),
        message: message,
      );
      expect(
        memo,
        "Fuel PIVXie: \$999999999999.99 · The Custom Brew\n$message",
      );
      expect(utf8Length(memo), lessThanOrEqualTo(kPivxMaxMemoBytes));
    });

    test("too long: the dollars go, then the message is cut", () {
      final ascii = pivxDonationMemo(
        tier: PivxDonationTier.cyberMug,
        usd: _d("5"),
        message: "a" * 500,
      );
      expect(ascii, "Fuel PIVXie: Cyber Mug\n${"a" * 489}");
      expect(utf8Length(ascii), kPivxMaxMemoBytes);

      final emoji = pivxDonationMemo(
        tier: PivxDonationTier.cyberMug,
        usd: _d("5"),
        message: "😀" * 130,
      );
      // 23 bytes of tag leave 489: 122 whole emoji.
      expect(emoji, "Fuel PIVXie: Cyber Mug\n${"😀" * 122}");
      expect(utf8Length(emoji), lessThanOrEqualTo(kPivxMaxMemoBytes));
    });
  });
}
