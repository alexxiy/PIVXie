//! Sapling note scanning and transaction building.
//!
//! Ported from PIVX-Labs/pivx-shield `src/transaction.rs` (MIT). The wallet
//! state (commitment tree, notes) is owned by the caller and passed in/out
//! as serialisable data; nothing here keeps state except the prover.
//!
//! Differences from upstream:
//! - no wasm-bindgen / tokio; transaction proving is synchronous
//! - notes carry their `value` and recipient `address` for the caller
//! - `handle_blocks` also returns per-transaction details for history
use crate::keys::{
    decode_extended_full_viewing_key, decode_extsk, decode_generic_address,
    encode_payment_address_internal, GenericAddress,
};
use crate::prover::{self, ImplTxProver};
use either::Either;
use incrementalmerkletree::frontier::CommitmentTree;
use incrementalmerkletree::witness::IncrementalWitness;
use pivx_client_backend::decrypt_transaction;
use pivx_client_backend::TransferType;
use pivx_client_backend::keys::UnifiedFullViewingKey;
use pivx_primitives::consensus::Network;
use pivx_primitives::consensus::NetworkConstants;
use pivx_primitives::consensus::{BlockHeight, MAIN_NETWORK, TEST_NETWORK};
use pivx_primitives::legacy::Script;
use pivx_primitives::memo::MemoBytes;
use pivx_primitives::merkle_tree::read_commitment_tree as zcash_read_commitment_tree;
use pivx_primitives::merkle_tree::read_incremental_witness;
use pivx_primitives::merkle_tree::write_commitment_tree;
use pivx_primitives::merkle_tree::write_incremental_witness;
use pivx_primitives::transaction::builder::BuildConfig;
use pivx_primitives::transaction::builder::Builder;
use pivx_primitives::transaction::builder::DEFAULT_TX_EXPIRY_DELTA;
use pivx_primitives::transaction::components::sapling::zip212_enforcement;
use pivx_primitives::transaction::sighash::{signature_hash, SignableInput};
use pivx_primitives::transaction::txid::TxIdDigester;
use pivx_primitives::transaction::{TransactionData, TxVersion};
use pivx_protocol::consensus::BranchId;
use pivx_protocol::value::ZatBalance;
use sapling::builder::BundleType;
use sapling::value::NoteValue;
use zcash_transparent::address::TransparentAddress;
use zcash_transparent::builder::TransparentBuilder;
use pivx_primitives::transaction::components::transparent::builder::TransparentSigningSet;
use pivx_primitives::transaction::fees::fixed::FeeRule;
use pivx_primitives::transaction::Transaction;
use pivx_primitives::zip32::AccountId;
use pivx_primitives::zip32::Scope;
use pivx_protocol::memo::Memo;
use pivx_protocol::value::Zatoshis;
use rand_core::OsRng;
use rayon::prelude::*;
use sapling::builder::ProverProgress;
use sapling::note::ExtractedNoteCommitment;
use sapling::keys::OutgoingViewingKey;
use sapling::note_encryption::{PreparedIncomingViewingKey, SaplingDomain, Zip212Enforcement};
use sapling::value::ValueCommitment;
use sapling::zip32::ExtendedSpendingKey;
use sapling::Anchor;
use sapling::NullifierDerivingKey;
use sapling::{note::Note, Node, Nullifier};
use secp256k1::Secp256k1;
use secp256k1::SecretKey;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::error::Error;
use std::io::Cursor;
use std::str::FromStr;
use zcash_note_encryption::{
    try_note_decryption, try_output_recovery_with_ovk, EphemeralKeyBytes, ShieldedOutput, ENC_CIPHERTEXT_SIZE,
    OUT_CIPHERTEXT_SIZE,
};
use zcash_transparent::bundle::{OutPoint, TxOut};

pub const DEPTH: u8 = 32;

/// PIVX Core's dust threshold for a P2PKH output at the 10 sat/byte relay
/// fee (3 * (34 + 148) * 10): nodes don't relay smaller transparent outputs.
const DUST_SATS: u64 = 5460;

type BoxResult<T> = Result<T, Box<dyn Error>>;

/// Shield fee rule used by PIVX wallets: 1000 sat per estimated byte.
fn fee_calculator(
    transparent_input_count: u64,
    transparent_output_count: u64,
    sapling_input_count: u64,
    sapling_output_count: u64,
) -> u64 {
    let fee_per_byte = 1000;
    let transparent_input_size = 150;
    let transparent_output_size = 34;
    let tx_offset_size = 85;
    let sapling_output_size = 948;
    let sapling_input_size = 384;
    fee_per_byte
        * (sapling_output_count * sapling_output_size
            + sapling_input_count * sapling_input_size
            + transparent_input_count * transparent_input_size
            + transparent_output_count * transparent_output_size
            + tx_offset_size)
}

// ---------------------------------------------------------------------------
// Serialised types
// ---------------------------------------------------------------------------

#[derive(Serialize, Deserialize)]
pub struct JSSpendableNote {
    pub note: Note,
    pub witness: String,
    pub nullifier: String,
    pub memo: Option<String>,
    /// Note value in satoshis (informational, filled on output).
    #[serde(default)]
    pub value: u64,
    /// Recipient shield address (informational, filled on output).
    #[serde(default)]
    pub address: String,
}

pub struct SpendableNote {
    note: Note,
    witness: IncrementalWitness<Node, DEPTH>,
    nullifier: String,
    memo: Option<String>,
}

