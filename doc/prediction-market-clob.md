# Prediction-Market CLOB Flow with Polymarket Conditional Tokens

This document explains how the current Clober CLOB contracts can run a prediction market using the Polymarket conditional token primitives that live under `src/polymarket`. It focuses on how the existing CLOB logic is used without modifying the matching engine, and it calls out optional changes that would make the experience closer to a fully collateralized prediction market.

## Components

- **OutcomeTokenWrapper (`src/polymarket/OutcomeTokenWrapper.sol`)** – Wraps a Polymarket ERC1155 outcome token into an ERC20 that the CLOB can trade. Holders can unwrap to the original ERC1155 outcome token at any time.
- **OutcomeTokenFactory (`src/polymarket/OutcomeTokenFactory.sol`)** – Deploys wrappers for specific ERC1155 outcome token IDs and records the backing Conditional Tokens contract.
- **ConditionalTokensHook (`src/polymarket/ConditionalTokensHook.sol`)** – Hook contract used in every prediction-market book. It validates the base/quote wrappers during `open`, enforces the trading cutoff and resolution checks during `make`/`take`, and lets the owner mark which outcome won. Market metadata keyed by `BookId` is stored here.
- **BookManager (`src/BookManager.sol`)** – Unchanged matching engine that expects two ERC20 currencies (`base` and `quote`) plus optional hook callbacks. Orders are still ERC721 positions minted by the book manager.

## Book composition

Each orderbook represents the market between two outcome tokens for the same Polymarket condition.

- `base` = ERC20 wrapper for one outcome (e.g., YES).
- `quote` = ERC20 wrapper for the complementary outcome (e.g., NO).
- Both wrappers must be created against the same Conditional Tokens contract; the hook rejects mismatches.
- Fee policies, tick spacing, and `unitSize` are configured exactly like a standard CLOB book.

## Lifecycle and flows

### 1) Prepare outcome wrappers

Create wrappers for the Polymarket outcome ERC1155s via `OutcomeTokenFactory.createOutcomeToken(tokenId, name, symbol)`. Anyone holding the ERC1155 can wrap by calling `depositFor`, and unwrap later with `withdrawTo`.

### 2) Open a book

Call `BookManager.open` through a locker as usual, passing a `BookKey` whose `base` and `quote` are the YES/NO wrapper addresses and whose `hooks` address is `ConditionalTokensHook`.

Encode `MarketCreationParams` into `hookData`:
- `conditionId`, `yesTokenId`, `noTokenId` – identify the Polymarket condition and its ERC1155 outcome IDs.
- `cutoffTime` – last timestamp when new orders or trades are allowed.
- `yesWrapper` / `noWrapper` – optional existing wrapper addresses; pass `address(0)` to deploy new ones via the factory.

`beforeOpen` in the hook records the market metadata and ensures the provided base/quote wrappers match the expected Conditional Tokens contract.

### 3) Place and fill orders

Use `BookManager.make` and `BookManager.take` exactly as in the base CLOB. The hook’s `beforeMake` and `beforeTake` simply check that:
- The market exists and is not resolved.
- The current timestamp is before `cutoffTime`.

Settlement is unchanged: traders pay and receive ERC20 outcome wrappers. Users who want the underlying ERC1155s (or final collateral after oracle resolution) unwrap through the wrapper contract; the CLOB itself only moves the ERC20 wrappers.

### 4) Cancel and claim

`beforeCancel` and `beforeClaim` ensure the order belongs to a known market but otherwise allow the normal flow. The CLOB still mints order NFTs and lets makers claim remaining liquidity the same way as any other market.

### 5) Resolution

Once the oracle resolves the Polymarket condition off-chain, the hook owner calls `resolveMarket(bookId, winningTokenId)` to mark which outcome won (`yesTokenId` or `noTokenId`). This blocks further `make`/`take` attempts because `_verifyOpen` will revert after resolution. Traders then unwrap their winning ERC20 outcome wrappers back to ERC1155 and redeem through the Conditional Tokens contract for collateral.

## How this works without core changes

The design keeps the matching engine and settlement math unchanged. By turning each Polymarket outcome into an ERC20, the CLOB can treat outcomes as standard fungible assets. The hook enforces market validity (matching wrappers, cutoff, resolution) so the engine does not need to know about conditional-token semantics. Because Polymarket redemption happens in the Conditional Tokens contract, no CLOB code changes are needed to cash-settle winners—holders of the winning wrapper simply unwrap and redeem post-resolution.

