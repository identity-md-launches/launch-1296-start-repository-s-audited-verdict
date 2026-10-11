// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SettlerRewardsBase} from "./VerdictSettlerRewards.t.sol";
import {VerdictMarkets} from "../src/VerdictMarkets.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";

contract SettlerLifecyclePropertiesTest is SettlerRewardsBase {
    function checkHeld(uint256 id) internal view {
        VerdictMarkets.Market memory m = markets.getMarket(id);
        assertEq(m.params.bounty, m.bountyRemaining + m.oracleSpend + m.rewardsPaid + m.returnedBounty);
        uint256 exits = m.paidOut + m.refunded + m.fees + m.oracleSpend + m.rewardsPaid + m.returnedBounty;
        assertEq(token.balanceOf(address(markets)), m.pool + m.params.bounty - exits);
    }

    function testFuzz_allLifecyclePathsConserveActualTransfers(
        uint96 rewardSeed,
        uint96 a,
        uint96 b,
        uint96 c,
        uint8 pathSeed,
        uint64 priceSeed,
        bool reverse
    ) public {
        uint256 reward = bound(rewardSeed, 0, 0.25 ether);
        VerdictMarkets.Params memory p = rewardedParams(reward);
        uint256 id = createWith(p);
        uint8 path = pathSeed % 8;
        uint256 x = bound(a, 1, 100 ether);
        uint256 y = bound(b, 1, 100 ether);
        uint256 z = bound(c, 1, 100 ether);
        betAs(id, alice, path == 7 ? 0 : 1, x);
        betAs(id, bob, path == 7 ? 0 : 1, y);
        betAs(id, carol, 0, z);
        uint256 bettorBefore = token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(carol);
        uint256 creatorBefore = token.balanceOf(creator);
        uint256 keeperBefore = token.balanceOf(address(this));
        setPrice(bound(priceSeed, 1, p.bounty));
        checkHeld(id);

        if (path != 0) {
            vm.warp(p.answerFrom);
            bytes32 rid = markets.resolve(id, body);
            checkHeld(id);
            if (path == 2 || path == 6) {
                vm.warp(block.timestamp + 24 hours);
                if (markets.getMarket(id).bountyRemaining >= oracle.price()) {
                    rid = markets.resolve(id, body);
                } else {
                    vm.expectRevert(VerdictMarkets.InsufficientBounty.selector);
                    markets.resolve(id, body);
                }
                checkHeld(id);
            }
            if (path >= 3) {
                OracleAttestation.Attestation memory answer = attestation(id, abi.encode(true), 5);
                deliver(rid, answer);
                setPrice(oracle.price() + reward); // A different reserve at proposal time.
                markets.propose(id, answer);
                checkHeld(id);
                if (path == 4 || path == 5) {
                    if (markets.getMarket(id).bountyRemaining >= oracle.price()) {
                        rid = markets.escalate(id, escalationBody);
                        checkHeld(id);
                        if (path == 5) {
                            answer = attestation(id, abi.encode(false), 10);
                            deliver(rid, answer);
                            markets.propose(id, answer);
                            checkHeld(id);
                        }
                    } else {
                        vm.expectRevert(VerdictMarkets.InsufficientBounty.selector);
                        markets.escalate(id, escalationBody);
                    }
                }
            }
        }

        VerdictMarkets.Market memory m = markets.getMarket(id);
        markets.pause(); // Entry controls must not stop rewards, settlement, or claims.
        if (m.status == VerdictMarkets.Status.Open) {
            vm.warp(p.voidAfter);
            markets.voidMarket(id);
        } else {
            vm.warp(m.disputeEnds);
            if (markets.outcomePool(id, m.outcome) == 0) markets.voidMarket(id);
            else markets.finalize(id);
        }
        checkHeld(id);
        address[3] memory users = reverse ? [carol, bob, alice] : [alice, bob, carol];
        m = markets.getMarket(id);
        for (uint256 i; i < users.length; ++i) {
            if (m.status == VerdictMarkets.Status.Finalized && markets.stakes(id, users[i], m.outcome) == 0) continue;
            vm.prank(users[i]);
            markets.claim(id);
            checkHeld(id);
        }

        m = markets.getMarket(id);
        uint256 creatorReceived = token.balanceOf(creator) - creatorBefore;
        uint256 keeperReceived = token.balanceOf(address(this)) - keeperBefore;
        uint256 bettorsReceived = token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(carol) - bettorBefore;
        uint256 creatorFee = m.status == VerdictMarkets.Status.Finalized ? (x + y + z) / 100 : 0;
        assertEq(m.rewardsPaid, keeperReceived);
        assertEq(m.returnedBounty, creatorReceived - creatorFee);
        assertEq(m.paidOut + m.refunded, bettorsReceived);
        assertEq(m.fees, creatorFee + token.balanceOf(treasury) + token.balanceOf(address(burn)));
        assertEq(m.oracleSpend, token.balanceOf(address(intake)));
        assertEq(
            x + y + z + p.bounty,
            bettorsReceived + creatorReceived + keeperReceived + token.balanceOf(treasury)
                + token.balanceOf(address(burn)) + token.balanceOf(address(intake))
        );
        assertRewardConserved(id);
        assertEq(token.balanceOf(address(markets)), 0);
        assertEq(token.balanceOf(address(oracle)), 0);
    }
}
