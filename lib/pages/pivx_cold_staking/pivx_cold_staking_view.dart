import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/isar/models/isar_models.dart';
import '../../providers/global/wallets_provider.dart';
import '../../route_generator.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/amount/amount.dart';
import '../../utilities/amount/amount_formatter.dart';
import '../../utilities/block_explorers.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/isar/providers/wallet_info_provider.dart';
import '../../wallets/models/tx_data.dart';
import '../../wallets/wallet/impl/pivx_wallet.dart';
import '../../widgets/background.dart';
import '../../widgets/custom_buttons/blue_text_button.dart';
import '../../widgets/desktop/primary_button.dart';
import '../../widgets/middle_ellipsis_text.dart';
import '../../widgets/page_app_bar.dart';
import '../../widgets/rounded_white_container.dart';
import '../pivx_governance/pivx_governance_widgets.dart';
import '../pivx_masternodes/pivx_masternodes_view.dart';
import '../send_view/confirm_transaction_view.dart';
import '../send_view/sub_widgets/building_transaction_dialog.dart';
import '../send_view/sub_widgets/pivx_funding_card.dart';
import 'pivx_delegate_view.dart';
import '../../widgets/desktop/desktop_page_column.dart';

/// Coins this wallet delegated to a cold staker, from the wallet's menu.
/// The wallet is only ever the owner (delegator).
class PivxColdStakingView extends ConsumerStatefulWidget {
  const PivxColdStakingView({super.key, required this.walletId});

  static const routeName = "/pivxColdStaking";

  final String walletId;

  @override
  ConsumerState<PivxColdStakingView> createState() =>
      _PivxColdStakingViewState();
}

class _PivxColdStakingViewState extends ConsumerState<PivxColdStakingView> {
  StreamSubscription<List<UTXO>>? _sub;
  List<PivxDelegation>? _delegations;

  /// Rewards received so far, per owner address.
  Future<Map<String, ({BigInt amount, int stakes})>>? _rewards;

  /// The reward part of outputs a stake created, by "txid:vout".
  Map<String, BigInt> _shares = const {};

  PivxWallet get _wallet =>
      ref.read(pWallets).getWallet(widget.walletId) as PivxWallet;

