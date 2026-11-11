import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../providers/global/wallets_provider.dart';
import '../../services/pivx_defi/pivx_defi_api.dart';
import '../../services/pivx_defi/pivx_defi_models.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/text_styles.dart';
import '../../wallets/wallet/impl/pivx_wallet.dart';
import '../../widgets/adaptive_page.dart';
import '../../widgets/background.dart';
import '../../widgets/rounded_white_container.dart';
import 'pivx_defi_common.dart';
import 'pivx_defi_order_view.dart';

/// The DeFi Bridge orders made from this wallet, newest first (the web
/// app's "Recent swaps").
class PivxDefiOrdersView extends ConsumerWidget {
  const PivxDefiOrdersView({super.key, required this.walletId});

  static const routeName = kPivxDefiOrdersRoute;

  final String walletId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final wallet = ref.read(pWallets).getWallet(walletId) as PivxWallet;
    final coin = wallet.cryptoCurrency;
    final config = PivxDefiConfig.forCoin(coin)!;
    return Background(
      child: AppScaffold(
        maxBodyWidth: ScreenFit.columnWidth,
        backgroundColor: colors.background,
        appBar: PivxDefiAppBar(
          walletId: walletId,
          config: config,
          title: l10n.defiRecent,
        ),
        body: SafeArea(
          child: ValueListenableBuilder<int>(
            valueListenable: pivxDefiChanges,
            builder: (context, _, _) {
              final orders = wallet.defiOrders;
              if (orders.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      l10n.defiNoOrders,
                      textAlign: TextAlign.center,
                      style: STextStyles.itemSubtitle(context),
                    ),
                  ),
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                itemCount: orders.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, i) => _OrderTile(
                  walletId: walletId,
                  order: orders[i],
                  colors: colors,
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _OrderTile extends ConsumerWidget {
  const _OrderTile({
    required this.walletId,
    required this.order,
    required this.colors,
  });

  final String walletId;
  final PivxDefiRecentOrder order;
  final StackColors colors;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coin = ref.read(pWallets).getWallet(walletId).cryptoCurrency;
    final direction =
        PivxDefiDirection.parse(order.direction) ?? PivxDefiDirection.wrap;
    final wrap = direction == PivxDefiDirection.wrap;
    final amount = showPivxDefiAmount(order.amount);
    // Where an unwrap pays, as this wallet asked: the name, if any, and
    // its address then.
    final to = wrap ? null : order.to;
    final name = to == null ? null : order.name;
    final subtle = STextStyles.w500_12(context)
        .copyWith(color: colors.textSubtitle1);
    return RoundedWhiteContainer(
      padding: EdgeInsets.zero,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () =>
              openPivxDefiOrder(context, walletId: walletId, id: order.id),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                PivxDefiPairIcon(coin: coin, direction: direction, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        wrap
                            ? l10n.defiRecentWrap(amount)
                            : l10n.defiRecentUnwrap(amount),
                        style: STextStyles.w600_14(context),
                      ),
                      if (to != null) ...[
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            if (name != null) ...[
                              Flexible(
                                child: Text(
                                  name,
                                  overflow: TextOverflow.ellipsis,
                                  style: STextStyles.w500_12(context).copyWith(
                                    color: pivxDefiColor(direction, colors),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                            ],
                            Text(
                              pivxDefiShort(to, head: 8),
                              textDirection: TextDirection.ltr,
                              style: subtle,
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Text(
                            "#${order.id}",
                            textDirection: TextDirection.ltr,
                            style: subtle,
                          ),
                          const Spacer(),
                          Text(pivxDefiDate(order.created), style: subtle),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Icon(
                  Directionality.of(context) == TextDirection.rtl
                      ? Icons.chevron_left_rounded
                      : Icons.chevron_right_rounded,
                  color: colors.textSubtitle1,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
