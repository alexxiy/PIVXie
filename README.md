# PIVXie

PIVXie is a non-custodial mobile wallet for [PIVX](https://pivx.org). Your recovery phrase and keys never leave your device. The app talks to the PIVX network through a [pivx-bridge](https://github.com/PIVX-Labs/pivx-bridge) server, and you can point it at your own.

Website: [pivxie.me](https://pivxie.me)

## Features

- **SHIELD**: private Sapling transactions. Shield, unshield and send privately, with an optional encrypted memo.
- **Cold staking**: delegate PIV to a staker and earn staking rewards while the coins stay in your wallet. Pick a staker from [masternode.space](https://masternode.space) or use your own node. Undelegate at any time.
- **Masternodes**: set up a masternode from the wallet (send the collateral, generate or paste the masternode key), start it, and follow its status and rewards.
- **Governance**: browse budget proposals, vote with your masternodes, submit your own proposal, and track budget payments.
- **History**: staking rewards, masternode rewards, proposal payments, delegations and shield transactions are labelled, and you can filter by each type. Rewards show how many confirmations are left until they mature.
- **Coin control**, an **address book** and **`pivx:` payment links**.
- **Backups**: encrypted backups of all wallets and settings, plus automatic backups.
- **Security**: PIN and fingerprint lock, and optional Tor for every connection.
- Open source (GPLv3), with no ads and no tracking.

PIVX logic follows [MyPIVXWallet](https://github.com/PIVX-Labs/MyPIVXWallet) and [PIVX Core](https://github.com/PIVX-Project/PIVX). The shield code is a Rust port of [pivx-shield](https://github.com/PIVX-Labs/pivx-shield) (`crypto_plugins/flutter_libpivxshield`).

## Platforms

- **Android**: the main platform (targets Android 17, API 37).
- **iOS**: builds on a macOS host.
- **Desktop** (Linux, Windows, macOS): the project still has the desktop targets and packaging files (`flatpak/`, `appimage/`), but desktop builds are untested and the shield library is built for Android and iOS only.

## Building

See the [build instructions](docs/building.md).

## Credits

PIVXie is built on [Stack Wallet](https://github.com/cypherstack/stack_wallet) by Cypher Stack, which is licensed under GPLv3. Source files keep their original copyright notices.

## License

[GPLv3](LICENSE)