  @override
  void initState() {
    super.initState();
    final wallet = _wallet;
    // Regtest or testnet decides the staking depth.
    wallet.loadMasternodeNetwork().then((_) {
      if (mounted) setState(() {});
    });
    // New rewards and delegations show up as the wallet syncs.
    _sub = wallet.watchUtxoRows().listen((rows) {
      if (!mounted) return;
      final delegations = wallet.delegationsOf(rows);
      setState(() {
        _delegations = delegations;
        _rewards = wallet.coldStakeRewardsByOwner();
      });
      wallet.coldStakeRewardShares(delegations).then((shares) {
        if (mounted) setState(() => _shares = shares);
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _delegate() =>
      Navigator.of(context)
          .pushNamed(PivxDelegateView.routeName, arguments: widget.walletId);

  /// "36 tPIV from 9 stakes".
  String _rewardsFrom(({BigInt amount, int stakes}) r, AmountFormatter fmt) =>
      "${fmt.format(Amount(rawValue: r.amount, fractionDigits: _wallet.cryptoCurrency.fractionDigits))}"
      " from ${r.stakes} ${r.stakes == 1 ? "stake" : "stakes"}";

  String _rewardsSoFar(
    Iterable<({BigInt amount, int stakes})> perOwner,
    AmountFormatter fmt,
  ) =>
      "Rewards so far: ${_rewardsFrom((amount: perOwner.fold(BigInt.zero, (p, r) => p + r.amount), stakes: perOwner.fold(0, (p, r) => p + r.stakes)), fmt)}";

  /// The reward part of [d] (an output a stake created), formatted.
  String? _rewardText(PivxDelegation d, AmountFormatter fmt) {
    final share = _shares["${d.utxo.txid}:${d.utxo.vout}"];
    if (!d.isReward || share == null) return null;
    return fmt.format(
      Amount(
        rawValue: share,
        fractionDigits: _wallet.cryptoCurrency.fractionDigits,
      ),
    );
  }

  bool _canWithdraw(PivxDelegation d, int height) => d.utxo.isConfirmed(
    height,
    _wallet.cryptoCurrency.minConfirms,
    _wallet.cryptoCurrency.minCoinbaseConfirms,
  );

  Future<void> _withdraw(List<PivxDelegation> delegations) async {
    final wallet = _wallet;
    final txData = await showBuildingTransaction<TxData>(
      context: context,
      coin: wallet.cryptoCurrency,
      build: () => wallet.prepareWithdrawal(delegations),
    );
    if (!mounted || txData == null) return;
    await Navigator.of(context).push(
      RouteGenerator.getRoute<void>(
        shouldUseMaterialRoute: RouteGenerator.useMaterialPageRoute,
        builder: (_) => DesktopPageColumn(
          card: true,
          child: ConfirmTransactionView(
            txData: txData,
            walletId: widget.walletId,
            onSuccess: () {},
            onSuccessInsteadOfRouteOnSuccess: () {
              if (mounted) {
                Navigator.of(
                  context,
                ).popUntil(ModalRoute.withName(PivxColdStakingView.routeName));
              }
            },
          ),
        ),
        settings: const RouteSettings(name: ConfirmTransactionView.routeName),
      ),
    );
  }

  /// Delegated or staking, or how long until it stakes.
  String _status(PivxDelegation d, int height) {
    final confirmations = d.utxo.getConfirmations(height);
    if (confirmations <= 0) return "Waiting for confirmation";
    final left = _wallet.coldStakeMinDepth - confirmations;
    if (left > 0) {
      return "Starts staking in ~"
          "${pivxDuration(left * _wallet.cryptoCurrency.targetBlockTimeSeconds)}";
    }
    return "Staking";
  }

  Future<void> _showInfo() => showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => _Sheet(
      title: "How cold staking works",
      children: [
        Text(
          "Your coins earn staking rewards while they stay in this wallet. "
          "A staker, a PIVX node that is always online, stakes them for "
          "you, but it can never spend or move them. Rewards are added to "
          "your delegated coins.",
          style: STextStyles.itemSubtitle(context),
        ),
        const SizedBox(height: 12),
        Text(
          "To take coins out of cold staking, just spend them. Tap an "
          "output and choose Withdraw, and the coins return to your "
          "regular balance.",
          style: STextStyles.itemSubtitle(context),
        ),
        const SizedBox(height: 12),
        Text(
          "Delegated coins are frozen, so a normal send never uses them by "
          "accident.",
          style: STextStyles.itemSubtitle(context),
        ),
        const SizedBox(height: 12),
        Text(
          "Delegated coins sit at an owner address of this wallet. A staker "
          "only stakes coins whose owner address it has on its whitelist, "
          "so give it every owner address you delegate from. The list "
          "groups your delegations by owner address.",
          style: STextStyles.itemSubtitle(context),
        ),
      ],
    ),
  );

  Future<void> _showDelegation(PivxDelegation d) {
    final wallet = _wallet;
    final coin = wallet.cryptoCurrency;
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => Consumer(
        builder: (context, ref, _) {
          final fmt = ref.watch(pAmountFormatter(coin));
          final height = ref.watch(pWalletChainHeight(widget.walletId));
          final canWithdraw = _canWithdraw(d, height);
          final maturity =
              coin.minCoinbaseConfirms - d.utxo.getConfirmations(height);
          return _Sheet(
            title: fmt.format(
              Amount(
                rawValue: BigInt.from(d.utxo.value),
                fractionDigits: coin.fractionDigits,
              ),
            ),
            subtitle: _rewardText(d, fmt) == null
                ? _status(d, height)
                : "Includes ${_rewardText(d, fmt)} from its latest stake; "
                      "earlier rewards are part of the amount · "
                      "${_status(d, height)}",
            children: [
              PivxCopyRow(title: "Staker", value: d.staker),
              PivxCopyRow(title: "Owner (your address)", value: d.owner),
              PivxCopyRow(
                title: "Transaction",
                value: d.utxo.txid,
                openTooltip: "Open in the block explorer",
                onOpen: () => launchUrl(
                  getBlockExplorerTransactionUrlFor(
                    coin: coin,
                    txid: d.utxo.txid,
                  ),
                  mode: LaunchMode.externalApplication,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                !canWithdraw && d.isReward && maturity > 0
                    ? "New rewards can be spent after "
                          "${coin.minCoinbaseConfirms} confirmations, in ~"
                          "${pivxDuration(maturity * coin.targetBlockTimeSeconds)}."
                    : "Withdrawing ends cold staking for these coins and "
                          "moves them back to your regular balance. The "
                          "network fee comes out of the amount.",
                style: STextStyles.itemSubtitle(context),
              ),
              const SizedBox(height: 16),
              PrimaryButton(
                label: "Withdraw",
                enabled: canWithdraw && !wallet.isViewOnly,
                onPressed: () {
                  Navigator.of(context).pop();
                  _withdraw([d]);
                },
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final wallet = _wallet;
    final coin = wallet.cryptoCurrency;
    final fmt = ref.watch(pAmountFormatter(coin));
    final height = ref.watch(pWalletChainHeight(widget.walletId));
    final delegations = _delegations;
    final withdrawable = [
      for (final d in delegations ?? const <PivxDelegation>[])
        if (_canWithdraw(d, height)) d,
    ];
    final total = Amount(
      rawValue: (delegations ?? const <PivxDelegation>[]).fold(
        BigInt.zero,
        (p, d) => p + BigInt.from(d.utxo.value),
      ),
      fractionDigits: coin.fractionDigits,
    );
    final secondary = STextStyles.w500_12(context)
        .copyWith(color: colors.textSubtitle1);

    return Background(
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: PageAppBar(
          title: Text("Cold staking", style: STextStyles.navBarTitle(context)),
          actions: [
            IconButton(
              tooltip: "How cold staking works",
              onPressed: _showInfo,
              icon: Icon(
                Icons.info_outline_rounded,
                color: colors.topNavIconPrimary,
              ),
            ),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: delegations == null
                ? const Center(child: CircularProgressIndicator())
                : delegations.isEmpty
                ? _Empty(
                    onStart: wallet.isViewOnly ? null : _delegate,
                    onInfo: _showInfo,
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: ListView(
                          children: [
                            RoundedWhiteContainer(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text("Delegated", style: secondary),
                                  const SizedBox(height: 4),
                                  Text(
                                    fmt.format(total),
                                    style: STextStyles.pageTitleH2(context),
                                  ),
                                  const SizedBox(height: 4),
                                  FutureBuilder<
                                    Map<String, ({BigInt amount, int stakes})>
                                  >(
                                    future: _rewards,
                                    builder: (context, snap) => Text(
                                      snap.hasData
                                          ? _rewardsSoFar(
                                              snap.data!.values,
                                              fmt,
                                            )
                                          : " ",
                                      style: STextStyles.w500_12(context)
                                          .copyWith(
                                            color: colors.accentColorGreen,
                                          ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 16),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    "Delegated outputs",
                                    style: STextStyles.smallMed12(context),
                                  ),
                                ),
                                if (withdrawable.length > 1 &&
                                    !wallet.isViewOnly)
                                  CustomTextButton(
                                    text: "Withdraw all",
                                    onTap: () => _withdraw(withdrawable),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            for (final owner in {
                              for (final d in delegations) d.owner,
                            }) ...[
                              FutureBuilder<
                                Map<String, ({BigInt amount, int stakes})>
                              >(
                                future: _rewards,
                                builder: (context, snap) => _OwnerHeader(
                                  walletId: widget.walletId,
                                  owner: owner,
                                  delegated: fmt.format(
                                    Amount(
                                      rawValue: delegations
                                          .where((d) => d.owner == owner)
                                          .fold(
                                            BigInt.zero,
                                            (p, d) =>
                                                p + BigInt.from(d.utxo.value),
                                          ),
                                      fractionDigits: coin.fractionDigits,
                                    ),
                                  ),
                                  rewards: snap.data?[owner] == null
                                      ? null
                                      : _rewardsFrom(snap.data![owner]!, fmt),
                                ),
                              ),
                              const SizedBox(height: 8),
                              for (final d in delegations.where(
                                (d) => d.owner == owner,
                              )) ...[
                                _DelegationRow(
                                  delegation: d,
                                  amount: fmt.format(
                                    Amount(
                                      rawValue: BigInt.from(d.utxo.value),
                                      fractionDigits: coin.fractionDigits,
                                    ),
                                  ),
                                  reward: _rewardText(d, fmt),
                                  status: _status(d, height),
                                  onTap: () => _showDelegation(d),
                                ),
                                const SizedBox(height: 8),
                              ],
                              const SizedBox(height: 8),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      PrimaryButton(
                        label: "Delegate more",
                        enabled: !wallet.isViewOnly,
                        onPressed: _delegate,
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onStart, required this.onInfo});

  final VoidCallback? onStart;
  final VoidCallback onInfo;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            children: [
              const SizedBox(height: 40),
              Center(
                child: PivxColdStakingIcon(
                  color: colors.accentColorBlue,
                  size: 56,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                "Earn rewards with your PIV",
                textAlign: TextAlign.center,
                style: STextStyles.pageTitleH2(context),
              ),
              const SizedBox(height: 8),
              Text(
                "Delegate coins to a staker and earn staking rewards without "
                "keeping a PIVX Core wallet online on your PC or server. Your "
                "coins never leave your wallet, and you can take them back "
                "at any time.",
                textAlign: TextAlign.center,
                style: STextStyles.itemSubtitle(context),
              ),
              const SizedBox(height: 8),
              Center(
                child: CustomTextButton(text: "How it works", onTap: onInfo),
              ),
            ],
          ),
        ),
        PrimaryButton(
          label: "Start cold staking",
          enabled: onStart != null,
          onPressed: onStart,
        ),
      ],
    );
  }
}

class _DelegationRow extends StatelessWidget {
  const _DelegationRow({
    required this.delegation,
    required this.amount,
    required this.reward,
    required this.status,
    required this.onTap,
  });

  final PivxDelegation delegation;
  final String amount;

  /// The reward part of [amount], for an output a stake created.
  final String? reward;
  final String status;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final secondary = STextStyles.w500_12(context)
        .copyWith(color: colors.textSubtitle1);
    return RoundedWhiteContainer(
      padding: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              PivxColdStakingIcon(
                color: delegation.isReward
                    ? colors.accentColorGreen
                    : colors.accentColorBlue,
                size: 18,
                reward: delegation.isReward,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // The pill moves under the amount when both don't fit
                    // (e.g. a split stake of 500.66666667 PIV on a phone).
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(amount, style: STextStyles.w600_14(context)),
                        if (delegation.isReward)
                          PivxPill(
                            text: reward == null
                                ? "Reward"
                                : "+$reward latest stake",
                            color: colors.accentColorGreen,
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    MiddleEllipsisText(
                      "Staker ${delegation.staker}",
                      style: secondary,
                    ),
                    const SizedBox(height: 2),
                    Text(status, style: secondary),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: colors.textSubtitle1),
            ],
          ),
        ),
      ),
    );
  }
}

/// Snowflake in a tinted circle; a reward gets a "+" badge.
class PivxColdStakingIcon extends StatelessWidget {
  const PivxColdStakingIcon({
    super.key,
    required this.color,
    required this.size,
    this.reward = false,
  });

  final Color color;
  final double size;
  final bool reward;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.all(size * 0.36),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.15),
      shape: BoxShape.circle,
    ),
    child: Icon(
      reward ? Icons.add_rounded : Icons.ac_unit_rounded,
      size: size,
      color: color,
    ),
  );
}

/// Bottom sheet with a title and content.
class _Sheet extends StatelessWidget {
  const _Sheet({required this.title, this.subtitle, required this.children});

  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return Container(
      decoration: BoxDecoration(
        color: colors.popupBG,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: STextStyles.pageTitleH2(context)),
              if (subtitle != null) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle!,
                  style: STextStyles.w500_12(context)
                      .copyWith(color: colors.textSubtitle1),
                ),
              ],
              const SizedBox(height: 12),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

/// An owner address with what it has delegated and earned; tap to copy
/// it (e.g. for the staker's whitelist).
class _OwnerHeader extends StatelessWidget {
  const _OwnerHeader({
    required this.walletId,
    required this.owner,
    required this.delegated,
    required this.rewards,
  });

  final String walletId;
  final String owner;
  final String delegated;
  final String? rewards;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final secondary = STextStyles.w500_12(context)
        .copyWith(color: colors.textSubtitle1);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: PivxCopyRow(
        title: "Owner · ${pivxAddressTitle(walletId, owner)}",
        value: owner,
        footer: Text(
          rewards == null
              ? "$delegated delegated"
              : "$delegated delegated · rewards: $rewards",
          style: secondary,
        ),
      ),
    );
  }
}
