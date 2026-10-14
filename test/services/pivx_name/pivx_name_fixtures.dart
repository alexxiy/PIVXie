/// Real answers from the production PIVX.name server (2026-10-14), and the
/// anchor contract's root they fold to (epoch 1).
library;

const liveRoot =
    "314f70fe112e800cd3a13a00776960eb74715702136a75f310b60d992d7d130b";

const liveTarget =
    "ps19wd4eft4mw2mlwad6tjrny5hlvtdxymatu2e3dge7jr6scqask0llvdsa3xhx06499vmzymatxr";

const liveOwnerKey =
    "3757ee1a8b3f10353ca6edd47b66920392b02e323dca3f3edddb5de142079a53";

/// donate.pivx's address: real, well formed, and not alexxiy.pivx's.
const otherShieldAddress =
    "ps10ayxgy96kzhzwe0mtd53lraj4hxsu9scyh730vwxna0ul2yxw2pwxvdceu8tajd40fhvkmx3dyz";

/// alexxiy.pivx, with [changes] applied.
Map<String, dynamic> liveRecord([Map<String, Object?> changes = const {}]) => {
  "domain_name": "alexxiy.pivx",
  "target_address": liveTarget,
  "owner_pubkey": liveOwnerKey,
  "price": 0,
  "nonce": 1786604913,
  "smt_root": liveRoot,
  "merkle_proof": [
    "ce7b953670410e6a28bb669dbf36c92b3a1d3be8ad1053b9dfcf730049fe57ff",
    "8de7514f0d3a019a6cb017618c3c8f2774aaf063b47a0ed1fcc52e4a7080fa71",
    "48830e34174714ac8990c825d5f9b8751713207bf370b100c3e956cd16efc4cc",
  ],
  "proof_depth": 3,
  "proof_terminal": "Occupied",
  ...changes,
};

/// donate.pivx: listed for sale, so its price is not zero.
Map<String, dynamic> donateRecord() => {
  "domain_name": "donate.pivx",
  "target_address": otherShieldAddress,
  "owner_pubkey": liveOwnerKey,
  "price": 2499999000000,
  "nonce": 1786606068,
  "smt_root": liveRoot,
  "merkle_proof": [
    "6160f60b33554064fd2c90e060b47b9f41edfe52510d4846a938ff8740ef1990",
    "6fa1ad66d943f13c441b9c613b8cdb79228094ec8d412a99a2e25a5764a79715",
  ],
  "proof_depth": 2,
  "proof_terminal": "Occupied",
};