impl SpendableNote {
    fn from_js(n: JSSpendableNote) -> BoxResult<SpendableNote> {
        let wit = Cursor::new(hex::decode(n.witness)?);
        Ok(SpendableNote {
            note: n.note,
            witness: read_incremental_witness(wit)?,
            nullifier: n.nullifier,
            memo: n.memo,
        })
    }

    fn into_js(self, is_testnet: bool) -> BoxResult<JSSpendableNote> {
        let mut buff = Vec::new();
        write_incremental_witness(&self.witness, &mut buff)?;
        Ok(JSSpendableNote {
            value: self.note.value().inner(),
            address: encode_payment_address_internal(&self.note.recipient(), is_testnet),
            note: self.note,
            witness: hex::encode(&buff),
            nullifier: self.nullifier,
            memo: self.memo,
        })
    }
}

#[derive(Serialize, Deserialize)]
pub struct Block {
    /// Hex of each shield transaction: a full raw one (the bridge's `pivx`
    /// stream format) or a compact packet (its `compact` format, see
    /// [`COMPACT_TX`]).
    pub txs: Vec<String>,
}

/// A note received by the wallet in a specific transaction.
#[derive(Serialize, Deserialize)]
pub struct ReceivedNote {
    pub value: u64,
    pub address: String,
    pub memo: Option<String>,
    pub nullifier: String,
    /// Index of the note's output among the tx's shield outputs.
    pub index: u32,
}

/// A shield output this wallet sent to someone else, recovered with the
/// wallet's outgoing viewing key.
#[derive(Serialize, Deserialize, Clone)]
pub struct SentNote {
    pub value: u64,
    pub address: String,
    pub memo: Option<String>,
    pub index: u32,
}

/// A transaction that touches the wallet (receives a note, spends one,
/// or sent shield outputs recoverable with our outgoing viewing key).
#[derive(Serialize, Deserialize)]
pub struct WalletTxDetail {
    /// Empty for a compact packet, which has no txid: the caller finds
    /// the transaction in its block by `nullifiers` and `commitments`.
    pub txid: String,
    pub hex: String,
    /// Index of the transaction's block in the blocks passed in.
    #[serde(default)]
    pub block: u32,
    pub received: Vec<ReceivedNote>,
    #[serde(default)]
    pub sent: Vec<SentNote>,
    /// All nullifiers revealed by the tx (the caller matches its own).
    pub nullifiers: Vec<String>,
    /// Note commitments (cmu) of all the tx's shield outputs, in order.
    #[serde(default)]
    pub commitments: Vec<String>,
}

#[derive(Serialize, Deserialize)]
pub struct HandleBlocksResult {
    pub decrypted_notes: Vec<JSSpendableNote>,
    pub decrypted_new_notes: Vec<JSSpendableNote>,
    pub nullifiers: Vec<String>,
    pub commitment_tree: String,
    pub wallet_transactions: Vec<WalletTxDetail>,
}

fn read_commitment_tree(tree_hex: &str) -> BoxResult<CommitmentTree<Node, DEPTH>> {
    let buff = Cursor::new(hex::decode(tree_hex)?);
    Ok(zcash_read_commitment_tree(buff)?)
}

fn serialize_notes(notes: Vec<SpendableNote>, is_testnet: bool) -> BoxResult<Vec<JSSpendableNote>> {
    notes.into_iter().map(|n| n.into_js(is_testnet)).collect()
}

fn memo_text(bytes: &[u8]) -> Option<String> {
    Memo::from_bytes(bytes)
        .map(|m| if let Memo::Text(e) = m { e.to_string() } else { String::new() })
        .ok()
}

// ---------------------------------------------------------------------------
// Block handling
// ---------------------------------------------------------------------------

/// Txid (display hex) of a raw transaction: its double SHA-256, reversed.
/// `Transaction::txid` hashes only the bytes the parser reads, which for a
/// special transaction (masternode registration and the like, nType != 0)
/// leaves out its extra payload after the Sapling data.
pub(crate) fn raw_txid(raw_hex: &str) -> BoxResult<String> {
    let raw = hex::decode(raw_hex)?;
    let once = hex::decode(sha256::digest(&raw[..]))?;
    let mut twice = hex::decode(sha256::digest(&once[..]))?;
    twice.reverse();
    Ok(hex::encode(twice))
}

/// Packet type of a transaction in the bridge's `compact` stream: the
/// nullifiers and outputs of its Sapling bundle without proofs or
/// signatures. A full raw transaction (version 3) starts with 0x03.
pub const COMPACT_TX: u8 = 0x04;

/// A Sapling output from a compact packet: all of an output but its proof.
struct CompactOutput {
    cv: ValueCommitment,
    cmu: ExtractedNoteCommitment,
    epk: EphemeralKeyBytes,
    enc_ciphertext: [u8; ENC_CIPHERTEXT_SIZE],
    out_ciphertext: [u8; OUT_CIPHERTEXT_SIZE],
}

impl ShieldedOutput<SaplingDomain, ENC_CIPHERTEXT_SIZE> for CompactOutput {
    fn ephemeral_key(&self) -> EphemeralKeyBytes {
        self.epk.clone()
    }
    fn cmstar_bytes(&self) -> [u8; 32] {
        self.cmu.to_bytes()
    }
    fn enc_ciphertext(&self) -> &[u8; ENC_CIPHERTEXT_SIZE] {
        &self.enc_ciphertext
    }
}

