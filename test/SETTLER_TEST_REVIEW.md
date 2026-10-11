# Settler reward test contribution

This contribution independently tests the accepted implementation without changing
application sources, deployment parameters, existing tests, dependencies, or build
configuration. The supplied property-testing guides informed the choice of
conservation, transition, boundary, and non-vacuity checks. No new contract defect
was reproduced.

The original 147 tests passed before these additions. They already exercise each
rewarded action, duplicate calls, reward limits, zero-reward compatibility, payment
rollback, callback authentication, canonical protocol signatures, and the exact
Sepolia Intake v2 constructor handoff. The following additions address gaps without
replacing that coverage.

| File | Additional coverage |
| --- | --- |
| `SettlerRewardSequence.t.sol` | 256 sequences of 80 randomized calls. Rewards must be maximal under the reserve rule, paid to the actual caller, and emitted exactly once. Includes zero, one-wei and maximum launch rewards, price increases and decreases, retry, first and replacement proposals, escalation, finalization, both void paths, claims, pause, donations and invalid calls. |
| `SettlerBountyBoundaries.t.sol` | Three properties with 1,000 fuzz runs each: exact minimum versus one wei short throughout the representable `uint256` range; the exact received minimum after incoming transfer tax; and impossible minimums rejected before any token transfer. Four fixed cases cover one wei, the largest valid price, the largest valid reward budget, and the entire `uint256` token supply. |

## Reward and accounting model

The existing reward invariant bounds payments above but would also permit a
smaller-than-required payment. The new campaign checks maximality without copying
the contract's `Math.min` expression: a nonterminal reward must either reach the
agreed amount or leave exactly the required reserve. If the available bounty is
already at or below the reserve, the payment must be zero. A terminal reward must
reach either the agreed amount or the entire remaining bounty.

Up to eight markets are created during each sequence. Four funded actors can be
creators, bettors and settlers; the treasury can also settle. Each action's actual
wallet deltas distinguish rewards from creator fees, bounty returns and treasury
fees even when one address has multiple roles. For terminal actions, the first
outgoing token transfer must match the reward event. Other markets' complete
state snapshots must remain unchanged.

Independent ledgers record incoming deposits and outgoing token balance changes.
After each randomized call, those ledgers are compared with each market's
accounting, aggregate custody, oracle receipts and zero residual allowances.
Settler rewards can consume only bounty; pool principal and fee liabilities are
checked separately. Direct donations have a separate ledger and cannot mask dust.

Every sequence ends by advancing beyond deadlines, settling every market and
claiming for every eligible actor. Each market must satisfy exactly:

`payouts + refunds + fees + oracle spend + rewards + returned bounty == deposits`

The only permitted residual balance is measured direct donations. The handler
also submits invalid committed bodies, unauthenticated proposals, invalid outcome
bets and premature or repeated terminal calls. Rejections must preserve balances,
market state and the Intake request nonce. Unexpected reverts from valid actions
fail the campaign.

A deterministic handler test checks counters for a paid retry, a replacement,
partial and zero rewards, every reward action, an unrewarded escalation and six
rejected calls. It also exercises settlement and claims while entry is paused.
This ensures important branches do not pass merely because random inputs never
reach them.

## Test sensitivity check

A temporary copy of `VerdictMarkets` under `test/scratch/` divided every computed
reward by two. Its runtime was substituted only in a scratch copy of the new
handler, preserving the same ABI and storage layout. Running the deterministic
handler test against it failed with `reward underpaid`: the one-wei reward was
rounded to zero while surplus bounty was still available. The unchanged production
contract passes the same sequence. Both temporary Solidity files were removed
before final verification. This intentionally defective test copy is not a finding
against the submitted contracts.

## Final local verification

- `forge build`: passed with the existing compiler configuration; advisory lint
  warnings remain.
- `forge test`: **156 passed, 0 failed, 0 skipped**, across 22 suites.
- The new invariant completed **256 runs / 20,480 calls / 0 unexpected reverts**.
- Each new arithmetic property completed **1,000 fuzz runs**.
- Scope verification found only these three new files under `test/`; all existing
  tracked files remained unchanged.

## Review boundaries

The source review traced bounty validation through state updates and transfers.
Nonterminal reward paths have used at least one ask; the sole remaining ask is
reserved at the current price. Terminal paths deduct the reward before releasing
the bounty. The reward addition leaves fee and payout arithmetic separate from
bounty accounting. The existing request identity, signature, retry and dispute
checks prevent using unrelated answers to earn a proposal reward.

This is an offline test contribution, not evidence of a live deployment or live
oracle availability. Tests use the vendored dependencies and local token/Intake
mocks, with no fork, FFI, network, environment mutation or wallet access. The
transfer-tax test disables tax before outgoing transfers; it does not promise
exact recipient receipts for arbitrary taxed or rebasing assets. Existing oracle
trust, creator-selected deadlines and unanswered-request limitations remain part
of the accepted design.
