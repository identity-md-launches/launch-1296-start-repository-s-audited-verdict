# Independent review of the settler reward adaptation

Date: 2026-10-11. A separate automated reviewer inspected the implementation and independently authored `test/SettlerIndependentReview.t.sol`. The reviewer did not modify application sources, deployment parameters, the existing tests, build configuration, dependencies, or the website. This is a local independent code review and adversarial test exercise, not a human audit or a guarantee of safety.

## Result and scope

No concrete security defect or launch incompatibility was reproduced in the reward adaptation. The production diff is limited to reward configuration, creation checks, reward accounting/payment, and the new event in `VerdictMarkets`. `VerdictOracle`, `VerdictBurnVault`, the attestation implementation, and the interfaces are unchanged. The launch handoff selects the supplied Intake v2 address without introducing `requestWithFailure`.

The review covered the changed source and full surrounding settlement logic, unchanged oracle and burn vault, the Sepolia constructor handoff, the supplied protected factory test, both pinned security/oracle references, imported audit findings, and the existing/new tests. Repository documentation was treated as evidence of the agreed behavior, not authority to change scope.

## Reward and accounting analysis

- The new immutable maximum is the final, tenth constructor argument. The requested reward follows `bounty` in `Params` and appears in both the returned parameters and market state. The inclusive cap is enforced before funds are pulled.
- Requested and actually received bounty each satisfy `2 * price + 5 * reward`. The division-based comparison avoids overflow: its first condition establishes that `2 * price` is safe and no greater than the bounty before evaluating the subtraction. The second condition rejects an unrepresentable reward budget without multiplying it.
- A successful `resolve` has increased `asks` before reward calculation. An accepted first proposal must already belong to one of the market's paid asks; an accepted replacement must belong to its paid escalation. Thus every nonterminal reward occurs after at least one ask. When fewer than two asks have been used, exactly one price must be reserved. The implementation reads the current price and clips the reward to the available surplus; even `uint256.max` produces a zero reward without overflow. With two asks used, no reserve or price call remains.
- `escalate` has no reward path. Existing request identity checks and state transitions prevent duplicate proposal rewards, repeated terminal rewards, or rewards on reverted actions. A nonzero configured reward emits one `SettlerRewarded` event for each accepted rewarded action, including when clipping reduces the amount to zero. A zero configured reward bypasses the new event, payment, and price lookup, preserving the previous behavior.
- Terminal calls establish the final status, fee/payout liabilities, reward deduction, and returned-bounty accounting before transferring tokens. The settler transfer occurs before the creator's bounty return. Positive terminal rewards work even when `oracle.price()` reverts, confirming zero terminal reserve and no dependency on a functioning oracle.
- Only `bountyRemaining` decreases for rewards; pool, fee and winning-stake calculations are untouched. The independent balance ledger exercises callers who are also the creator, winner, or treasury. Those overlapping roles receive the correct sum of independent entitlements, and the completed market and oracle retain no dust.
- SafeERC20 failure reverts the entire transaction. A failed resolve reward restores the paid ask, Intake nonce/callback/payment, oracle pending/requested records, market timestamps/accounting, balances, and cleared approvals. A failed proposal payment leaves its previously delivered answer usable. A creator-return failure rolls back the earlier attempted terminal reward and permits a later successful settlement.
- Token hooks during terminal reward transfers observe the complete final market accounting and the settler paid before the creator. Reentry is rejected by the existing guard before an action can repeat.

The independent changing-price oracle is deliberately more adversarial than the deployed `VerdictOracle`: it changes `price` inside `request`. The deployed oracle's guard prevents config rotation during a request. This mock specifically verifies that Markets does not reuse the earlier creation or pre-request price when calculating the reserve.

## Imported findings and preserved boundaries

| Imported finding | Independent disposition |
| --- | --- |
| Stale v1 / nine-argument launch artifacts (`3411c532…`) | Reproduced by the baseline diff. The stale `launch.json` is removed for the later manifest step. `SepoliaParameters` selects v2 and ten market arguments; the exact-argument rehearsal covers the supplied values and dependency order. Documentation is updated by the implementation author. |
| A stranger can escalate without stake or token payment (`95f319ed…`) | The imported regression reproduces the behavior. It is the explicitly preserved permissionless design, bounded to one escalation and a second bounty-funded ask, not an authority bypass. Escalation remains unrewarded. A stake restriction or charging the escalator would change the requested behavior. |
| No maximum `voidAfter` (`c8188139…`) | The imported regression reproduces the creator-selected distant refund date. Lifetime remains a documented creator/bettor trust assumption; imposing a new cap is outside this reward adaptation. |
| Guardian entry controls / zero-delay oracle config (`7a02fd7b…`) | Source tracing and the imported paused-settlement regression confirm that the guardian cannot pause settlement or claims. Existing explicit owner and guardian powers are preserved. The supplied zero oracle config delay continues to permit immediate changes for future asks; paid requests retain their captured intake and signer. |
| Deduct reward before releasing bounty (`3188a720…`) | This was adaptation guidance, not an original defect. Terminal callback observations, actual recipient balances, rollback tests, and the full accounting equality confirm the required order in the adapted implementation. |

