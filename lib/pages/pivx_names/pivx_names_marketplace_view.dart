import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../providers/global/wallets_provider.dart';
import '../../services/pivx_name/pivx_name.dart';
import '../../services/pivx_name/pivx_names_protocol.dart';
import '../../services/pivx_name/pivx_names_registrar.dart';
import '../../themes/stack_colors.dart';
import '../../utilities/text_styles.dart';
import '../../utilities/util.dart';
import '../../wallets/wallet/impl/pivx_wallet.dart';
import '../../widgets/adaptive_page.dart';
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
  String _search = "";
  List<String> _zones = kPivxNameZones;

  /// The pages shown so far, and where the next one starts (null: no more).
  List<PivxNamesDomain>? _names;
  String? _next;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  String? _moreError;
  int _request = 0;

  // Filters live with the screen: leaving it resets them.
  PivxNamesFilter _filter = kPivxNamesNoFilter;
  bool _filtersOpen = false;

  PivxWallet get _wallet =>
      ref.read(pWallets).getWallet(widget.walletId) as PivxWallet;

  PivxNamesRegistrar get _registrar =>
      PivxNamesRegistrar.forCoin(_wallet.cryptoCurrency)!;

  @override
  void initState() {
    super.initState();
    pivxNamesChanges.addListener(_changed);
    unawaited(_loadKey());
    unawaited(
      pivxNamesZones(_wallet).then((zones) {
        if (mounted) setState(() => _zones = zones);
      }),
    );
    unawaited(_load());
  }

  @override
  void dispose() {
    pivxNamesChanges.removeListener(_changed);
    super.dispose();
  }

  void _changed() => unawaited(_load());

  /// The user's key, to tell their own listings apart (the list has each
  /// owner's).
  Future<void> _loadKey() async {
    try {
      final key = await pivxNamesPublicKey(_wallet);
      if (mounted) setState(() => _key = key);
    } catch (_) {}
  }

  /// The first page again.
  Future<void> _load() async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _loadingMore = false;
      _error = null;
      _moreError = null;
    });
    try {
      final page = await _registrar.marketplace(
        search: _search,
        filter: _filter,
      );
      if (!mounted || request != _request) return;
      setState(() {
        _names = page.items;
        _next = page.next;
      });
    } catch (e) {
      if (!mounted || request != _request) return;
      setState(() => _error = l10n.pivxNamesLoadNamesFailed(pivxNamesError(e)));
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  /// The page after those shown.
  Future<void> _more() async {
    final after = _next;
    if (after == null || _loading || _loadingMore) return;
    final request = _request;
    setState(() {
      _loadingMore = true;
      _moreError = null;
    });
    try {
      final page = await _registrar.marketplace(
        after: after,
        search: _search,
        filter: _filter,
      );
      if (!mounted || request != _request) return;
      setState(() {
        // A name whose listing changed meanwhile may come again.
        final shown = {for (final d in _names ?? const []) d.name};
        _names = [
          ...?_names,
          for (final d in page.items)
            if (!shown.contains(d.name)) d,
        ];
        _next = page.next;
      });
    } catch (e) {
      if (!mounted || request != _request) return;
      setState(
        () => _moreError = l10n.pivxNamesLoadNamesFailed(pivxNamesError(e)),
      );
    } finally {
      if (mounted && request == _request) setState(() => _loadingMore = false);
    }
  }

  void _setFilter(PivxNamesFilter filter) {
    setState(() => _filter = filter);
    unawaited(_load());
  }

  PivxNamesFlow _flow(PivxNamesDomain d, PivxNamesOp op) => PivxNamesFlow(
    walletId: widget.walletId,
    op: op,
    name: d.name,
    price: op == PivxNamesOp.buy ? d.price : d.updatePrice,
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
    final filtered = _filter != kPivxNamesNoFilter;
    return Background(
      child: AppScaffold(
        maxBodyWidth: ScreenFit.panesOrColumn(context),
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
                PivxNamesSearchBar(
                  search: PivxNamesSearchField(
                    hint: l10n.pivxNamesSearchOnSale,
                    onSearch: (term) {
                      _search = term;
                      unawaited(_load());
                    },
                  ),
                  filter: _filter,
                  open: _filtersOpen,
                  onToggle: () => setState(() => _filtersOpen = !_filtersOpen),
                ),
                if (_filtersOpen)
                  PivxNamesFilterPanel(
                    filter: _filter,
                    zones: _zones,
                    onChanged: _setFilter,
                  ),
                const SizedBox(height: 12),
                if (_loading && names == null)
                  const PivxNamesListState(loading: true)
                else if (_error != null)
                  PivxNamesListState(error: _error, onRetry: _load)
                else if (names == null || names.isEmpty)
                  PivxNamesListState(
                    empty: filtered
                        ? l10n.pivxNamesNoFilterMatch
                        : _search.isNotEmpty
                        ? l10n.pivxNamesNoMatch
                        : l10n.pivxNamesNoneOnSale,
                    action: filtered
                        ? SecondaryButton(
                            label: l10n.pivxNamesResetFilters,
                            width: 200,
                            buttonHeight: Util.isDesktop
                                ? ButtonHeight.m
                                : null,
                            onPressed: () => _setFilter(kPivxNamesNoFilter),
                          )
                        : _search.isNotEmpty
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
                  CardGrid(children: [for (final d in names) _card(d)]),
                  if (_moreError != null)
                    PivxNamesListState(error: _moreError, onRetry: _more)
                  else if (_next != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Center(
                        child: SecondaryButton(
                          label: l10n.pivxNamesShowMore,
                          width: 200,
                          enabled: !_loadingMore && !_loading,
                          buttonHeight: Util.isDesktop ? ButtonHeight.m : null,
                          onPressed: _more,
                        ),
                      ),
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