/// A transaction from the shield stream.
enum StreamTx {
    Full(Box<Transaction>),
    Compact {
        nullifiers: Vec<Nullifier>,
        outputs: Vec<CompactOutput>,
    },
}

/// A Bitcoin CompactSize at `pos`: its value and the position after it.
fn read_compact_size(data: &[u8], pos: usize) -> BoxResult<(usize, usize)> {
    let first = *data.get(pos).ok_or("Truncated compact packet")?;
    let len = match first {
        0xfd => 2,
        0xfe => 4,
        0xff => 8,
        n => return Ok((n as usize, pos + 1)),
    };
    let bytes = data.get(pos + 1..pos + 1 + len).ok_or("Truncated compact packet")?;
    let mut v = [0u8; 8];
    v[..len].copy_from_slice(bytes);
    let n = usize::try_from(u64::from_le_bytes(v)).map_err(|_| "Compact packet count too large")?;
    Ok((n, pos + 1 + len))
}

fn take<const N: usize>(data: &[u8], pos: &mut usize) -> [u8; N] {
    let mut out = [0u8; N];
    out.copy_from_slice(&data[*pos..*pos + N]);
    *pos += N;
    out
}

/// A compact packet: `[0x04][spends][outputs]`, then 32 bytes of nullifier
/// per spend and per output cv, cmu, epk (32 each), enc_ciphertext and
/// out_ciphertext (the bridge's `encode_compact_packet`).
fn parse_compact_tx(data: &[u8]) -> BoxResult<StreamTx> {
    const OUTPUT_SIZE: usize = 3 * 32 + ENC_CIPHERTEXT_SIZE + OUT_CIPHERTEXT_SIZE;
    let (spends, pos) = read_compact_size(data, 1)?;
    let (outputs, mut pos) = read_compact_size(data, pos)?;
    let len = spends
        .checked_mul(32)
        .zip(outputs.checked_mul(OUTPUT_SIZE))
        .and_then(|(s, o)| s.checked_add(o)?.checked_add(pos));
    if len != Some(data.len()) {
        return Err("Compact packet has the wrong length".into());
    }
    let nullifiers = (0..spends).map(|_| Nullifier(take(data, &mut pos))).collect();
    let outputs = (0..outputs)
        .map(|_| -> BoxResult<CompactOutput> {
            let cv = ValueCommitment::from_bytes_not_small_order(&take(data, &mut pos))
                .into_option()
                .ok_or("Invalid cv in compact packet")?;
            let cmu = ExtractedNoteCommitment::from_bytes(&take(data, &mut pos))
                .into_option()
                .ok_or("Invalid cmu in compact packet")?;
            Ok(CompactOutput {
                cv,
                cmu,
                epk: EphemeralKeyBytes(take(data, &mut pos)),
                enc_ciphertext: take(data, &mut pos),
                out_ciphertext: take(data, &mut pos),
            })
        })
        .collect::<BoxResult<_>>()?;
    Ok(StreamTx::Compact { nullifiers, outputs })
}

fn parse_stream_tx(tx_hex: &str) -> BoxResult<StreamTx> {
    let data = hex::decode(tx_hex).map_err(|_| "Tx hex is invalid")?;
    if data.first() == Some(&COMPACT_TX) {
        return parse_compact_tx(&data);
    }
    let tx = Transaction::read(Cursor::new(data), pivx_primitives::consensus::BranchId::Sapling)
        .map_err(|_| "Couldn't parse tx")?;
    Ok(StreamTx::Full(Box::new(tx)))
}

/// The keys `decrypt_transaction` tries on each output, for compact
/// packets.
struct CompactKeys {
    domain: SaplingDomain,
    ivk_external: PreparedIncomingViewingKey,
    ivk_internal: PreparedIncomingViewingKey,
    ovk: OutgoingViewingKey,
}

/// A stream transaction's Sapling parts and the outputs the wallet could
/// decrypt: (output index, note, memo, kind).
struct ScannedTx {
    nullifiers: Vec<Nullifier>,
    cmus: Vec<ExtractedNoteCommitment>,
    decrypted: Vec<(usize, Note, Option<String>, TransferType)>,
}

fn scan_tx(
    tx: &StreamTx,
    keys: &HashMap<AccountId, UnifiedFullViewingKey>,
    compact_keys: &CompactKeys,
    is_testnet: bool,
) -> ScannedTx {
    match tx {
        StreamTx::Full(tx) => {
            let decrypted = if is_testnet {
                decrypt_transaction(&TEST_NETWORK, BlockHeight::from_u32(320), tx, keys)
            } else {
                decrypt_transaction(&MAIN_NETWORK, BlockHeight::from_u32(320), tx, keys)
            };
            let bundle = tx.sapling_bundle();
            ScannedTx {
                nullifiers: bundle
                    .map(|b| b.shielded_spends().iter().map(|s| *s.nullifier()).collect())
                    .unwrap_or_default(),
                cmus: bundle
                    .map(|b| b.shielded_outputs().iter().map(|o| *o.cmu()).collect())
                    .unwrap_or_default(),
                decrypted: decrypted
                    .sapling_outputs()
                    .iter()
                    .map(|o| (o.index(), o.note().clone(), memo_text(o.memo().as_slice()), o.transfer_type()))
                    .collect(),
            }
        }
        StreamTx::Compact { nullifiers, outputs } => {
            let k = compact_keys;
            // In the order decrypt_transaction tries them.
            let decrypted = outputs
                .iter()
                .enumerate()
                .filter_map(|(i, o)| {
                    try_note_decryption(&k.domain, &k.ivk_external, o)
                        .map(|r| (r, TransferType::Incoming))
                        .or_else(|| {
                            try_note_decryption(&k.domain, &k.ivk_internal, o)
                                .map(|r| (r, TransferType::WalletInternal))
                        })
                        .or_else(|| {
                            try_output_recovery_with_ovk(&k.domain, &k.ovk, o, &o.cv, &o.out_ciphertext)
                                .map(|r| (r, TransferType::Outgoing))
                        })
                        .map(|((note, _, memo), kind)| (i, note, memo_text(&memo), kind))
                })
                .collect();
            ScannedTx {
                nullifiers: nullifiers.clone(),
                cmus: outputs.iter().map(|o| o.cmu).collect(),
                decrypted,
            }
        }
    }
}

