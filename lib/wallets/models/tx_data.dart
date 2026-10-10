import '../../models/input.dart';
import '../../models/isar/models/blockchain_data/v2/transaction_v2.dart';
import '../../utilities/amount/amount.dart';
import '../../utilities/enums/fee_rate_type_enum.dart';
import 'tx_recipient.dart';

export 'tx_recipient.dart';

class TxData {
  final FeeRateType? feeRateType;
  final BigInt? feeRateAmount;
  final int? satsPerVByte;

  final Amount? fee;
  final int? vSize;

  final String? raw;

  final String? txid;
  final String? txHash;

  final String? note;
  final String? noteOnChain;

  final String? memo;

  final List<TxRecipient>? recipients;
  final Set<BaseInput>? utxos;
  final List<BaseInput>? usedUTXOs;

  final String? changeAddress;

  // PIVX: JSON encoded send options (shield, subtract fee, ...)
  final String? otherData;

  final TransactionV2? tempTx;

  TxData({
    this.feeRateType,
    this.feeRateAmount,
    this.satsPerVByte,
    this.fee,
    this.vSize,
    this.raw,
    this.txid,
    this.txHash,
    this.note,
    this.noteOnChain,
    this.memo,
    this.recipients,
    this.utxos,
    this.usedUTXOs,
    this.changeAddress,
    this.otherData,
    this.tempTx,
  });

  Amount? get amount {
    if (recipients != null && recipients!.isNotEmpty) {
      return recipients!
          .map((e) => e.amount)
          .reduce((total, amount) => total += amount);
    }

    return null;
  }

  Amount? get amountWithoutChange {
    if (recipients != null && recipients!.isNotEmpty) {
      if (recipients!.where((e) => !e.isChange).isEmpty) {
        return Amount(
          rawValue: BigInt.zero,
          fractionDigits: recipients!.first.amount.fractionDigits,
        );
      } else {
        return recipients!
            .where((e) => !e.isChange)
            .map((e) => e.amount)
            .reduce((total, amount) => total += amount);
      }
    } else {
      return null;
    }
  }

  TxData copyWith({
    FeeRateType? feeRateType,
    BigInt? feeRateAmount,
    int? satsPerVByte,
    Amount? fee,
    int? vSize,
    String? raw,
    String? txid,
    String? txHash,
    String? note,
    String? noteOnChain,
    String? memo,
    String? otherData,
    Set<BaseInput>? utxos,
    List<BaseInput>? usedUTXOs,
    List<TxRecipient>? recipients,
    String? changeAddress,
    TransactionV2? tempTx,
  }) {
    return TxData(
      feeRateType: feeRateType ?? this.feeRateType,
      feeRateAmount: feeRateAmount ?? this.feeRateAmount,
      satsPerVByte: satsPerVByte ?? this.satsPerVByte,
      fee: fee ?? this.fee,
      vSize: vSize ?? this.vSize,
      raw: raw ?? this.raw,
      txid: txid ?? this.txid,
      txHash: txHash ?? this.txHash,
      note: note ?? this.note,
      noteOnChain: noteOnChain ?? this.noteOnChain,
      memo: memo ?? this.memo,
      otherData: otherData ?? this.otherData,
      utxos: utxos ?? this.utxos,
      usedUTXOs: usedUTXOs ?? this.usedUTXOs,
      recipients: recipients ?? this.recipients,
      changeAddress: changeAddress ?? this.changeAddress,
      tempTx: tempTx ?? this.tempTx,
    );
  }

  @override
  String toString() =>
      'TxData{'
      'feeRateType: $feeRateType, '
      'feeRateAmount: $feeRateAmount, '
      'satsPerVByte: $satsPerVByte, '
      'fee: $fee, '
      'vSize: $vSize, '
      'raw: $raw, '
      'txid: $txid, '
      'txHash: $txHash, '
      'note: $note, '
      'noteOnChain: $noteOnChain, '
      'memo: $memo, '
      'recipients: $recipients, '
      'utxos: $utxos, '
      'usedUTXOs: $usedUTXOs, '
      'changeAddress: $changeAddress, '
      'otherData: $otherData, '
      'tempTx: $tempTx, '
      '}';
}
