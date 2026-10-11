# Verdict settler rewards and Intake v2 adaptation

This is the contracts-only Sepolia adaptation after launch 1277. It preserves the audited application behavior except for the requested settler rewards and deployment configuration. No token, pool, proxy, initializer, external library, or new authority is introduced. Solidity 0.8.26, the existing Foundry configuration, and vendored OpenZeppelin v5 dependencies are unchanged. `web/` and `dist/` are untouched.

## Changes and reasons

| File | Change | Required by |
| --- | --- | --- |
| `src/VerdictMarkets.sol` | Append immutable constructor argument `maxSettlerReward`; append `settlerReward` to `Params`; expose `Market.settlerReward` and `Market.rewardsPaid` through `getMarket`. | Requested reward configuration and accounting ABI. |
| `src/VerdictMarkets.sol` | Reject a reward above the immutable cap with `InvalidParams`. Check both requested and received bounty against two oracle prices plus five rewards, reverting `InsufficientBounty`. | Reward cap and minimum funding rules, including transfer-fee receipts. |
| `src/VerdictMarkets.sol` | Reward every successful resolve (including retry), first proposal, escalation replacement, finalize, and void. Escalate remains unrewarded. | Permissionless settler incentives. |
| `src/VerdictMarkets.sol` | Deduct rewards solely from that market's bounty and increment `rewardsPaid`. Resolve/propose reserve current oracle funding; terminal calls deduct rewards before releasing the remainder and pay the settler before the creator. | Reserve, terminal payment order, and conservation requirements. |
| `script/SepoliaParameters.sol` | Use Sepolia Intake v2 `0xa43e6f75ee006411f79ac1c84120606c2330de82`; append maximum reward `250000000000000000` to encoded Markets arguments. | Exact requested deployment arguments and reproduced stale-artifact finding. |
| `launch.json` | Remove the old v1/nine-argument manifest. | The supplied launch process assigns manifest generation to the following stage; leaving the old file would deploy the wrong configuration or fail constructor validation. No replacement manifest is written here. |
| `test/TestBase.sol`, `test/VerdictMarketsValidation.t.sol`, `test/VerdictSettlementProperties.t.sol` | Update existing constructor calls; explicitly keep existing market rewards zero. Existing test assertions and scenarios are unchanged. | ABI additions while retaining every prior regression. |
| `test/VerdictSettlerRewards.t.sol` | Add action/event, retry, proposal replacement, price-reserve, bounty minimum, cap, zero-reward, overflow, fee, and isolation tests. | New behavior acceptance criteria. |
| `test/SettlerLifecycleProperties.t.sol`, `test/SettlerRewardInvariant.t.sol` | Add lifecycle fuzzing and a three-market stateful reward campaign with price changes, actual token outflows, paused entry, and complete final draining. | Per-market conservation and no-dust requirement. Original zero-reward invariants remain unchanged. |
| `test/SettlerDeployment.t.sol` | Assert the exact supplied constructor bytes, Intake v2, reward maximum, dependency order, and ownership through a factory with no external dependency code. | Launch compatibility and stale deployment regression. The existing opcode/runtime/constructor rehearsal still runs. |
| `test/VerdictImportedAudit.t.sol` | Preserve executable reproductions of free escalation, unbounded lifetime, and entry-only pause behavior. | Reproduce imported observations and prevent unrelated behavioral changes. |
| `test/SettlerIndependentReview.t.sol`, `docs/SETTLER_INDEPENDENT_REVIEW.md` | Separate automated reviewer-authored adversarial tests and findings. | Requested independent review. |
| `README.md`, `docs/DEPLOYMENT.md`, this file | Document rewards, revised accounting, exact arguments, audit dispositions, and the deployment handoff. | Launch documentation and adaptation acceptance criteria. |

