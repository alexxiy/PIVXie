//! Sapling proving parameters, loaded once from files the app downloaded.
use sapling::circuit::{OutputParameters, SpendParameters};
use std::error::Error;
use std::sync::OnceLock;

pub type ImplTxProver = (OutputParameters, SpendParameters);

static PROVER: OnceLock<ImplTxProver> = OnceLock::new();

pub const SAPLING_OUTPUT_SHA256: &str = "2f0ebbcbb9bb0bcffe95a397e7eba89c29eb4dde6191c339db88570e3f3fb0e4";
pub const SAPLING_SPEND_SHA256: &str = "8e48ffd23abb3a5fd9c5589204f32d9c31285a04b78096ba40a79b75677efc13";

pub fn load_from_files(output_path: &str, spend_path: &str) -> Result<(), Box<dyn Error>> {
    if PROVER.get().is_some() {
        return Ok(());
    }
    let output = std::fs::read(output_path)?;
    let spend = std::fs::read(spend_path)?;
    if sha256::digest(&output[..]) != SAPLING_OUTPUT_SHA256 {
        Err("Sha256 does not match for sapling output")?;
    }
    if sha256::digest(&spend[..]) != SAPLING_SPEND_SHA256 {
        Err("Sha256 does not match for sapling spend")?;
    }
    let prover = (
        OutputParameters::read(&output[..], false)?,
        SpendParameters::read(&spend[..], false)?,
    );
    let _ = PROVER.set(prover);
    Ok(())
}

pub fn is_loaded() -> bool {
    PROVER.get().is_some()
}

pub fn get() -> Result<&'static ImplTxProver, Box<dyn Error>> {
    Ok(PROVER.get().ok_or("Sapling prover not loaded")?)
}