/// Scan the bridge's shield stream: full raw transactions (`pivx` format)
/// or compact packets (`compact` format), which give the same notes, tree
/// and nullifiers. A compact wallet transaction comes back without txid.
pub fn handle_blocks(
    tree_hex: &str,
    blocks: Vec<Block>,
    enc_extfvk: &str,
    is_testnet: bool,
    comp_notes: Vec<JSSpendableNote>,
) -> BoxResult<HandleBlocksResult> {
    let mut tree = read_commitment_tree(tree_hex).map_err(|_| "Couldn't read commitment tree")?;
    let extfvk = decode_extended_full_viewing_key(enc_extfvk, is_testnet)?;
    let dfvk = extfvk.to_diversifiable_full_viewing_key();
    let key = UnifiedFullViewingKey::from_sapling_extended_full_viewing_key(extfvk)
        .map_err(|_| "Failed to create unified full viewing key")?;
    let mut comp_note = comp_notes
        .into_iter()
        .map(SpendableNote::from_js)
        .collect::<BoxResult<Vec<SpendableNote>>>()?;
    let hexes = blocks
        .into_iter()
        .enumerate()
        .flat_map(|(i, b)| b.txs.into_iter().map(move |h| (i as u32, h)))
        .collect::<Vec<_>>();

    let mut keys = HashMap::new();
    let nullif_key = key.sapling().ok_or("Cannot generate nullifier key")?.to_nk(Scope::External);
    keys.insert(AccountId::default(), key.clone());
    let compact_keys = CompactKeys {
        // PIVX uses pre-ZIP212 note encoding.
        domain: SaplingDomain::new(Zip212Enforcement::Off),
        ivk_external: PreparedIncomingViewingKey::new(&dfvk.to_ivk(Scope::External)),
        ivk_internal: PreparedIncomingViewingKey::new(&dfvk.to_ivk(Scope::Internal)),
        ovk: dfvk.fvk().ovk,
    };

    let txs = hexes
        .iter()
        .map(|(_, h)| parse_stream_tx(h))
        .collect::<BoxResult<Vec<_>>>()?;
    let scanned_txs = txs
        .par_iter()
        .map(|tx| scan_tx(tx, &keys, &compact_keys, is_testnet))
        .collect::<Vec<_>>();

    let mut nullifiers = vec![];
    let mut new_notes: Vec<SpendableNote> = vec![];
    let mut wallet_transactions = vec![];
    for (((block, hex_tx), tx), scanned) in hexes.iter().zip(&txs).zip(&scanned_txs) {
        let old_note_length = new_notes.len();
        let mut indices = vec![];
        let mut sent = vec![];
        handle_transaction(
            &mut tree,
            scanned,
            &nullif_key,
            &mut comp_note,
            &mut new_notes,
            &mut indices,
            &mut sent,
            is_testnet,
        )
        .map_err(|_| "Couldn't handle transaction")?;
        let tx_nullifiers = scanned.nullifiers.iter().map(|n| hex::encode(n.0)).collect::<Vec<_>>();
        let received_here = &new_notes[old_note_length..];
        let spends_ours = comp_note
            .iter()
            .chain(new_notes.iter())
            .any(|n| tx_nullifiers.contains(&n.nullifier));
        if !received_here.is_empty() || spends_ours || !sent.is_empty() {
            wallet_transactions.push(WalletTxDetail {
                txid: match tx {
                    StreamTx::Full(_) => raw_txid(hex_tx)?,
                    StreamTx::Compact { .. } => String::new(),
                },
                hex: hex_tx.clone(),
                block: *block,
                received: received_here
                    .iter()
                    .zip(&indices)
                    .map(|(n, &index)| ReceivedNote {
                        value: n.note.value().inner(),
                        address: encode_payment_address_internal(&n.note.recipient(), is_testnet),
                        memo: n.memo.clone(),
                        nullifier: n.nullifier.clone(),
                        index,
                    })
                    .collect(),
                sent,
                nullifiers: tx_nullifiers.clone(),
                commitments: scanned.cmus.iter().map(|c| hex::encode(c.to_bytes())).collect(),
            });
        }
        nullifiers.extend(tx_nullifiers);
    }

    let mut buff = Vec::new();
    write_commitment_tree(&tree, &mut buff).map_err(|_| "Cannot write tree to buffer")?;

    Ok(HandleBlocksResult {
        decrypted_notes: serialize_notes(comp_note, is_testnet)?,
        decrypted_new_notes: serialize_notes(new_notes, is_testnet)?,
        nullifiers,
        commitment_tree: hex::encode(buff),
        wallet_transactions,
    })
}