`src/VerdictOracle.sol`, `src/VerdictBurnVault.sol`, both interfaces, and the canonical attestation code are unchanged. VerdictOracle still calls `request`, never `requestWithFailure`, and authenticates callbacks from the Intake pinned when each request was purchased. The existing protocol conformance vector and adversarial oracle tests remain applicable to Intake v2's unchanged request/callback ABI.

## Reward semantics and arithmetic

Each successful eligible action computes its reward after the action's state transition. For resolve/propose, the market has necessarily used at least one ask. If one remains, its reserve is the current `oracle.price()`; after two asks, it is zero. The price is reread after `oracle.request` returns, so a change during the purchase is reflected too. The paid amount is the lesser of the configured reward and the bounty exceeding the reserve. If the bounty is already below the reserve, nothing is deducted and the action can still succeed. Finalize/void use zero reserve, including void with no asks.

All reward accounting and terminal bounty-release accounting finish before a reward transfer. The existing reentrancy guard protects every rewarded entry point. A failed token transfer reverts the entire operation, including preceding oracle requests or payments. Payout and fee calculations continue to use only bettor deposits.

`SettlerRewarded(uint256 indexed id, address indexed settler, uint8 action, uint256 amount)` uses action codes 0 resolve, 1 propose, 2 finalize, and 3 void. A positive configured reward emits once even when reserve clipping reduces the payment to zero. A configured reward of zero skips reward accounting, additional oracle reads, transfers, and reward events, retaining the old behavior.

The minimum check first establishes `bounty / 2 >= price`, then checks `(bounty - 2 * price) / 5 >= reward`. This is equivalent to `bounty >= 2 * price + 5 * reward` without overflowing either product or the sum, including impossible uint256-sized settings. It runs before and after the bounty pull.

After all entitled claims, each market satisfies:

```text
payouts + refunds + fees + oracle spend + rewardsPaid + returnedBounty
    == credited bettor deposits + credited creator bounty
```

The separate randomized campaign also checks intermediate liabilities against actual contract balances and records measured reward transfers independently of `rewardsPaid`. Direct token donations and unclaimed entitlements retain their documented treatment; no-dust means all entitled claims have completed.

## Imported audit dispositions

Four probes ran against the unchanged source before implementation and all passed. They reproduced the deployment mismatch, free escalation, remote refund deadline, and paused settlement/full bounty release. The behavior probes are delivered in `test/VerdictImportedAudit.t.sol`; the obsolete launch configuration assertion is replaced by the exact new deployment regression.

1. **3411c5325568508ca05754d997ee48552a25ef6ed957ac53611f157b780bff71 — stale launch artifacts: reproduced and fixed.** The old manifest and parameter library named v1 and encoded nine Markets arguments. The old documentation deliberately described v1. The stale manifest is removed, the library and documentation now specify v2 and ten arguments, and `test_launchHandoffPinsV2AndTenConstructorArguments` asserts literal values independently of the parameter constants. The existing deployment test follows the updated parameter library without weakening its assertions.
2. **95f319edf7bfa27ec2c58910c44a552c35a3b83c17f7415027ea81ce9c9217cd — free escalation: reproduced, intentional behavior retained.** A non-bettor can spend one remaining bounty-funded ask and extend the deadline to at least 24 hours from escalation. The audit explicitly identifies the design as intentional; adding stake gating or charging the caller would conflict with the brief's unchanged-behavior requirement. The new escalation test proves it earns no settler reward. This remains a bounded griefing/trust assumption.
3. **c81881396a0ac369e5718fc22f39dd8f73aaca327c6a8307570975dc8c519ca6 — no maximum lifetime: reproduced, documented creator risk retained.** A market with `voidAfter = type(uint64).max` cannot refund one year after its answer window. This is visible immutable market metadata, and the audit describes it as a trust assumption rather than a defect. No new deadline cap or emergency withdrawal is added.
4. **7a02fd7bd83b63049e4fa11176050a3f67bec9e4de14c299c8f25c55b7a37f67 — guardian/configuration powers: reproduced, unchanged.** Pause and creator admission gate entry only. Existing and new tests demonstrate settlement, rewards, and claims while entry is paused. The guardian cannot freeze or seize held funds. The requested zero-delay oracle owner can change configuration for future asks; paid requests retain their pinned Intake/signer. These are the agreed launch-1277 authorities, not permission bypasses.
5. **3188a7204f0a886f2231f6a2cefff353c71223828b911a3143ed62ed0010ea28 — terminal reward ordering: implementation guidance applied.** The old `_releaseBounty` returned all remaining bounty, as reproduced before editing. The adapted calls deduct/account for the reward before invoking it, then pay the caller first after all state changes. Actual transfers, `returnedBounty`, `rewardsPaid`, fees, and final claims are checked together. The suggested faulty ordering was not a defect in the original zero-reward code.

