# Sepolia deployment handoff

## Status and fixed launch

This handoff describes the settler-reward redeployment after Sepolia launch 1277. Build, test, and independent review evidence for the new source is recorded in `ADAPTATION.md` and `docs/SETTLER_INDEPENDENT_REVIEW.md`. The factory rehearsal runs on chain ID 11155111 with no code at the external dependency addresses. No live transactions or GitHub publication were performed by this worker. No live contract addresses are claimed. The network launch service performs the separate manifest, final independent review, publication, bytecode deployment, and confirmed-address handoff.

Do not deploy to another network. The contracts themselves contain no hardcoded chain restriction: the oracle domain uses `block.chainid`, and the launch policy must enforce **Sepolia only**. The rehearsal factory explicitly rejects other chains. No additional application token, proxy, liquidity pool, initializer transaction, or linked library is required.

The stale launch-1277 `launch.json` has been removed: the separate manifest stage must generate it for this constructor set. Constructor bytes are also encoded in `script/SepoliaParameters.sol`. All external values below come from the approved task, not inferred network tables.

## Deployment order and constructor parameters

1. **VerdictBurnVault()** — no arguments.
2. **VerdictOracle(address intake, address asset, address signer, bytes32 actionId, uint256 price, address owner, uint256 configDelay)**:

| Parameter | Value |
| --- | --- |
| intake | `0xa43e6f75ee006411f79ac1c84120606c2330de82` |
| asset | `0x44a1cd38474fb1748400e7deb5f8d786cce3f89a` |
| signer | `0x5598aa9146215bc13eb26f2c692ad1461fd32982` |
| actionId | `0x6f7261636c652e72657175657374406f7261636c652d31000000000000000000` |
| price | `500000000000000000` (0.5 IMD at 18 decimals) |
| owner | `0x397dacb1ee8e9a8ce5196988958f56bde0a0a312` |
| configDelay | `0` |

The action is the right-padded UTF-8 value `oracle.request@oracle-1`, not its keccak hash. This launch uses Intake version 2. VerdictOracle is unchanged and continues to use `request`, whose callback is called by the Intake itself. It does not use `requestWithFailure`.

3. **VerdictMarkets(address oracle, address collateral, address treasury, address burnSink, address guardian, uint16 creatorFeeBps, uint16 burnFeeBps, uint16 treasuryFeeBps, uint256 maxPoolPerMarket, uint256 maxSettlerReward)**:

| Parameter | Value |
| --- | --- |
| oracle | Address of the VerdictOracle deployed in step 2 (`$contract:VerdictOracle`) |
| collateral | `0x44a1cd38474fb1748400e7deb5f8d786cce3f89a` |
| treasury | `0x397dacb1ee8e9a8ce5196988958f56bde0a0a312` |
| burnSink | Address of the VerdictBurnVault deployed in step 1 (`$contract:VerdictBurnVault`) |
| guardian | `0x397dacb1ee8e9a8ce5196988958f56bde0a0a312` |
| creatorFeeBps | `100` (1%) |
| burnFeeBps | `50` (0.5%) |
| treasuryFeeBps | `50` (0.5%) |
| maxPoolPerMarket | `500000000000000000000` (500 IMD at 18 decimals) |
| maxSettlerReward | `250000000000000000` (0.25 IMD at 18 decimals) |

The provided owner fills every `$owner` reference. The factory and transaction sender receive no application authority. Constructor validation never calls the Intake, oracle, collateral, or signer, and is compatible with the empty-chain deployment floor. All constructors are nonpayable.

## Verification by the launch operator

Run the root `forge build`, `forge test`, and `forge fmt --check` with the pinned compiler and settings. Review the independent report and final manifest together, including all privileged and recipient arguments. Confirm the live RPC chain ID is 11155111, the supplied Intake and IMD have code, IMD identity/decimals match, `Intake.priceOf(actionId, IMD)` still equals the configured price, and the operator's oracle service still signs for the supplied signer and this consumer domain. A read-only batch query to `https://ethereum-sepolia-rpc.publicnode.com` for chain ID and code at the v2 Intake and TestIMD addresses on 2026-10-11 returned HTTP 403; no current live dependency result is asserted here.

