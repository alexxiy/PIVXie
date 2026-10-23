import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:coinlib_flutter/coinlib_flutter.dart' as coinlib;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../../l10n/l10n.dart';
import '../../../models/keys/view_only_wallet_data.dart';
import '../../../notifications/show_flush_bar.dart';
import '../../../pages_desktop_specific/desktop_home_view.dart';
import '../../../pages_desktop_specific/my_stack_view/exit_to_my_stack_button.dart';
import '../../../providers/global/secure_store_provider.dart';
import '../../../providers/providers.dart';
import '../../../themes/stack_colors.dart';
import '../../../utilities/clipboard_interface.dart';
import '../../../utilities/text_styles.dart';
import '../../../utilities/util.dart';
import '../../../wallets/crypto_currency/crypto_currency.dart';
import '../../../wallets/crypto_currency/intermediate/bip39_hd_currency.dart';
import '../../../wallets/isar/models/wallet_info.dart';
import '../../../wallets/wallet/wallet.dart';
import '../../../widgets/custom_buttons/app_bar_icon_button.dart';
import '../../../widgets/desktop/desktop_app_bar.dart';
import '../../../widgets/desktop/desktop_scaffold.dart';
import '../../../widgets/desktop/primary_button.dart';
import '../../../widgets/stack_text_field.dart';
import '../../home_view/home_view.dart';
import 'confirm_recovery_dialog.dart';
import 'sub_widgets/restore_failed_dialog.dart';
import 'sub_widgets/restore_succeeded_dialog.dart';
import 'sub_widgets/restoring_dialog.dart';

class RestoreViewOnlyWalletView extends ConsumerStatefulWidget {
  const RestoreViewOnlyWalletView({
    super.key,
    required this.walletName,
    required this.coin,
    required this.restoreBlockHeight,
    this.clipboard = const ClipboardWrapper(),
  });

  static const routeName = "/restoreViewOnlyWallet";

  final String walletName;
  final CryptoCurrency coin;
  final int restoreBlockHeight;
  final ClipboardInterface clipboard;

  @override
  ConsumerState<RestoreViewOnlyWalletView> createState() =>
      _RestoreViewOnlyWalletViewState();
}