All supplied behavioral observations reproduced. None established an additional unintended runtime defect requiring a scope change; no claim is made that the documented operational risks were removed.

## Validation and independent review

- Before adaptation: `forge test` passed all **121 existing tests**, including both original stateful invariant suites. The separate pre-change imported-audit probe passed **4/4**.
- Focused reward and constructor checks passed **11/11**.
- New lifecycle property passed **512 fuzz cases**, varying rewards, prices, stakes, settlement paths, and claim order.
- New stateful reward invariant passed **128 runs × 64 calls**, with **zero unexpected reverts**, followed by complete draining for every sequence.
- Independent review passed **33/33** selected tests, including **10** reviewer-authored adversarial tests and two **512-run** fuzz tests. It found no concrete adaptation defect. Commands, scope, limitations, and reviewed source hashes are in `docs/SETTLER_INDEPENDENT_REVIEW.md`. This is an automated review by a separate agent, not a human audit or guarantee.
- Final **`forge build` passed** and **`forge test` passed all 147 tests across 20 suites**, with zero failures or skips, using the unchanged project configuration. This includes all 121 original tests. The three stateful campaigns executed **32,768 calls** in total with zero unexpected reverts and drained all entitled claims after every run. The full test command completed in 87.45 seconds.
- The final scope check confirmed all protected build/dependency files, `web/`, and `dist/` are unchanged. Oracle, BurnVault, canonical attestation code, and both interfaces match the original source byte for byte. `git diff --check` passed. No dependency installation was needed. Build output contains advisory lint warnings documented in the independent review; no compilation error or test failure remains.

## Deployment handoff and limits

The launch remains **Sepolia only (11155111)**, in the order **VerdictBurnVault → VerdictOracle → VerdictMarkets**. The owner, treasury, and guardian remain `0x397dacb1ee8e9a8ce5196988958f56bde0a0a312`. `docs/DEPLOYMENT.md` and the tested `SepoliaParameters` library provide every constructor argument. All three contracts are fully configured by nonpayable constructors, call no dependency during construction, and fit the supported static argument types and 16-argument limit.

Built runtime/initcode sizes are 16/40 bytes for VerdictBurnVault, 7,720/9,472 for VerdictOracle, and 16,825/17,697 for VerdictMarkets. The original deployment test and an independent artifact walk confirm the runtime bound, no forbidden escape opcodes, and no external library links. Initcode figures exclude static constructor arguments; adding them remains below the limit.

The bounded worker deliverable is source, tests, review, and this exact deployment handoff. The network's subsequent manifest, final review, publication, and deployment stages provide signed deployment transactions and confirmed addresses. No wallet keys were accessed, no live transactions were broadcast, and no GitHub publication was performed here. No new deployment addresses or receipts are invented. A read-only public Sepolia RPC batch query for chain ID and code at the specified v2 Intake/TestIMD addresses returned HTTP 403 on 2026-10-11; live dependency checks, simulation, receipt confirmation, and explorer verification remain with the deployment stage.

The later site job must use the new confirmed contract set and regenerate the changed Markets ABI (`Params` and `Market` both grew). Its current launch-1277 assets are preserved.
