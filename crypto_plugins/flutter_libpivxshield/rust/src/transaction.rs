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
use pivx_client_backend::data_api::DecryptedTransaction;
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
use sapling::note_encryption::{try_sapling_note_decryption, PreparedIncomingViewingKey, Zip212Enforcement};
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
use zcash_note_encryption::{EphemeralKeyBytes, ShieldedOutput, ENC_CIPHERTEXT_SIZE};
use zcash_transparent::bundle::{OutPoint, TxOut};

pub const DEPTH: u8 = 32;

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
    pub txs: Vec<String>,
}

#[derive(Serialize, Deserialize)]
pub struct CompactBlock {
    pub txs: Vec<CompactTxData>,
}

#[derive(Serialize, Deserialize)]
pub struct CompactTxData {
    pub nullifiers: Vec<String>,
    pub outputs: Vec<CompactOutputData>,
}

#[derive(Serialize, Deserialize)]
pub struct CompactOutputData {
    #[serde(with = "serde_bytes")]
    pub cmu: Vec<u8>,
    #[serde(with = "serde_bytes")]
    pub epk: Vec<u8>,
    #[serde(with = "serde_bytes")]
    pub enc_ciphertext: Vec<u8>,
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
    pub txid: String,
    pub hex: String,
    pub received: Vec<ReceivedNote>,
    #[serde(default)]
    pub sent: Vec<SentNote>,
    /// All nullifiers revealed by the tx (the caller matches its own).
    pub nullifiers: Vec<String>,
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

/// Scan full raw transactions (the bridge's default `pivx` stream format).
pub fn handle_blocks(
    tree_hex: &str,
    blocks: Vec<Block>,
    enc_extfvk: &str,
    is_testnet: bool,
    comp_notes: Vec<JSSpendableNote>,
) -> BoxResult<HandleBlocksResult> {
    let mut tree = read_commitment_tree(tree_hex).map_err(|_| "Couldn't read commitment tree")?;
    let extfvk = decode_extended_full_viewing_key(enc_extfvk, is_testnet)?;
    let key = UnifiedFullViewingKey::from_sapling_extended_full_viewing_key(extfvk)
        .map_err(|_| "Failed to create unified full viewing key")?;
    let mut comp_note = comp_notes
        .into_iter()
        .map(SpendableNote::from_js)
        .collect::<BoxResult<Vec<SpendableNote>>>()?;
    let hexes = blocks.into_iter().flat_map(|b| b.txs).collect::<Vec<_>>();

    let mut keys = HashMap::new();
    let nullif_key = key.sapling().ok_or("Cannot generate nullifier key")?.to_nk(Scope::External);
    keys.insert(AccountId::default(), key.clone());

    let txs = hexes
        .iter()
        .map(|h| -> BoxResult<(&String, Transaction)> {
            let tx = Transaction::read(
                Cursor::new(hex::decode(h).map_err(|_| "Tx hex is invalid")?),
                pivx_primitives::consensus::BranchId::Sapling,
            )
            .map_err(|_| "Couldn't parse tx")?;
            Ok((h, tx))
        })
        .collect::<BoxResult<Vec<_>>>()?;

    let decrypted_txs = txs
        .par_iter()
        .map(|(_, tx)| {
            if is_testnet {
                decrypt_transaction(&TEST_NETWORK, BlockHeight::from_u32(320), tx, &keys)
            } else {
                decrypt_transaction(&MAIN_NETWORK, BlockHeight::from_u32(320), tx, &keys)
            }
        })
        .collect::<Vec<_>>();

    let mut nullifiers = vec![];
    let mut new_notes: Vec<SpendableNote> = vec![];
    let mut wallet_transactions = vec![];
    for ((hex_tx, tx), decrypted_tx) in txs.iter().zip(decrypted_txs) {
        let old_note_length = new_notes.len();
        let mut indices = vec![];
        let mut sent = vec![];
        let tx_nullifiers = handle_transaction(
            &mut tree,
            tx,
            &decrypted_tx,
            &nullif_key,
            &mut comp_note,
            &mut new_notes,
            &mut indices,
            &mut sent,
            is_testnet,
        )
        .map_err(|_| "Couldn't handle transaction")?
            .into_iter()
            .map(|n| hex::encode(n.0))
            .collect::<Vec<_>>();
        let received_here = &new_notes[old_note_length..];
        let spends_ours = comp_note
            .iter()
            .chain(new_notes.iter())
            .any(|n| tx_nullifiers.contains(&n.nullifier));
        if !received_here.is_empty() || spends_ours || !sent.is_empty() {
            wallet_transactions.push(WalletTxDetail {
                txid: tx.txid().to_string(),
                hex: (*hex_tx).clone(),
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

struct CompactOutputRef {
    epk: EphemeralKeyBytes,
    cmu: [u8; 32],
    enc_ciphertext: [u8; ENC_CIPHERTEXT_SIZE],
}

impl ShieldedOutput<sapling::note_encryption::SaplingDomain, ENC_CIPHERTEXT_SIZE> for CompactOutputRef {
    fn ephemeral_key(&self) -> EphemeralKeyBytes {
        self.epk.clone()
    }
    fn cmstar_bytes(&self) -> [u8; 32] {
        self.cmu
    }
    fn enc_ciphertext(&self) -> &[u8; ENC_CIPHERTEXT_SIZE] {
        &self.enc_ciphertext
    }
}

struct PreparedCompactOutput {
    node: Node,
    decrypted: Option<(Note, Option<String>)>,
}

fn prepare_compact_output(o: &CompactOutputData, ivk: &PreparedIncomingViewingKey) -> Result<PreparedCompactOutput, String> {
    let cmu_bytes: [u8; 32] = o.cmu.as_slice().try_into().map_err(|_| "invalid cmu length".to_string())?;
    let epk_bytes: [u8; 32] = o.epk.as_slice().try_into().map_err(|_| "invalid epk length".to_string())?;
    let enc_bytes: [u8; ENC_CIPHERTEXT_SIZE] = o
        .enc_ciphertext
        .as_slice()
        .try_into()
        .map_err(|_| "invalid enc_ciphertext length".to_string())?;
    let cmu = ExtractedNoteCommitment::from_bytes(&cmu_bytes)
        .into_option()
        .ok_or_else(|| "invalid cmu".to_string())?;
    let node = Node::from_cmu(&cmu);
    let r = CompactOutputRef { epk: EphemeralKeyBytes(epk_bytes), cmu: cmu_bytes, enc_ciphertext: enc_bytes };
    // PIVX uses pre-ZIP212 note encoding.
    let decrypted = try_sapling_note_decryption(ivk, &r, Zip212Enforcement::Off)
        .map(|(note, _addr, memo_bytes)| (note, memo_text(memo_bytes.as_slice())));
    Ok(PreparedCompactOutput { node, decrypted })
}

/// Scan the bridge's compact (0x04) stream. No raw txs, so no
/// per-transaction details are returned.
pub fn handle_blocks_compact(
    tree_hex: &str,
    blocks: Vec<CompactBlock>,
    enc_extfvk: &str,
    is_testnet: bool,
    comp_notes: Vec<JSSpendableNote>,
) -> BoxResult<HandleBlocksResult> {
    let mut tree = read_commitment_tree(tree_hex).map_err(|_| "Couldn't read commitment tree")?;
    let extfvk = decode_extended_full_viewing_key(enc_extfvk, is_testnet)?;
    let ivk = PreparedIncomingViewingKey::new(&extfvk.to_diversifiable_full_viewing_key().fvk().vk.ivk());
    let nullif_key = extfvk.to_diversifiable_full_viewing_key().to_nk(Scope::External);
    let mut existing = comp_notes.into_iter().map(SpendableNote::from_js).collect::<BoxResult<Vec<_>>>()?;
    let mut nullifiers = vec![];
    let mut new_notes: Vec<SpendableNote> = vec![];
    for b in &blocks {
        for tx in &b.txs {
            for nf in &tx.nullifiers {
                nullifiers.push(nf.to_lowercase());
            }
        }
    }
    let all_outputs: Vec<&CompactOutputData> =
        blocks.iter().flat_map(|b| b.txs.iter()).flat_map(|t| t.outputs.iter()).collect();
    let prepared = all_outputs
        .par_iter()
        .map(|&o| prepare_compact_output(o, &ivk))
        .collect::<Result<Vec<_>, String>>()?;
    for prep in &prepared {
        tree.append(prep.node).map_err(|_| "Failed to add cmu to tree")?;
        for note in existing.iter_mut().chain(new_notes.iter_mut()) {
            note.witness.append(prep.node).map_err(|_| "Failed to add cmu to witness")?;
        }
        if let Some((note, memo)) = &prep.decrypted {
            let witness = IncrementalWitness::<Node, DEPTH>::from_tree(tree.clone());
            let nullifier = get_nullifier_from_note_internal(&nullif_key, note, &witness)?;
            new_notes.push(SpendableNote { note: note.clone(), witness, nullifier, memo: memo.clone() });
        }
    }
    let mut buff = Vec::new();
    write_commitment_tree(&tree, &mut buff).map_err(|_| "Cannot write tree to buffer")?;
    Ok(HandleBlocksResult {
        decrypted_notes: serialize_notes(existing, is_testnet)?,
        decrypted_new_notes: serialize_notes(new_notes, is_testnet)?,
        nullifiers,
        commitment_tree: hex::encode(buff),
        wallet_transactions: vec![],
    })
}

/// Add a tx to the commitment tree; witness our outputs; return its nullifiers.
/// The output index of each note added to `new_witnesses` goes to `indices`;
/// outputs we sent to others (recovered with our ovk) go to `sent`.
#[allow(clippy::too_many_arguments)]
pub fn handle_transaction(
    tree: &mut CommitmentTree<Node, DEPTH>,
    tx: &Transaction,
    decrypted_tx: &DecryptedTransaction<'_, AccountId>,
    nullif_key: &NullifierDerivingKey,
    witnesses: &mut [SpendableNote],
    new_witnesses: &mut Vec<SpendableNote>,
    indices: &mut Vec<u32>,
    sent: &mut Vec<SentNote>,
    is_testnet: bool,
) -> BoxResult<Vec<Nullifier>> {
    let mut nullifiers: Vec<Nullifier> = vec![];
    if let Some(sapling) = tx.sapling_bundle() {
        for x in sapling.shielded_spends() {
            nullifiers.push(*x.nullifier());
        }
        for (i, out) in sapling.shielded_outputs().iter().enumerate() {
            tree.append(Node::from_cmu(out.cmu())).map_err(|_| "Failed to add cmu to tree")?;
            for SpendableNote { ref mut witness, .. } in witnesses.iter_mut().chain(new_witnesses.iter_mut()) {
                witness.append(Node::from_cmu(out.cmu())).map_err(|_| "Failed to add cmu to witness")?;
            }
            for output in decrypted_tx.sapling_outputs() {
                if output.index() == i && output.transfer_type() == TransferType::Outgoing {
                    // Someone else's note: never ours to spend.
                    sent.push(SentNote {
                        value: output.note().value().inner(),
                        address: encode_payment_address_internal(&output.note().recipient(), is_testnet),
                        memo: memo_text(output.memo().as_slice()),
                        index: i as u32,
                    });
                    break;
                }
                if output.index() == i {
                    let note = output.note();
                    let witness = IncrementalWitness::<Node, DEPTH>::from_tree(tree.clone());
                    let nullifier = get_nullifier_from_note_internal(nullif_key, note, &witness)?;
                    new_witnesses.push(SpendableNote {
                        note: note.clone(),
                        witness,
                        nullifier,
                        memo: memo_text(output.memo().as_slice()),
                    });
                    indices.push(i as u32);
                    break;
                }
            }
        }
    }
    Ok(nullifiers)
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
    } = options;
    if notes.is_some() && utxos.is_some() {
        Err("Notes and UTXOs were both provided")?;
    }
    let extsk = decode_extsk(&extsk, is_testnet)?;
    let network = if is_testnet { Network::TestNetwork } else { Network::MainNetwork };
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

    let (mut transparent_output_count, sapling_output_count) =
        if to_address.starts_with(network.hrp_sapling_payment_address()) { (0, 2) } else { (1, 2) };
    if !change_address.starts_with(network.hrp_sapling_payment_address()) {
        transparent_output_count += 1;
    }
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

fn choose_utxos(
    builder: &mut Builder<Network, impl ProverProgress>,
    utxos: &[Utxo],
    amount: &mut u64,
    transparent_output_count: u64,
    sapling_output_count: u64,
    signing_set: &mut TransparentSigningSet,
    selection: Selection,
) -> BoxResult<(Vec<String>, Zatoshis, u64)> {
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
    let change = Zatoshis::from_u64(change).map_err(|_| "Invalid change")?;
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
) -> BoxResult<(Vec<String>, Zatoshis, u64)> {
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
    let change = Zatoshis::from_u64(change).map_err(|_| "Invalid change")?;
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