class _RestoreViewOnlyWalletViewState
    extends ConsumerState<RestoreViewOnlyWalletView> {
  late final TextEditingController viewKeyController;

  bool _enableRestoreButton = false;
  bool _buttonLock = false;

  /// Why [xpub] can't be watched, or null. Checked before anything is
  /// made: a bad key only failed deep in the restore, with the library's
  /// error ("Instance of 'InvalidBase58Checksum'").
  String? _xpubProblem(String xpub) {
    final coin = widget.coin as Bip39HDCurrency;
    final coinlib.HDPublicKey key;
    try {
      key = coinlib.HDPublicKey.decode(xpub, coin.networkParams.pubHDPrefix);
    } catch (_) {
      return l10n.restoreNotXpub(coin.prettyName);
    }
    // Addresses are derived below the account key (chain/index).
    if (key.depth != 3) {
      return l10n.restoreUseAccountXpub(
        coin.supportedHardenedDerivationPaths.last,
      );
    }
    return null;
  }

  Future<void> _requestRestore() async {
    if (_buttonLock) return;
    _buttonLock = true;

    try {
      final problem = _xpubProblem(viewKeyController.text.trim());
      if (problem != null) {
        await showFloatingFlushBar(
          type: FlushBarType.warning,
          message: problem,
          context: context,
        );
        return;
      }
      if (!Util.isDesktop) {
        // wait for keyboard to disappear
        FocusScope.of(context).unfocus();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }

      if (mounted) {
        await showDialog<dynamic>(
          context: context,
          useSafeArea: false,
          barrierDismissible: true,
          builder: (context) {
            return ConfirmRecoveryDialog(onConfirm: _attemptRestore);
          },
        );
      }
    } finally {
      _buttonLock = false;
    }
  }

  Future<void> _attemptRestore() async {
    final Map<String, dynamic> otherDataJson = {
      WalletInfoKeys.isViewOnlyKey: true,
    };

    // PIVX view only wallets watch one BIP44 account xpub.
    otherDataJson[WalletInfoKeys.viewOnlyTypeIndexKey] =
        ViewOnlyWalletType.xPub.index;
    if (ref.read(pDuress)) {
      otherDataJson[WalletInfoKeys.duressMarkedVisibleWalletKey] = true;
    }

    if (!Platform.isLinux) await WakelockPlus.enable();

    try {
      final info = WalletInfo.createNew(
        coin: widget.coin,
        name: widget.walletName,
        restoreHeight: widget.restoreBlockHeight,
        otherDataJsonString: jsonEncode(otherDataJson),
      );

      bool isRestoring = true;
      // show restoring in progress

      if (mounted) {
        unawaited(
          showDialog<dynamic>(
            context: context,
            useSafeArea: false,
            barrierDismissible: false,
            builder: (context) {
              return RestoringDialog(
                onCancel: () async {
                  isRestoring = false;

                  await ref
                      .read(pWallets)
                      .deleteWallet(info, ref.read(secureStoreProvider));
                },
              );
            },
          ),
        );
      }

      final xpub = viewKeyController.text.trim();
      if (xpub.isEmpty) {
        throw Exception(l10n.restoreXpubEmpty);
      }
      final viewOnlyData = ExtendedKeysViewOnlyWalletData(
        walletId: info.walletId,
        xPubs: [
          XPub(
            path: (widget.coin as Bip39HDCurrency)
                .supportedHardenedDerivationPaths
                .last,
            encoded: xpub,
          ),
        ],
      );

      var node = ref
          .read(nodeServiceChangeNotifierProvider)
          .getPrimaryNodeFor(currency: widget.coin);

      if (node == null) {
        node = widget.coin.defaultNode(isPrimary: true);
        await ref.read(nodeServiceChangeNotifierProvider).save(node, false);
      }

      try {
        final wallet = await Wallet.create(
          walletInfo: info,
          mainDB: ref.read(mainDBProvider),
          secureStorageInterface: ref.read(secureStoreProvider),
          nodeService: ref.read(nodeServiceChangeNotifierProvider),
          prefs: ref.read(prefsChangeNotifierProvider),
          viewOnlyData: viewOnlyData,
        );

        await wallet.init();

        await wallet.recover(isRescan: false);

        // check if state is still active before continuing
        if (mounted) {
          // don't remove this setMnemonicVerified thing
          await wallet.info.setMnemonicVerified(
            isar: ref.read(mainDBProvider).isar,
          );

          if (ref.read(pDuress)) {
            await wallet.info.updateDuressVisibilityStatus(
              isDuressVisible: true,
              isar: ref.read(mainDBProvider).isar,
            );
          }

          ref.read(pWallets).addWallet(wallet);

          if (mounted) {
            if (Util.isDesktop) {
              Navigator.of(context)
                  .popUntil(ModalRoute.withName(DesktopHomeView.routeName));
            } else {
              unawaited(
                Navigator.of(
                  context,
                ).pushNamedAndRemoveUntil(HomeView.routeName, (route) => false),
              );
            }

            await showDialog<dynamic>(
              context: context,
              useSafeArea: false,
              barrierDismissible: true,
              builder: (context) {
                return const RestoreSucceededDialog();
              },
            );
          }
        }
      } catch (e) {
        // check if state is still active and restore wasn't cancelled
        // before continuing
        if (mounted && isRestoring) {
          // pop waiting dialog
          Navigator.pop(context);

          // show restoring wallet failed dialog
          await showDialog<dynamic>(
            context: context,
            useSafeArea: false,
            barrierDismissible: true,
            builder: (context) {
              return RestoreFailedDialog(
                errorMessage: e.toString(),
                walletId: info.walletId,
                walletName: info.name,
              );
            },
          );
        }
      }
    } finally {
      if (!Platform.isLinux) await WakelockPlus.disable();
    }
  }

  @override
  void initState() {
    super.initState();
    viewKeyController = TextEditingController();
  }

  @override
  void dispose() {
    viewKeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = Util.isDesktop;

    return MasterScaffold(
      isDesktop: isDesktop,
      appBar: isDesktop
          ? const DesktopAppBar(
              isCompactHeight: false,
              leading: AppBarBackButton(),
              trailing: ExitToMyStackButton(),
            )
          : AppBar(
              leading: AppBarBackButton(
                onPressed: () async {
                  if (FocusScope.of(context).hasFocus) {
                    FocusScope.of(context).unfocus();
                    await Future<void>.delayed(
                      const Duration(milliseconds: 50),
                    );
                  }
                  if (context.mounted) {
                    Navigator.of(context).pop();
                  }
                },
              ),
            ),
      body: Container(
        color: Theme.of(context).extension<StackColors>()!.background,
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight,
                  maxWidth: isDesktop ? 480 : double.infinity,
                ),
                child: IntrinsicHeight(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        if (isDesktop) const Spacer(flex: 10),
                        if (!isDesktop)
                          Text(
                            widget.walletName,
                            style: STextStyles.itemSubtitle(context),
                          ),
                        SizedBox(height: isDesktop ? 0 : 4),
                        Text(
                          l10n.restoreEnterViewOnly,
                          style: isDesktop
                              ? STextStyles.desktopH2(context)
                              : STextStyles.pageTitleH1(context),
                        ),
                        SizedBox(height: isDesktop ? 24 : 16),
                        FullTextField(
                          key: const Key("viewOnlyKeyRestoreFieldKey"),
                          label: l10n.restoreXpub,
                          controller: viewKeyController,
                          onChanged: (value) {
                            setState(() {
                              _enableRestoreButton = value.trim().isNotEmpty;
                            });
                          },
                        ),
                        if (!isDesktop) const Spacer(),
                        SizedBox(height: isDesktop ? 24 : 16),
                        PrimaryButton(
                          enabled: _enableRestoreButton,
                          onPressed: _requestRestore,
                          width: isDesktop ? 480 : null,
                          label: l10n.restoreAction,
                        ),
                        if (isDesktop) const Spacer(flex: 15),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