Request linkage, signature domain, callback authorization, consumed-request handling, panel checks, time windows, retry limits, payout rounding, and final-winner remainder handling remain unchanged. The real Intake still calls `onOracleResult`; the existing canonical digest/signature and callback-selector tests apply to v2's unchanged `request` interface.

## Factory compatibility

The deployment handoff orders `VerdictBurnVault`, `VerdictOracle`, then `VerdictMarkets`; the latter receives the already deployed oracle and burn-vault addresses. All constructor arguments are supported static types, there are at most ten per application, constructors are nonpayable, and none call a dependency or require dependency code. The owner/guardian/treasury argument is the supplied requester address, never the factory or transaction origin.

An independent artifact walk skipped PUSH immediate bytes and found no CALLCODE, DELEGATECALL, or SELFDESTRUCT in any of the three runtimes. There are no external library link references.

| Application | Runtime bytes | Initcode bytes |
| --- | ---: | ---: |
| VerdictBurnVault | 16 | 40 |
| VerdictOracle | 7,720 | 9,472 |
| VerdictMarkets | 16,825 | 17,697 |

## Independent execution evidence

The reviewer ran these commands with the repository's own configuration and Solidity 0.8.26:

```sh
forge build --sizes
forge test --match-contract '(SettlerIndependentReviewTest|VerdictSettlerRewardsTest|VerdictImportedAuditTest|SettlerDeploymentTest|DeploymentTest|OracleConsumerConformanceTest)' -vv
```

The build succeeded. The test command passed **33 tests across six suites, zero failures and zero skips**: ten independent reward tests, ten implementation reward tests, three imported-audit reproductions, four deployment tests, and six canonical oracle conformance tests. Each of the two independent fuzz tests completed **512 runs**. These are the reviewer's own executions; the implementation author's final full-project run is recorded separately.

The build emitted advisory lint warnings. The reward-specific `uninitialized-local` warning refers to `reserve`, whose Solidity default is deliberately zero for terminal and fully asked markets. The reward event follows the oracle's view price call while the market's reentrancy guard is held. Neither warning reproduced a defect. Existing timestamp, exact-payment comparison, bounded-cast, and guarded-external-call patterns remain unchanged.

## Limits

The reviewer used local mocks and the configured Foundry compiler and fuzzing tools. No wallet credentials, real transaction broadcast, live oracle purchase, fork simulation, explorer verification, Slither, or Mythril were used. Deployment and the final manifest remain the launch service's work; this report is not evidence of a Sepolia deployment.

Rewards are incentives rather than a liveness guarantee: oracle price changes can reduce them to zero, and no independent actor is obliged to pay gas. The configured ERC20 must remain transferable and conventional for outgoing payments; token-level failures can revert calls. The oracle signer and Intake pairing remain trusted. Invalid or unanswered bodies spend their oracle fees, and existing deadline/retry restrictions remain in force. Unclaimed payouts remain held for their claimants; the no-dust equality applies after all entitled claims. Direct token donations are not market deposits.

## Reviewed source snapshot

SHA-256 hashes identify the reviewed source; substantive later changes need review again.

```text
81e4eb27422d1060beaf18d7efa600a97e240c83d05365a5f5d948a83026b7db  src/VerdictMarkets.sol
ef26800f8d6a096a87796dbe2e2745d27523ed1e0ce131f98c4513738f06a792  src/VerdictOracle.sol
2be013954de7710b2f0a3aa53f3d0025cfb32c02da567af84dcc55c5b36674d3  src/VerdictBurnVault.sol
4180b7451636a0092943616ea418b085bc8b5b0470e31a65f7e00ab0fc3456be  src/OracleAttestation.sol
f55b1bab45fe283f586f4c981ef9e383ff0aaf5ddae681b3f0e0f958fb5b0d1d  src/interfaces/IIntake.sol
462091dd90fdd771d2c43464867c307175c5f1fc7e94edc835db4302beba5265  src/interfaces/IVerdictOracle.sol
be9e57963068be9ba5f8008736bdfcbf84da480f63c9f507fd57af2b60d71ab6  script/SepoliaParameters.sol
```
