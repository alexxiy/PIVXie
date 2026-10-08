//! Commitment tree checkpoints, so new wallets don't sync from activation.
use crate::mainnet_checkpoints::MAINNET_CHECKPOINTS;
use crate::testnet_checkpoints::TESTNET_CHECKPOINTS;

/// Closest checkpoint at or below `block_height`: (height, commitment tree hex).
pub fn get_checkpoint(block_height: i32, is_testnet: bool) -> (i32, &'static str) {
    let used = if is_testnet { TESTNET_CHECKPOINTS } else { MAINNET_CHECKPOINTS };
    used.iter()
        .rev()
        .find(|x| x.0 <= block_height)
        .copied()
        .unwrap_or(used[0])
}
