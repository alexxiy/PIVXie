// Stored by index in [TransactionV2]: append new values, never insert or
// remove.
enum TransactionType { outgoing, incoming, sentToSelf, unknown }

// Stored by index, like [TransactionType]: the values of other coins only
// keep the indexes of the ones PIVXie uses.
enum TransactionSubType {
  none,
  bip47Notification,
  mint,
  join,
  ethToken,
  cashFusion,
  sparkMint,
  sparkSpend,
  ordinal,
  mweb,
  splToken,
}