/// Add a tx's outputs to the commitment tree and our witnesses, and keep
/// the notes that are ours. The output index of each note added to
/// `new_witnesses` goes to `indices`; outputs we sent to others
/// (recovered with our ovk) go to `sent`.
#[allow(clippy::too_many_arguments)]
fn handle_transaction(
    tree: &mut CommitmentTree<Node, DEPTH>,
    scanned: &ScannedTx,
    nullif_key: &NullifierDerivingKey,
    witnesses: &mut [SpendableNote],
    new_witnesses: &mut Vec<SpendableNote>,
    indices: &mut Vec<u32>,
    sent: &mut Vec<SentNote>,
    is_testnet: bool,
) -> BoxResult<()> {
    for (i, cmu) in scanned.cmus.iter().enumerate() {
        let node = Node::from_cmu(cmu);
        tree.append(node).map_err(|_| "Failed to add cmu to tree")?;
        for SpendableNote { ref mut witness, .. } in witnesses.iter_mut().chain(new_witnesses.iter_mut()) {
            witness.append(node).map_err(|_| "Failed to add cmu to witness")?;
        }
        let Some((_, note, memo, kind)) = scanned.decrypted.iter().find(|d| d.0 == i) else {
            continue;
        };
        if matches!(kind, TransferType::Outgoing) {
            // Someone else's note: never ours to spend.
            sent.push(SentNote {
                value: note.value().inner(),
                address: encode_payment_address_internal(&note.recipient(), is_testnet),
                memo: memo.clone(),
                index: i as u32,
            });
        } else {
            let witness = IncrementalWitness::<Node, DEPTH>::from_tree(tree.clone());
            let nullifier = get_nullifier_from_note_internal(nullif_key, note, &witness)?;
            new_witnesses.push(SpendableNote {
                note: note.clone(),
                witness,
                nullifier,
                memo: memo.clone(),
            });
            indices.push(i as u32);
        }
    }
    Ok(())
}

pub fn get_nullifier_from_note_internal(
    nullif_key: &NullifierDerivingKey,
    note: &Note,
    witness: &IncrementalWitness<Node, DEPTH>,
) -> BoxResult<String> {
    let path = witness.path().ok_or("Cannot find witness path")?;
    Ok(hex::encode(note.nf(nullif_key, path.position().into()).0))
}

// ---------------------------------------------------------------------------
// Transaction building
// ---------------------------------------------------------------------------

#[derive(Serialize, Deserialize)]
pub struct JSTransaction {
    pub txid: String,
    pub txhex: String,
    /// Nullifiers of spent notes, or "txid,vout" of spent UTXOs.
    pub nullifiers: Vec<String>,
    pub fee: u64,
    pub amount: u64,
}

#[derive(Serialize, Deserialize)]
pub struct Utxo {
    pub txid: String,
    pub vout: u32,
    pub amount: u64,
    /// 32-byte secret key, hex.
    pub private_key: String,
    /// scriptPubKey of the spent output, hex.
    pub script: String,
}

#[derive(Serialize, Deserialize)]
pub struct JSTxOptions {
    pub notes: Option<Vec<JSSpendableNote>>,
    pub utxos: Option<Vec<Utxo>>,
    pub extsk: String,
    pub to_address: String,
    pub change_address: String,
    pub amount: u64,
    pub block_height: u32,
    pub is_testnet: bool,
    #[serde(default)]
    pub memo: String,
    /// Spend every given note/UTXO (coin control) instead of only as
    /// many as the amount needs.
    #[serde(default)]
    pub use_all_inputs: bool,
    /// The recipient pays the fee: it receives `amount - fee`.
    #[serde(default)]
    pub subtract_fee: bool,
    /// Pay `amount` to this output script (hex) instead of `to_address`:
    /// a proposal fee's OP_RETURN or a cold staking delegation. Shield
    /// notes only.
    #[serde(default)]
    pub to_script: Option<String>,
}

pub fn create_transaction(options: JSTxOptions) -> BoxResult<JSTransaction> {
    let JSTxOptions {
        notes,
        utxos,
        extsk,
        to_address,
        change_address,
        amount,
        block_height,
        is_testnet,
        memo,
        use_all_inputs,
        subtract_fee,
        to_script,
    } = options;
    if notes.is_some() && utxos.is_some() {
        Err("Notes and UTXOs were both provided")?;
    }
    let extsk = decode_extsk(&extsk, is_testnet)?;
    let network = if is_testnet { Network::TestNetwork } else { Network::MainNetwork };
    if let Some(script) = to_script {
        let mut notes: Vec<(Note, String)> =
            notes.ok_or("Paying to a script needs shield notes")?.into_iter().map(|n| (n.note, n.witness)).collect();
        notes.sort_by_key(|(note, _)| note.value().inner());
        return create_script_transaction(
            &notes,
            &extsk,
            hex::decode(script)?,
            &change_address,
            amount,
            BlockHeight::from_u32(block_height),
            network,
            Selection { use_all: use_all_inputs, subtract_fee },
        );
    }
    let input = if let Some(notes) = notes {
        let mut notes: Vec<(Note, String)> = notes.into_iter().map(|n| (n.note, n.witness)).collect();
        notes.sort_by_key(|(note, _)| note.value().inner());
        Either::Left(notes)
    } else if let Some(mut utxos) = utxos {
        utxos.sort_by_key(|u| u.amount);
        Either::Right(utxos)
    } else {
        Err("No input provided")?
    };
    create_transaction_internal(
        input,
        &extsk,
        &to_address,
        &change_address,
        amount,
        BlockHeight::from_u32(block_height),
        network,
        memo,
        Selection { use_all: use_all_inputs, subtract_fee },
    )
}

