import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/global/wallets_provider.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/amount/amount.dart';
import '../../utilities/amount/amount_formatter.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/wallet/impl/pivx_wallet.dart';
import '../../widgets/background.dart';
import '../../widgets/custom_buttons/app_bar_icon_button.dart';
import '../../widgets/desktop/primary_button.dart';
import '../../widgets/desktop/secondary_button.dart';
import '../../widgets/rounded_white_container.dart';
import 'pivx_create_masternode_view.dart';
import 'pivx_masternode_details_view.dart';

/// The wallet's PIVX masternodes, from the wallet's "More" menu.
class PivxMasternodesView extends ConsumerStatefulWidget {
  const PivxMasternodesView({super.key, required this.walletId});

  static const routeName = "/pivxMasternodes";

  final String walletId;

  @override
  ConsumerState<PivxMasternodesView> createState() =>
      _PivxMasternodesViewState();
}

/// What a card shows besides the stored masternode.
typedef PivxMasternodeCardData = ({
  PivxMasternodeNetworkInfo info,
  Amount earned,
});

class _PivxMasternodesViewState extends ConsumerState<PivxMasternodesView> {
  /// Network data per masternode id, refetched on pull to refresh.
  Map<String, Future<PivxMasternodeCardData>> _data = {};

  PivxWallet get _wallet =>
      ref.read(pWallets).getWallet(widget.walletId) as PivxWallet;

  @override
  void initState() {
    _reload();
    _wallet.loadMasternodeNetwork().then((_) {
      if (mounted) setState(() {});
    });
    super.initState();
  }

  void _reload() {
    final wallet = _wallet;
    _data = {
      for (final mn in wallet.masternodes)
        mn.id: () async {
          final results = await Future.wait([
            wallet.masternodeNetworkInfo(mn),
            wallet.masternodeEarned(mn),
          ]);
          return (
            info: results[0] as PivxMasternodeNetworkInfo,
            earned: results[1] as Amount,
          );
        }(),
    };
  }

  Future<void> _refresh() async {
    setState(_reload);
    await Future.wait(_data.values);
  }

