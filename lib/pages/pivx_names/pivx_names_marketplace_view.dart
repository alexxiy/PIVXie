import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../providers/global/wallets_provider.dart';
import '../../services/pivx_name/pivx_names_protocol.dart';
import '../../services/pivx_name/pivx_names_registrar.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/text_styles.dart';
import '../../utilities/util.dart';
import '../../wallets/wallet/impl/pivx_wallet.dart';
import '../../widgets/background.dart';
import '../../widgets/desktop/primary_button.dart';
import '../../widgets/desktop/secondary_button.dart';
import '../../widgets/rounded_white_container.dart';
import 'pivx_names_common.dart';
import 'pivx_names_flow.dart';
import 'pivx_names_in_flight.dart';

/// Names for sale: buy one, or change the price of (or unlist) the
/// user's own listings.
class PivxNamesMarketplaceView extends ConsumerStatefulWidget {
  const PivxNamesMarketplaceView({super.key, required this.walletId});

  static const routeName = kPivxNamesMarketplaceRoute;

  final String walletId;

  @override
  ConsumerState<PivxNamesMarketplaceView> createState() =>
      _PivxNamesMarketplaceViewState();
}

class _PivxNamesMarketplaceViewState
    extends ConsumerState<PivxNamesMarketplaceView> {
  String? _key;
  int _page = 1;
  String _search = "";
  PivxNamesPage<PivxNamesDomain>? _names;
  bool _loading = true;
  String? _error;
  int _request = 0;

  PivxWallet get _wallet =>
      ref.read(pWallets).getWallet(widget.walletId) as PivxWallet;

  @override
  void initState() {
    super.initState();
    pivxNamesChanges.addListener(_changed);
    unawaited(_load());
  }

  @override
  void dispose() {
    pivxNamesChanges.removeListener(_changed);
    super.dispose();
  }

  void _changed() => unawaited(_load());

  Future<void> _load() async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // With the key, the user's own listings come marked.
      String? key = _key;
      if (key == null) {
        try {
          key = await pivxNamesPublicKey(_wallet);
          if (mounted) setState(() => _key = key);
        } catch (_) {}
      }
      final names = await PivxNamesRegistrar.forCoin(_wallet.cryptoCurrency)!
          .marketplace(pubkey: key, page: _page, search: _search);
      if (!mounted || request != _request) return;
      setState(() => _names = names);
    } catch (e) {
      if (!mounted || request != _request) return;
      setState(() => _error = l10n.pivxNamesLoadNamesFailed(pivxNamesError(e)));
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  PivxNamesFlow _flow(PivxNamesDomain d, PivxNamesOp op) => PivxNamesFlow(
    walletId: widget.walletId,
    op: op,
    name: d.name,
    price: op == PivxNamesOp.buy ? d.price : null,
    listedPrice: op == PivxNamesOp.lst ? d.price : null,
    returnTo: PivxNamesMarketplaceView.routeName,
  );

  Future<void> _buy(PivxNamesDomain d) async {
    final ok = await pivxNamesConfirm(
      context,
      title: l10n.pivxNamesBuyName,
      message: l10n.pivxNamesBuyConfirm(
        pivxNamesUnbroken(d.name),
        pivxNamesAmount(d.price, ref, _wallet),
      ),
      action: l10n.pivxNamesBuy,
    );
    if (ok && mounted) {
      await startPivxNamesFlow(context, ref, _flow(d, PivxNamesOp.buy));
    }
  }

  Future<void> _unlist(PivxNamesDomain d) async {
    final ok = await pivxNamesConfirm(
      context,
      title: l10n.pivxNamesUnlistTitle,
      message: l10n.pivxNamesUnlistConfirm(pivxNamesUnbroken(d.name)),
      action: l10n.pivxNamesUnlist,
    );
    if (ok && mounted) {
      await startPivxNamesFlow(context, ref, _flow(d, PivxNamesOp.ult));
    }
  }

  Widget _card(PivxNamesDomain d) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final own = _key != null && d.owner == _key;
    final inFlight = PivxNamesInFlight.of(widget.walletId, d.name);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: RoundedWhiteContainer(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: PivxNamesNameText(d.name)),
                const SizedBox(width: 8),
                if (own)
                  PivxNamesPill(
                    text: l10n.pivxNamesYours,
                    color: colors.accentColorBlue,
                  )
                else
                  PivxNamesZoneBadge(name: d.name),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              pivxNamesAmount(d.price, ref, _wallet),
              style: STextStyles.w600_18(context)
                  .copyWith(color: colors.accentColorBlue),
            ),
            const SizedBox(height: 10),
            if (inFlight != null)
              PivxNamesInFlightNote(tracked: inFlight)
            else if (own)
              Row(
                children: [
                  Expanded(
                    child: SecondaryButton(
                      label: l10n.pivxNamesChangePrice,
                      buttonHeight: Util.isDesktop ? ButtonHeight.m : null,
                      onPressed: () => startPivxNamesFlow(
                        context,
                        ref,
                        _flow(d, PivxNamesOp.lst),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SecondaryButton(
                      label: l10n.pivxNamesUnlist,
                      buttonHeight: Util.isDesktop ? ButtonHeight.m : null,
                      onPressed: () => _unlist(d),
                    ),
                  ),
                ],
              )
            else
              PrimaryButton(
                label: l10n.pivxNamesBuyName,
                buttonHeight: Util.isDesktop ? ButtonHeight.m : null,
                onPressed: () => _buy(d),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final names = _names;
    return Background(
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: PivxNamesAppBar(
          walletId: widget.walletId,
          title: l10n.pivxNamesMarketplace,
          section: PivxNamesSection.marketplace,
        ),
        body: SafeArea(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                Text(
                  l10n.pivxNamesMarketplaceIntro,
                  style: STextStyles.itemSubtitle(context),
                ),
                const SizedBox(height: 12),
                PivxNamesSearchField(
                  hint: l10n.pivxNamesSearchOnSale,
                  onSearch: (term) {
                    _search = term;
                    _page = 1;
                    unawaited(_load());
                  },
                ),
                const SizedBox(height: 12),
                if (_loading && names == null)
                  const PivxNamesListState(loading: true)
                else if (_error != null)
                  PivxNamesListState(error: _error, onRetry: _load)
                else if (names == null || names.items.isEmpty)
                  PivxNamesListState(
                    empty: _search.isNotEmpty
                        ? l10n.pivxNamesNoMatch
                        : l10n.pivxNamesNoneOnSale,
                    action: _search.isNotEmpty
                        ? null
                        : SecondaryButton(
                            label: l10n.pivxNamesSellMyNames,
                            width: 200,
                            buttonHeight: Util.isDesktop
                                ? ButtonHeight.m
                                : null,
                            onPressed: () => Navigator.of(context)
                                .pushReplacementNamed(
                                  PivxNamesSection.myNames.routeName,
                                  arguments: widget.walletId,
                                ),
                          ),
                  )
                else ...[
                  if (_loading) const LinearProgressIndicator(minHeight: 2),
                  for (final d in names.items) _card(d),
                  PivxNamesPager(
                    page: _page,
                    count: names.count,
                    pageSize: kPivxNamesListPageSize,
                    onPage: (p) {
                      _page = p;
                      unawaited(_load());
                    },
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