## Optional/next-step changes

If you want a closer parity with Polymarket’s single-collateral UX instead of direct outcome-token swaps, consider:

- **Collateralized order entry** – Extend hooks or `BookManager` to lock a single collateral token and mint/burn outcome wrappers on the fly when orders are made or taken, so users never touch ERC1155s directly.
- **Post-resolution gating** – Enhance `beforeClaim` to restrict claims on losing-side orders or to auto-redeem winning-side balances into collateral during claim.
- **Metadata surfacing** – Add view helpers or emitted events that expose question text, oracle address, and resolution timestamp alongside `BookId` so indexers can render prediction markets without off-chain mapping.
- **LP/payoff helpers** – Provide hook functions to batch unwrap and redeem to collateral for users after resolution, or to net out complementary outcome positions held by the same trader.

These improvements would add UX polish but are not required for the CLOB to list and trade Polymarket outcomes using the current contracts.

## Minting both sides when crossed buys meet

In Polymarket, two complementary **buy** intents (e.g., buy NO at 0.4 and buy YES at 0.6) can meet each other and immediately mint a YES/NO pair out of collateral. The current wrapper-only design cannot mint exposure on the fly because the CLOB expects pre-existing ERC20 balances. To reproduce the “mint both sides” behavior you need a collateral-aware hook + router that sit in front of the engine:

1. **Treat quote debits as collateral deposits.** Configure the book with base = YES wrapper and quote = NO wrapper as before, but have your locker/router intercept `_accountDelta` so that when the engine debits quote on `make`/`take` it actually pulls collateral (e.g., USDC) into a hook-held escrow instead of requiring pre-minted NO. You can do this by extending the locker used to call `BookManager` so it reroutes quote transfers to the hook contract.
2. **Mint outcome wrappers during matching.** Implement `afterTake` in `ConditionalTokensHook` (flip the permission bit in the constructor) to read the executed `takenUnit` and call `ConditionalTokens.splitPositions` for that many collateral units. Send the newly minted YES wrapper to the YES buyer and the NO wrapper to the NO buyer. Fees are still charged per the existing maker/taker policies; the hook just sources the underlying outcome supply.
3. **Handle unmatched liquidity.** When a buy order rests on the book, the router should hold its collateral in escrow. If the order is canceled or claimed, return the collateral; if it is filled, let `afterTake` consume the matching amount of escrow to mint the corresponding outcome token to the taker. This mirrors Polymarket’s “collateral-backed intention” without touching the matching math.

With this pattern, two opposing buys don’t need any pre-minted YES/NO. Their collateral flows into the hook, `afterTake` mints one YES and one NO for each matched unit, and the normal CLOB price/fee logic determines how much collateral each side spends for its share.

## Where splitting and merging fit

Polymarket users normally **split** collateral into complementary outcome tokens (e.g., YES/NO) and later **merge** those tokens back into the original collateral. The CLOB does not need to implement splitting/merging inside the matching engine because the Conditional Tokens contracts and the ERC20 wrappers already provide that lifecycle:

- **Splitting collateral** – Users interact directly with the Polymarket Conditional Tokens contract to split collateral into the ERC1155 outcome IDs. They can then wrap either side via `OutcomeTokenWrapper.depositFor` to obtain ERC20s tradable on the CLOB. No CLOB code path mints or burns outcome exposure.
- **Trading** – Once wrapped, outcome ERC20s behave like any fungible asset inside the CLOB. Normal `make`/`take` matching applies; partial fills, price-time priority, and fee logic are unchanged.
- **Merging (recombining)** – After trading, a user who holds complementary outcomes can unwrap both ERC20s back to ERC1155 and call `ConditionalTokens.mergePositions` to reclaim collateral. This happens entirely outside the CLOB; the hook does not need to track merged balances.

If you want the CLOB to offer **in-book splitting/merging convenience**, you could extend the hook to optionally wrap the Polymarket calls:

- Allow `beforeMake`/`beforeTake` to accept collateral plus a split/merge intent bit, then internally call `splitPositions` or `mergePositions` before forwarding ERC20 wrappers into the CLOB settlement flow.
- Add helper methods (outside the matching engine) that atomically split → trade → merge for users who want to stay in collateral terms.

These additions still avoid modifying the core matching engine: the engine only ever sees ERC20 balances, while the hook or auxiliary contracts handle translating collateral into outcome wrappers and vice versa.
