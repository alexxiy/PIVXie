//! PIVX Shield (Sapling) wallet core with a C ABI for Flutter (dart:ffi).
//!
//! One entry point, `pivx_shield_call(method, args_json)`, returns a JSON
//! string `{"ok": <result>}` or `{"err": "<message>"}` that the caller
//! must release with `pivx_shield_free`. Panics are caught and reported
//! as errors so they never unwind across the FFI boundary.
mod checkpoint;
mod keys;
mod mainnet_checkpoints;
mod prover;
mod testnet_checkpoints;
pub mod transaction;
mod utils;

#[cfg(test)]
mod tests;

use serde::Deserialize;
use serde_json::{json, Value};
use std::ffi::{CStr, CString};
use std::os::raw::c_char;

type CallResult = Result<Value, String>;

fn parse<T: for<'de> Deserialize<'de>>(args: &str) -> Result<T, String> {
    serde_json::from_str(args).map_err(|e| format!("invalid arguments: {e}"))
}

fn err<E: std::fmt::Display>(e: E) -> String {
    e.to_string()
}

#[derive(Deserialize)]
struct SeedArgs {
    seed_hex: String,
    coin_type: u32,
    #[serde(default)]
    account_index: u32,
}

#[derive(Deserialize)]
struct KeyArgs {
    key: String,
    is_testnet: bool,
}

#[derive(Deserialize)]
struct NextAddressArgs {
    extfvk: String,
    diversifier_index: Vec<u8>,
    is_testnet: bool,
}

#[derive(Deserialize)]
struct CheckpointArgs {
    height: i32,
    is_testnet: bool,
}

#[derive(Deserialize)]
struct HandleBlocksArgs {
    tree: String,
    blocks: Vec<transaction::Block>,
    extfvk: String,
    is_testnet: bool,
    notes: Vec<transaction::JSSpendableNote>,
}

#[derive(Deserialize)]
struct HandleCompactArgs {
    tree: String,
    blocks: Vec<transaction::CompactBlock>,
    extfvk: String,
    is_testnet: bool,
    notes: Vec<transaction::JSSpendableNote>,
}

#[derive(Deserialize)]
struct TreeArgs {
    tree: String,
}

#[derive(Deserialize)]
struct ProverArgs {
    output_path: String,
    spend_path: String,
}

#[derive(Deserialize)]
struct AddressArgs {
    address: String,
    is_testnet: bool,
}

fn dispatch(method: &str, args: &str) -> CallResult {
    match method {
        "version" => Ok(json!(env!("CARGO_PKG_VERSION"))),
        "generate_extsk" => {
            let a: SeedArgs = parse(args)?;
            let seed = hex::decode(&a.seed_hex).map_err(err)?;
            keys::generate_extended_spending_key_from_seed(&seed, a.coin_type, a.account_index)
                .map(Value::from)
                .map_err(err)
        }
        "generate_extfvk" => {
            let a: KeyArgs = parse(args)?;
            keys::generate_extended_full_viewing_key(&a.key, a.is_testnet).map(Value::from).map_err(err)
        }
        "default_address" => {
            let a: KeyArgs = parse(args)?;
            keys::generate_default_payment_address(&a.key, a.is_testnet)
                .map_err(err)
                .and_then(|v| serde_json::to_value(v).map_err(err))
        }
        "next_address" => {
            let a: NextAddressArgs = parse(args)?;
            keys::generate_next_shielding_payment_address(&a.extfvk, &a.diversifier_index, a.is_testnet)
                .map_err(err)
                .and_then(|v| serde_json::to_value(v).map_err(err))
        }
        "validate_address" => {
            let a: AddressArgs = parse(args)?;
            Ok(json!(keys::is_valid_shield_address(&a.address, a.is_testnet)))
        }
        "closest_checkpoint" => {
            let a: CheckpointArgs = parse(args)?;
            let (height, tree) = checkpoint::get_checkpoint(a.height, a.is_testnet);
            Ok(json!({ "height": height, "tree": tree }))
        }
        "handle_blocks" => {
            let a: HandleBlocksArgs = parse(args)?;
            transaction::handle_blocks(&a.tree, a.blocks, &a.extfvk, a.is_testnet, a.notes)
                .map_err(err)
                .and_then(|v| serde_json::to_value(v).map_err(err))
        }
        "handle_blocks_compact" => {
            let a: HandleCompactArgs = parse(args)?;
            transaction::handle_blocks_compact(&a.tree, a.blocks, &a.extfvk, a.is_testnet, a.notes)
                .map_err(err)
                .and_then(|v| serde_json::to_value(v).map_err(err))
        }
        "sapling_root" => {
            let a: TreeArgs = parse(args)?;
            utils::get_sapling_root(&a.tree).map(Value::from).map_err(err)
        }
        "load_prover" => {
            let a: ProverArgs = parse(args)?;
            prover::load_from_files(&a.output_path, &a.spend_path).map(|_| json!(true)).map_err(err)
        }
        "prover_is_loaded" => Ok(json!(prover::is_loaded())),
        "create_transaction" => {
            let a: transaction::JSTxOptions = parse(args)?;
            transaction::create_transaction(a)
                .map_err(err)
                .and_then(|v| serde_json::to_value(v).map_err(err))
        }
        _ => Err(format!("unknown method: {method}")),
    }
}

/// Call `method` with JSON `args`. Returns a heap-allocated JSON string
/// that must be released with [`pivx_shield_free`].
///
/// # Safety
/// `method` and `args` must be valid NUL-terminated UTF-8 C strings.
#[no_mangle]
pub unsafe extern "C" fn pivx_shield_call(method: *const c_char, args: *const c_char) -> *mut c_char {
    let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let method = CStr::from_ptr(method).to_str().map_err(err)?;
        let args = CStr::from_ptr(args).to_str().map_err(err)?;
        dispatch(method, args)
    }));
    let response = match outcome {
        Ok(Ok(v)) => json!({ "ok": v }),
        Ok(Err(e)) => json!({ "err": e }),
        Err(panic) => {
            let msg = panic
                .downcast_ref::<&str>()
                .map(|s| s.to_string())
                .or_else(|| panic.downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "panic".into());
            json!({ "err": format!("panic: {msg}") })
        }
    };
    CString::new(response.to_string()).unwrap_or_default().into_raw()
}

/// Release a string returned by [`pivx_shield_call`].
///
/// # Safety
/// `s` must come from `pivx_shield_call` and not be freed twice.
#[no_mangle]
pub unsafe extern "C" fn pivx_shield_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}