  Future<void> _open(String route, Object arguments) async {
    await Navigator.of(context).pushNamed(route, arguments: arguments);
    if (mounted) setState(_reload);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final masternodes = _wallet.masternodes;

    return Background(
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: AppBar(
          leading: AppBarBackButton(
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Text("Masternodes", style: STextStyles.navBarTitle(context)),
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: masternodes.isEmpty
                      ? _Empty(wallet: _wallet)
                      : RefreshIndicator(
                          onRefresh: _refresh,
                          child: ListView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            children: [
                              PivxMasternodesSummary(
                                wallet: _wallet,
                                masternodes: masternodes,
                                data: _data,
                              ),
                              for (final mn in masternodes) ...[
                                const SizedBox(height: 12),
                                PivxMasternodeCard(
                                  wallet: _wallet,
                                  masternode: mn,
                                  data: _data[mn.id],
                                  onTap: () => _open(
                                    PivxMasternodeDetailsView.routeName,
                                    (walletId: widget.walletId, id: mn.id),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                ),
                const SizedBox(height: 12),
                PrimaryButton(
                  label: "Create masternode",
                  onPressed: () => _open(
                    PivxCreateMasternodeView.routeName,
                    widget.walletId,
                  ),
                ),
                const SizedBox(height: 8),
                SecondaryButton(
                  label: "Add existing masternode",
                  onPressed: () => _open(PivxCreateMasternodeView.routeName, (
                    walletId: widget.walletId,
                    existing: true,
                  )),
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
  const _Empty({required this.wallet});

  final PivxWallet wallet;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    return ListView(
      children: [
        const SizedBox(height: 40),
        Center(child: _MasternodeIcon(color: colors.textSubtitle1, size: 56)),
        const SizedBox(height: 24),
        Text(
          "No masternodes yet",
          textAlign: TextAlign.center,
          style: STextStyles.pageTitleH2(context),
        ),
        const SizedBox(height: 8),
        Text(
          "A masternode locks a collateral of "
          "${wallet.masternodeCollateral.decimal} "
          "${wallet.cryptoCurrency.ticker} in this wallet and earns rewards "
          "while a server runs it. The collateral stays yours and is "
          "frozen so it can't be spent by accident.",
          textAlign: TextAlign.center,
          style: STextStyles.itemSubtitle(context),
        ),
      ],
    );
  }
}

/// Count, enabled ones and rewards earned by all masternodes.
class PivxMasternodesSummary extends ConsumerWidget {
  const PivxMasternodesSummary({
    required this.wallet,
    required this.masternodes,
    required this.data,
  });

  final PivxWallet wallet;
  final List<PivxMasternode> masternodes;
  final Map<String, Future<PivxMasternodeCardData>> data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final fmt = ref.watch(pAmountFormatter(wallet.cryptoCurrency));
    return FutureBuilder<List<PivxMasternodeCardData>>(
      future: Future.wait([for (final mn in masternodes) data[mn.id]!]),
      builder: (context, snapshot) {
        final loaded = snapshot.data;
        final enabled = loaded?.where((e) => e.info.status == "ENABLED").length;
        // Masternodes sharing a collateral address share its rewards.
        final earned = loaded == null
            ? null
            : {
                for (int i = 0; i < masternodes.length; i++)
                  masternodes[i].address: loaded[i].earned,
              }.values.fold(
                Amount.zeroWith(
                  fractionDigits: wallet.cryptoCurrency.fractionDigits,
                ),
                (p, e) => p + e,
              );

        Widget stat(String label, String value) => Expanded(
          child: Column(
            children: [
              Text(
                value,
                textAlign: TextAlign.center,
                style: STextStyles.w600_16(context),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: STextStyles.w500_12(
                  context,
                ).copyWith(color: colors.textSubtitle1),
              ),
            ],
          ),
        );

        return RoundedWhiteContainer(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
          child: Row(
            children: [
              stat("Masternodes", "${masternodes.length}"),
              stat("Enabled", enabled == null ? "…" : "$enabled"),
              stat("Earned", earned == null ? "…" : fmt.format(earned)),
            ],
          ),
        );
      },
    );
  }
}

class PivxMasternodeCard extends ConsumerWidget {
  const PivxMasternodeCard({
    required this.wallet,
    required this.masternode,
    required this.data,
    required this.onTap,
  });

  final PivxWallet wallet;
  final PivxMasternode masternode;
  final Future<PivxMasternodeCardData>? data;
  final VoidCallback onTap;

  static int _now() => DateTime.timestamp().millisecondsSinceEpoch ~/ 1000;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final fmt = ref.watch(pAmountFormatter(wallet.cryptoCurrency));
    final mn = masternode;

    return FutureBuilder<PivxMasternodeCardData>(
      future: data,
      builder: (context, snapshot) {
        final d = snapshot.data;
        final info = d?.info;
        final status = info?.status ?? "…";

        Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            children: [
              Text(
                label,
                style: STextStyles.w500_12(
                  context,
                ).copyWith(color: colors.textSubtitle1),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  value,
                  textAlign: TextAlign.right,
                  overflow: TextOverflow.ellipsis,
                  style: STextStyles.w500_12(
                    context,
                  ).copyWith(color: colors.textDark),
                ),
              ),
            ],
          ),
        );

        return GestureDetector(
          onTap: onTap,
          child: RoundedWhiteContainer(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            mn.label.isEmpty ? "Masternode" : mn.label,
                            style: STextStyles.w600_16(context),
                          ),
                          const SizedBox(height: 6),
                          PivxMasternodeStatusPill(status: status),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    _MasternodeIcon(
                      color: pivxMasternodeStatusColor(status, colors),
                      size: 28,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Divider(height: 16, color: colors.backgroundAppBar),
                row("Server", mn.service ?? "Not set"),
                row(
                  "Collateral",
                  "${fmt.format(wallet.masternodeCollateral)} · "
                      "${mn.txid.substring(0, 8)}…:${mn.vout}",
                ),
                if (info != null && info.activeSeconds > 0)
                  row("Active for", pivxDuration(info.activeSeconds)),
                if (info != null &&
                    info.status != "MISSING" &&
                    info.status != "UNKNOWN")
                  row(
                    "Last paid",
                    info.lastPaid > 0
                        ? "${pivxDuration(_now() - info.lastPaid)} ago"
                        : "Not yet",
                  ),
                if (d != null) row("Earned", fmt.format(d.earned)),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The masternode (server) icon on a tinted round tile.
class _MasternodeIcon extends StatelessWidget {
  const _MasternodeIcon({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.all(size * 0.36),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.15),
      shape: BoxShape.circle,
    ),
    child: Icon(Icons.dns_rounded, size: size, color: color),
  );
}

/// "3 d 4 h", "2 h 15 min", "12 min", "40 s".
String pivxDuration(int seconds) {
  if (seconds < 60) return "${seconds.clamp(0, 59)} s";
  final m = seconds ~/ 60, h = m ~/ 60, d = h ~/ 24;
  if (d > 0) return h % 24 > 0 ? "$d d ${h % 24} h" : "$d d";
  if (h > 0) return m % 60 > 0 ? "$h h ${m % 60} min" : "$h h";
  return "$m min";
}

Color pivxMasternodeStatusColor(String status, StackColors colors) {
  final color = switch (status) {
    "ENABLED" => colors.accentColorGreen,
    "PRE_ENABLED" => colors.accentColorYellow,
    "…" || "UNKNOWN" => colors.textSubtitle1,
    "MISSING" => colors.accentColorOrange,
    _ => colors.accentColorRed,
  };
  if (colors.brightness == Brightness.dark) return color;
  // Light themes: deepen light accents (yellow) so text stays readable.
  final hsl = HSLColor.fromColor(color);
  return hsl.lightness > 0.45 ? hsl.withLightness(0.42).toColor() : color;
}

String _statusText(String status) => switch (status) {
  "…" => "Checking…",
  "MISSING" => "Not started",
  "UNKNOWN" => "Unknown",
  _ => status[0] + status.substring(1).toLowerCase().replaceAll("_", "-"),
};

/// Masternode status as a coloured pill.
class PivxMasternodeStatusPill extends StatelessWidget {
  const PivxMasternodeStatusPill({super.key, required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final color = pivxMasternodeStatusColor(status, colors);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(100),
      ),
      child: Text(
        _statusText(status),
        style: STextStyles.w600_12(context).copyWith(color: color),
      ),
    );
  }
}

/// Masternode status from the network, as a [PivxMasternodeStatusPill].
class PivxMasternodeStatusTag extends StatelessWidget {
  const PivxMasternodeStatusTag({
    super.key,
    required this.wallet,
    required this.masternode,
  });

  final PivxWallet wallet;
  final PivxMasternode masternode;

  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
    future: wallet.masternodeStatus(masternode),
    builder: (context, snapshot) =>
        PivxMasternodeStatusPill(status: snapshot.data ?? "…"),
  );
}
