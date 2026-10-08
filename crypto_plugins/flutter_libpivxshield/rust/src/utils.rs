use crate::transaction::DEPTH;
use pivx_primitives::merkle_tree::{read_commitment_tree, HashSer};
use sapling::Node;
use std::error::Error;
use std::io::Cursor;

/// Sapling root of a hex-encoded commitment tree (as `finalsaplingroot`
/// bytes, before display byte-reversal).
pub fn get_sapling_root(tree_hex: &str) -> Result<String, Box<dyn Error>> {
    let buff = Cursor::new(hex::decode(tree_hex)?);
    let tree = read_commitment_tree::<Node, _, DEPTH>(buff)?;
    let mut root = Vec::new();
    tree.root().write(&mut root)?;
    Ok(hex::encode(root))
}