/// How inputs are chosen and who pays the fee.
#[derive(Clone, Copy)]
struct Selection {
    /// Spend every given input (coin control).
    use_all: bool,
    /// Take the fee out of the amount sent.
    subtract_fee: bool,
}

impl Selection {
    /// Inputs needed before selection may stop.
    fn needed(&self, amount: u64, fee: u64) -> u64 {
        if self.subtract_fee {
            amount
        } else {
            amount + fee
        }
    }

    /// Final amount sent and change, given the selected `total`.
    fn settle(&self, total: u64, amount: &mut u64, fee: u64) -> BoxResult<u64> {
        if self.subtract_fee {
            if total < *amount || *amount <= fee {
                Err("Not enough balance")?;
            }
            *amount -= fee;
        } else if total < *amount + fee {
            // The fee is only taken out of the amount when asked to.
            Err("Not enough balance to pay the fee")?;
        }
        Ok(total - *amount - fee)
    }
}

/// Error when a transparent recipient would get less than [`DUST_SATS`]
/// (only possible when the fee comes out of the amount).
const BELOW_DUST: &str = "Amount after the fee is below the dust limit";

/// Change and fee once transparent change below [`DUST_SATS`] goes to the
/// fee, as PIVX Core's wallet does: nodes would refuse the transaction
/// with such an output. Shield change has no such limit.
fn fold_dust_change(change: u64, fee: u64, transparent_change: bool) -> (u64, u64) {
    if transparent_change && change > 0 && change < DUST_SATS {
        (0, fee + change)
    } else {
        (change, fee)
    }
}

#[allow(clippy::too_many_arguments)]
fn create_transaction_internal(
    inputs: Either<Vec<(Note, String)>, Vec<Utxo>>,
    extsk: &ExtendedSpendingKey,
    to_address: &str,
    change_address: &str,
    mut amount: u64,
    block_height: BlockHeight,
    network: Network,
    memo: String,
    selection: Selection,
) -> BoxResult<JSTransaction> {
    let anchor = if let Either::Left(ref notes) = inputs {
        match notes.first() {
            Some((_, witness)) => {
                let witness = read_incremental_witness::<Node, _, DEPTH>(Cursor::new(hex::decode(witness)?))?;
                Anchor::from_bytes(witness.root().to_bytes()).into_option()
            }
            None => None,
        }
    } else {
        None
    };

    let mut builder = Builder::new(
        network,
        block_height,
        BuildConfig::Standard { sapling_anchor: Some(anchor.unwrap_or(Anchor::empty_tree())), orchard_anchor: None },
    );
    let mut signing_set = TransparentSigningSet::new();

    let to_shield = to_address.starts_with(network.hrp_sapling_payment_address());
    let change_to_shield = change_address.starts_with(network.hrp_sapling_payment_address());
    let sapling_output_count = 2;
    let transparent_output_count = u64::from(!to_shield) + u64::from(!change_to_shield);
    let (nullifiers, change, fee) = match inputs {
        Either::Left(notes) => choose_notes(
            &mut builder,
            &notes,
            extsk,
            &mut amount,
            transparent_output_count,
            sapling_output_count,
            selection,
        )?,
        Either::Right(utxos) => choose_utxos(
            &mut builder,
            &utxos,
            &mut amount,
            transparent_output_count,
            sapling_output_count,
            &mut signing_set,
            selection,
        )?,
    };
    let (change, fee) = fold_dust_change(change, fee, !change_to_shield);
    if !to_shield && amount < DUST_SATS {
        Err(BELOW_DUST)?;
    }
    let change = Zatoshis::from_u64(change).map_err(|_| "Invalid change")?;
    let send_amount = Zatoshis::from_u64(amount).map_err(|_| "Invalid Amount")?;
    // Outputs carry the wallet's outgoing viewing key (as PIVX Core does),
    // so the sender can later recover recipient, amount and memo.
    let ovk = extsk.to_diversifiable_full_viewing_key().fvk().ovk;
    match decode_generic_address(network, to_address)? {
        GenericAddress::Transparent(x) => builder.add_transparent_output(&x, send_amount).map_err(|_| "Failed to add output")?,
        GenericAddress::Shield(x) => builder
            .add_sapling_output::<FeeRule>(
                Some(ovk),
                x,
                send_amount,
                Memo::from_str(&memo).map(|m| m.encode()).unwrap_or(MemoBytes::empty()),
            )
            .map_err(|_| "Failed to add output")?,
    }
    if change.is_positive() {
        match decode_generic_address(network, change_address)? {
            GenericAddress::Transparent(x) => {
                builder.add_transparent_output(&x, change).map_err(|_| "Failed to add transparent change")?
            }
            GenericAddress::Shield(x) => builder
                .add_sapling_output::<FeeRule>(Some(ovk), x, change, MemoBytes::empty())
                .map_err(|_| "Failed to add shield change")?,
        }
    }

    let prover = prover::get()?;
    let mut tx = prove_transaction(builder, extsk.clone(), &signing_set, nullifiers, fee, prover)?;
    tx.amount = amount;
    Ok(tx)
}