The deployment service should deploy the built bytecodes in the stated order with zero native value, record transaction hashes, confirm receipts and runtime bytes, then verify source using exactly the repository build settings. Verify all constructor getters and the initial roles against the tables. Record the confirmed address set in the launch handoff consumed by the separate website job. Do not insert example/test addresses into live configuration.

## After launch

- **Guardian (`$owner`):** call `setCreatorAllowed(creator, true)` for each admitted creator, or call `disableAllowlist()` to make creation permanently permissionless. The initial allowlist is on and empty. `pause()`/`unpause()` affect only market creation and betting. `transferGuardian(next)` requires `next` to call `acceptGuardian()`. Renunciation requires unpaused entry and a disabled allowlist; call `disableAllowlist()` before renouncing.
- **Oracle owner (`$owner`):** monitor Intake availability, action/version, price, collateral asset, and signer changes through the IdentityMD operator. Submit all five values in `proposeConfig(Config)` and then `acceptConfig()` after the configured delay. This launch delay is zero: the owner can rotate Intake and signer in the same block and control answers to future asks, even for markets with existing bets. Bettors must trust this owner as well as the service. No post-deployment initialization is needed. `transferOwnership(next)` requires the next owner to call `acceptOwnership()`. Old requests continue to trust their recorded Intake and signer.
- **Creators:** acquire IMD, approve the exact intended bounty to VerdictMarkets, and publish valid primary/escalation JSON. Append `settlerReward` to Params; it must be at most `maxSettlerReward`. Both requested and received bounty must cover `2 * oracle.price() + 5 * settlerReward`. Use already-confirmed absolute data block intervals and the protocol's canonical question hash. The two bodies must describe the same market terms; escalation should request a panel at least twice the initial actual panel size. The oracle service's supported panel sizes, request schema, and question hashing must be checked when constructing each body. Budget enough response/dispute time; the contracts do not validate JSON or promise delivery. Keep primary requests well before `answerUntil`: primary issuance must precede that cutoff. Paid escalation issuance can extend through its dispute deadline. List answers must fit 16,384 encoded bytes (at most 510 entries). A delivered primary answer that fails panel minima still blocks a retry and may cause timeout refunds with oracle fees spent.
- **Bettors:** approve their bet amount, inspect immutable market terms and full body events, bet before close, then call `claim(id)` once after finalization or voiding. Claims remain available indefinitely. The last winning claim receives division residue.
- **Permissionless callers/keepers:** retrieve the exact published bytes, call `resolve` during its request window, retrieve the complete signed attestation from oracle delivery, call `propose`, optionally escalate, and call `finalize`/`voidMarket` when eligible. A provisional market's dispute deadline takes precedence over the timeout deadline. Each successful resolve (including retry), accepted proposal (including replacement), finalize, and void pays the caller up to that market's settler reward. Escalate is unrewarded. Resolve/propose retain the current price for each unused oracle ask; rewards can be clipped to zero. Terminal rewards have no reserve and are paid before the creator receives the rest of the bounty. Fees and remaining bounty move during settlement; individual claims are separate.

Owner configuration changes can stop new oracle purchases if a new price exceeds old bounties or the new asset differs from Markets' immutable collateral. These changes cannot alter already-stored results or seize bettor funds. No sweep, discretionary refunds, proxy upgrade, or alternate settlement authority exists. The market timeout handles missing primary answers; a missing escalation answer preserves the primary outcome.

The new `createMarket` Params tuple and `getMarket` return tuple change the ABI. The later website job must regenerate its ABI and use the confirmed new deployment addresses. This adaptation leaves `web/` and `dist/` pointing at their existing deployment.
