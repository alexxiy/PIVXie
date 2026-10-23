import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../db/isar/main_db.dart';
import '../../models/isar/models/isar_models.dart';
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
import '../../widgets/middle_ellipsis_text.dart';
import '../../widgets/rounded_white_container.dart';
import '../send_view/sub_widgets/pivx_funding_card.dart';
import 'pivx_names_common.dart';
import 'pivx_names_flow.dart';
import 'pivx_names_in_flight.dart';

/// The names this wallet's key owns: where they point, and changing the
/// destination, the owner or the listing.
class PivxNamesMyNamesView extends ConsumerStatefulWidget {
  const PivxNamesMyNamesView({super.key, required this.walletId});

  static const routeName = kPivxNamesMyNamesRoute;

  final String walletId;

  @override
  ConsumerState<PivxNamesMyNamesView> createState() =>
      _PivxNamesMyNamesViewState();
}

class _PivxNamesMyNamesViewState extends ConsumerState<PivxNamesMyNamesView> {
  String? _key;
  String? _keyError;

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
      final key = _key ?? await pivxNamesPublicKey(_wallet);
      if (!mounted || request != _request) return;
      setState(() => _key = key);
      final names = await PivxNamesRegistrar.forCoin(_wallet.cryptoCurrency)!
          .myNames(pubkey: key, page: _page, search: _search);
      if (!mounted || request != _request) return;
      setState(() => _names = names);
    } catch (e) {
      if (!mounted || request != _request) return;
      setState(() {
        if (_key == null) _keyError = pivxNamesError(e);
        _error = "Couldn't load your names. ${pivxNamesError(e)}";
      });
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  Future<void> _start(PivxNamesFlow flow) =>
      startPivxNamesFlow(context, ref, flow);

  PivxNamesFlow _flow(
    PivxNamesDomain d,
    PivxNamesOp op, {
    BigInt? listedPrice,
  }) => PivxNamesFlow(
    walletId: widget.walletId,
    op: op,
    name: d.name,
    returnTo: PivxNamesMyNamesView.routeName,
    currentAddress: d.address,
    listedPrice: listedPrice,
  );

  Future<void> _unlist(PivxNamesDomain d) async {
    final ok = await pivxNamesConfirm(
      context,
      title: "Unlist from sale",
      message: "Take ${pivxNamesUnbroken(d.name)} off the marketplace?",
      action: "Unlist",
    );
    if (ok && mounted) await _start(_flow(d, PivxNamesOp.ult));
  }

  /// What can be done with [d], in a sheet: the price or unlisting while
  /// it's on sale, else its destination, owner or listing.
  Future<void> _manage(PivxNamesDomain d) async {
    final colors = Theme.of(context).extension<StackColors>()!;
    final listed = d.price > BigInt.zero;
    final actions = <_Action>[
      if (listed) ...[
        (
          icon: PivxNamesIcons.price,
          label: "Change sell price",
          note: "Listed for ${pivxNamesAmount(d.price, ref, _wallet)}",
          run: () => _start(_flow(d, PivxNamesOp.lst, listedPrice: d.price)),
        ),
        (
          icon: PivxNamesIcons.unlist,
          label: "Unlist",
          note: "Take it off the marketplace",
          run: () => _unlist(d),
        ),
      ] else ...[
        (
          icon: PivxNamesIcons.destination,
          label: "Change destination",
          note: "Point it to another shield address",
          run: () => _start(_flow(d, PivxNamesOp.upd)),
        ),
        (
          icon: PivxNamesIcons.owner,
          label: "Change owner",
          note: "Give it to someone else's public key",
          run: () => _start(_flow(d, PivxNamesOp.chg)),
        ),
        (
          icon: PivxNamesIcons.list,
          label: "List on marketplace",
          note: "Put it up for sale",
          run: () => _start(_flow(d, PivxNamesOp.lst)),
        ),
      ],
    ];
    final picked = await showModalBottomSheet<_Action>(
      context: context,
      backgroundColor: colors.popupBG,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PivxNamesNameText(
                d.name,
                style: STextStyles.pageTitleH2(context),
              ),
              const SizedBox(height: 12),
              for (final a in actions)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _actionTile(a),
                ),
            ],
          ),
        ),
      ),
    );
    // Once the sheet is gone, so that the flow opens over this page.
    if (picked != null && mounted) await picked.run();
  }

  Widget _actionTile(_Action a) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final color = a.icon == PivxNamesIcons.unlist
        ? colors.textError
        : colors.accentColorBlue;
    return RoundedWhiteContainer(
      padding: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => Navigator.of(context).pop(a),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: PivxNamesIcon(a.icon, size: 18, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(a.label, style: STextStyles.w600_14(context)),
                    const SizedBox(height: 2),
                    Text(
                      a.note,
                      style: STextStyles.w500_12(context)
                          .copyWith(color: colors.textSubtitle1),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right_rounded, color: colors.textSubtitle1),
            ],
          ),
        ),
      ),
    );
  }

  Widget _keyCard() {
    final colors = Theme.of(context).extension<StackColors>()!;
    final key = _key;
    return RoundedWhiteContainer(
      padding: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: key == null
            ? null
            : () => pivxNamesCopy(context, key, "Public key"),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      "Your public key",
                      style: STextStyles.w500_12(context)
                          .copyWith(color: colors.textSubtitle1),
                    ),
                  ),
                  if (key != null)
                    Icon(
                      Icons.copy_rounded,
                      size: 16,
                      color: colors.textSubtitle1,
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                key ?? _keyError ?? "…",
                style: STextStyles.w500_12(context).copyWith(
                  fontFamily: "monospace",
                  color: key == null && _keyError != null
                      ? colors.textError
                      : colors.textDark,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                "Your names belong to this key. It comes from your recovery "
                "phrase: open pivx.name with the same phrase and you'll find "
                "the same names. Share it with anyone who wants to give you "
                "a name.",
                style: STextStyles.w500_12(context)
                    .copyWith(color: colors.textSubtitle1),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _card(PivxNamesDomain d) {
    final colors = Theme.of(context).extension<StackColors>()!;
    final wallet = _wallet;
    final listed = d.price > BigInt.zero;
    final address = d.address;
    final own =
        address != null &&
        MainDB.instance.isar.addresses.getByValueWalletIdSync(
              address,
              widget.walletId,
            ) !=
            null;
    final secondary = STextStyles.w500_12(context)
        .copyWith(color: colors.textSubtitle1);
    final walletId = widget.walletId;
    final inFlight = PivxNamesInFlight.of(walletId, d.name);
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
                listed
                    ? PivxNamesPill(
                        text:
                            "On sale: ${pivxNamesAmount(d.price, ref, wallet)}",
                        color: colors.accentColorBlue,
                      )
                    : PivxNamesPill(
                        text: "Active",
                        color: pivxNamesReadable(
                          colors.accentColorGreen,
                          colors,
                        ),
                      ),
              ],
            ),
            if (address != null) ...[
              const SizedBox(height: 10),
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () => pivxNamesCopy(context, address, "Address"),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              own
                                  ? "Points to "
                                        "${pivxAddressTitle(walletId, address)}"
                                  // Possibly one of this phrase's that the
                                  // wallet hasn't made yet (after a
                                  // restore): not "outside the wallet".
                                  : "Points to an address not on this "
                                        "wallet's list",
                              style: secondary,
                            ),
                            const SizedBox(height: 2),
                            MiddleEllipsisText(
                              address,
                              style: STextStyles.w500_14(context),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        Icons.copy_rounded,
                        size: 16,
                        color: colors.textSubtitle1,
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 10),
            if (inFlight != null)
              PivxNamesInFlightNote(tracked: inFlight)
            else
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 160),
                  child: IntrinsicWidth(
                    child: SecondaryButton(
                      label: "Manage",
                      icon: PivxNamesIcon(
                        PivxNamesIcons.manage,
                        size: 18,
                        color: colors.buttonTextSecondary,
                      ),
                      iconSpacing: 8,
                      buttonHeight: Util.isDesktop ? ButtonHeight.m : null,
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      onPressed: () => _manage(d),
                    ),
                  ),
                ),
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
          title: "My Names",
          section: PivxNamesSection.myNames,
        ),
        body: SafeArea(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                Text(
                  "Manage where your names point and who owns them.",
                  style: STextStyles.itemSubtitle(context),
                ),
                const SizedBox(height: 12),
                _keyCard(),
                const SizedBox(height: 12),
                PivxNamesSearchField(
                  hint: "Search your names",
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
                        ? "No names match your search."
                        : "You haven't registered a PIVX name yet.",
                    action: _search.isNotEmpty
                        ? null
                        : PrimaryButton(
                            label: "Register your first name",
                            buttonHeight: Util.isDesktop
                                ? ButtonHeight.m
                                : null,
                            onPressed: () => Navigator.of(context).pop(),
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

typedef _Action = ({
  String icon,
  String label,
  String note,
  FutureOr<void> Function() run,
});