/// Spend shield notes to one transparent output with a given script. The
/// generic builder only pays to addresses, so this assembles and signs the
/// transaction the way it does (`Builder::build`), with that output.
#[allow(clippy::too_many_arguments)]
fn create_script_transaction(
    notes: &[(Note, String)],
    extsk: &ExtendedSpendingKey,
    script: Vec<u8>,
    change_address: &str,
    mut amount: u64,
    block_height: BlockHeight,
    network: Network,
    selection: Selection,
) -> BoxResult<JSTransaction> {
    let (_, first_witness) = notes.first().ok_or("No shield notes to spend")?;
    let first_witness =
        read_incremental_witness::<Node, _, DEPTH>(Cursor::new(hex::decode(first_witness)?))?;
    let anchor = Anchor::from_bytes(first_witness.root().to_bytes())
        .into_option()
        .ok_or("Invalid anchor")?;
    let mut sapling = sapling::builder::Builder::new(
        zip212_enforcement(&network, block_height),
        BundleType::DEFAULT,
        anchor,
    );

    let shield_change = change_address.starts_with(network.hrp_sapling_payment_address());
    let transparent_outputs = if shield_change { 1 } else { 2 };
    // The fee estimate counts 34-byte transparent outputs; this one is
    // value + script length + script.
    let extra = 1000 * (9 + script.len() as u64).saturating_sub(34);

    let dfvk = extsk.to_diversifiable_full_viewing_key();
    let mut total = 0;
    let mut count = 0;
    let mut fee = 0;
    let mut nullifiers = vec![];
    for (note, witness) in notes {
        let witness = read_incremental_witness::<Node, _, DEPTH>(Cursor::new(hex::decode(witness)?))?;
        sapling
            .add_spend(dfvk.fvk().clone(), note.clone(), witness.path().ok_or("Commitment Tree is empty")?)
            .map_err(|_| "Failed to add sapling spend")?;
        let nullifier = note.nf(&dfvk.to_nk(Scope::External), witness.witnessed_position().into());
        nullifiers.push(hex::encode(nullifier.to_vec()));
        count += 1;
        fee = fee_calculator(0, transparent_outputs, count, 2) + extra;
        total += note.value().inner();
        if !selection.use_all && total >= selection.needed(amount, fee) {
            break;
        }
    }
    let change = selection.settle(total, &mut amount, fee)?;
    let (change, fee) = fold_dust_change(change, fee, !shield_change);

    let ovk = dfvk.fvk().ovk;
    let mut transparent = TransparentBuilder::empty();
    // A placeholder address: its script is replaced below.
    transparent
        .add_output(
            &TransparentAddress::PublicKeyHash([0; 20]),
            Zatoshis::from_u64(amount).map_err(|_| "Invalid Amount")?,
        )
        .map_err(|_| "Failed to add output")?;
    if change > 0 {
        match decode_generic_address(network, change_address)? {
            GenericAddress::Transparent(x) => transparent
                .add_output(&x, Zatoshis::from_u64(change).map_err(|_| "Invalid change")?)
                .map_err(|_| "Failed to add transparent change")?,
            GenericAddress::Shield(x) => sapling
                .add_output(Some(ovk), x, NoteValue::from_raw(change), None)
                .map_err(|_| "Failed to add shield change")?,
        }
    }
    let mut transparent = transparent.build().ok_or("No transparent output")?;
    transparent.vout[0].script_pubkey = Script(script);

    let prover = prover::get()?;
    let mut rng = OsRng;
    let (sapling, _) = sapling
        .build::<sapling::circuit::SpendParameters, sapling::circuit::OutputParameters, _, ZatBalance>(
            &[extsk.clone()],
            &mut rng,
        )
        .map_err(|e| format!("Failed to build the shield bundle: {e:?}"))?
        .ok_or("No shield spends")?;
    let sapling = sapling.create_proofs(&prover.1, &prover.0, &mut rng, ());

    let branch = BranchId::for_height(&network, block_height);
    let version = TxVersion::suggested_for_branch(branch);
    let expiry = block_height + DEFAULT_TX_EXPIRY_DELTA;
    let unauthed: TransactionData<pivx_primitives::transaction::Unauthorized> =
        TransactionData::from_parts(version, branch, 0, expiry, Some(transparent), None, Some(sapling), None);

    let txid_parts = unauthed.digest(TxIdDigester);
    let transparent = unauthed
        .transparent_bundle()
        .cloned()
        .map(|b| {
            b.apply_signatures(
                |input| *signature_hash(&unauthed, &SignableInput::Transparent(input), &txid_parts).as_ref(),
                &TransparentSigningSet::new(),
            )
        })
        .transpose()
        .map_err(|e| format!("Failed to sign: {e:?}"))?;
    let sighash = signature_hash(&unauthed, &SignableInput::Shielded, &txid_parts);
    let sapling = unauthed
        .sapling_bundle()
        .cloned()
        .map(|b| b.apply_signatures(&mut rng, *sighash.as_ref(), &[extsk.expsk.ask.clone()]))
        .transpose()
        .map_err(|e| format!("Failed to sign the shield spends: {e:?}"))?;
    let tx = TransactionData::from_parts(version, branch, 0, expiry, transparent, None, sapling, None).freeze()?;

    let mut tx_hex = vec![];
    tx.write(&mut tx_hex)?;
    Ok(JSTransaction { txid: tx.txid().to_string(), txhex: hex::encode(tx_hex), nullifiers, fee, amount })
}

fn choose_utxos(
    builder: &mut Builder<Network, impl ProverProgress>,
    utxos: &[Utxo],
    amount: &mut u64,
    transparent_output_count: u64,
    sapling_output_count: u64,
    signing_set: &mut TransparentSigningSet,
    selection: Selection,
) -> BoxResult<(Vec<String>, u64, u64)> {
    let mut total = 0;
    let mut used = vec![];
    let mut count = 0;
    let mut fee = 0;
    let secp = Secp256k1::new();
    for utxo in utxos {
        used.push(format!("{},{}", utxo.txid, utxo.vout));
        let key = SecretKey::from_slice(&hex::decode(&utxo.private_key)?)?;
        builder
            .add_transparent_input(
                key.public_key(&secp),
                OutPoint::new(
                    hex::decode(&utxo.txid)?
                        .into_iter()
                        .rev()
                        .collect::<Vec<_>>()
                        .try_into()
                        .map_err(|_| "failed to decode txid")?,
                    utxo.vout,
                ),
                TxOut {
                    value: Zatoshis::from_u64(utxo.amount).map_err(|_| "Invalid utxo amount")?,
                    script_pubkey: Script(hex::decode(&utxo.script)?),
                },
            )
            .map_err(|_| "Failed to use utxo")?;
        signing_set.add_key(key);
        count += 1;
        fee = fee_calculator(count, transparent_output_count, 0, sapling_output_count);
        total += utxo.amount;
        if !selection.use_all && total >= selection.needed(*amount, fee) {
            break;
        }
    }
    let change = selection.settle(total, amount, fee)?;
    Ok((used, change, fee))
}

fn choose_notes(
    builder: &mut Builder<Network, impl ProverProgress>,
    notes: &[(Note, String)],
    extsk: &ExtendedSpendingKey,
    amount: &mut u64,
    transparent_output_count: u64,
    sapling_output_count: u64,
    selection: Selection,
) -> BoxResult<(Vec<String>, u64, u64)> {
    let mut total = 0;
    let mut nullifiers = vec![];
    let mut count = 0;
    let mut fee = 0;
    let dfvk = extsk.to_diversifiable_full_viewing_key();
    for (note, witness) in notes {
        let witness = read_incremental_witness::<Node, _, DEPTH>(Cursor::new(hex::decode(witness)?))?;
        builder
            .add_sapling_spend::<FeeRule>(dfvk.fvk().clone(), note.clone(), witness.path().ok_or("Commitment Tree is empty")?)
            .map_err(|_| "Failed to add sapling spend")?;
        let nullifier = note.nf(&dfvk.to_nk(Scope::External), witness.witnessed_position().into());
        nullifiers.push(hex::encode(nullifier.to_vec()));
        count += 1;
        fee = fee_calculator(0, transparent_output_count, count, sapling_output_count);
        total += note.value().inner();
        if !selection.use_all && total >= selection.needed(*amount, fee) {
            break;
        }
    }
    let change = selection.settle(total, amount, fee)?;
    Ok((nullifiers, change, fee))
}

fn prove_transaction(
    builder: Builder<'_, Network, impl ProverProgress>,
    extsk: ExtendedSpendingKey,
    transparent_keys: &TransparentSigningSet,
    nullifiers: Vec<String>,
    fee: u64,
    prover: &ImplTxProver,
) -> BoxResult<JSTransaction> {
    let result = builder.build(
        transparent_keys,
        &[extsk],
        &[],
        OsRng,
        &prover.1,
        &prover.0,
        &FeeRule::non_standard(Zatoshis::from_u64(fee).map_err(|_| "Invalid fee")?),
    )?;
    let mut tx_hex = vec![];
    let tx = result.transaction();
    tx.write(&mut tx_hex)?;
    Ok(JSTransaction { txid: tx.txid().to_string(), txhex: hex::encode(tx_hex), nullifiers, fee, amount: 0 })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dust_change_goes_to_the_fee() {
        assert_eq!(fold_dust_change(DUST_SATS - 1, 1000, true), (0, 1000 + DUST_SATS - 1));
        assert_eq!(fold_dust_change(DUST_SATS, 1000, true), (DUST_SATS, 1000));
        assert_eq!(fold_dust_change(0, 1000, true), (0, 1000));
        // Shield change has no dust limit.
        assert_eq!(fold_dust_change(1, 1000, false), (1, 1000));
    }

    #[test]
    fn selection_settles_change_and_fee() {
        let plain = Selection { use_all: false, subtract_fee: false };
        let mut amount = 100;
        assert_eq!(plain.settle(150, &mut amount, 10).unwrap(), 40);
        assert_eq!(amount, 100);
        let mut amount = 100;
        assert!(plain.settle(105, &mut amount, 10).is_err());

        let subtract = Selection { use_all: false, subtract_fee: true };
        let mut amount = 100;
        assert_eq!(subtract.settle(150, &mut amount, 10).unwrap(), 50);
        assert_eq!(amount, 90);
        let mut amount = 10;
        assert!(subtract.settle(150, &mut amount, 10).is_err());
    }
}
