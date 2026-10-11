// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StdPrecompiles} from "tempo-std/StdPrecompiles.sol";
import {AllowItTempoVault as Vault} from "../src/AllowItTempoVault.sol";
import {AllowItTempoVaultFactory as Factory} from "../src/AllowItTempoVaultFactory.sol";
import {MockTIP20} from "./MockTIP20.sol";

contract AllowItTempoVaultTest is Test {
    uint256 constant AUTHORITY_KEY = 0xA11CE;
    address owner = address(0x1001);
    address executor = address(0x1002);
    address recipient = address(0x1003);
    address attacker = address(0x1004);
    address authority;
    MockTIP20 token;
    Vault vault;
    Factory factory;
    bytes32 policyId = keccak256("policy-1");

    function setUp() public {
        vm.warp(1_900_000_000);
        authority = vm.addr(AUTHORITY_KEY);
        token = new MockTIP20();
        vm.mockCall(
            address(StdPrecompiles.TIP20_FACTORY),
            abi.encodeWithSignature("isTIP20(address)", address(token)),
            abi.encode(true)
        );
        vault = new Vault(owner, address(token), executor, authority, policyId, terms());
        factory = new Factory();
        token.mint(owner, 100_000_000);
        vm.startPrank(owner);
        token.approve(address(vault), type(uint256).max);
        token.approve(address(factory), type(uint256).max);
        vault.fund(10_000_000);
        vm.stopPrank();
    }

    function terms() internal view returns (Vault.Terms memory) {
        return Vault.Terms(
            keccak256("source"),
            keccak256("requirements"),
            10_000_000,
            3_000_000,
            1_000_000,
            uint64(block.timestamp + 30 days),
            address(0),
            true
        );
    }

    function request(uint256 amount) internal view returns (Vault.Execution memory r) {
        (Vault.Terms memory t, uint64 rev, uint64 n,,,,,) = vault.getState();
        r = Vault.Execution(
            block.chainid,
            address(vault),
            address(token),
            policyId,
            t.policyDigest,
            t.requirementsDigest,
            rev,
            n + 1,
            recipient,
            amount,
            uint64(block.timestamp + 180),
            keccak256(abi.encode("request", n + 1)),
            keccak256("Jev assessment approved"),
            bytes32("invoice-1")
        );
    }

    function sign(Vault.Execution memory r) internal view returns (bytes memory) {
        (uint8 v, bytes32 rs, bytes32 s) = vm.sign(AUTHORITY_KEY, vault.executionDigest(r));
        return abi.encodePacked(rs, s, v);
    }

    function execute(uint256 amount) internal {
        Vault.Execution memory r = request(amount);
        bytes memory signature = sign(r);
        vm.prank(executor);
        vault.execute(r, signature);
    }

    function reject(Vault.Execution memory r, bytes4 selector) internal {
        bytes memory signature = sign(r);
        vm.expectRevert(selector);
        vm.prank(executor);
        vault.execute(r, signature);
        assertEq(vault.nonce(), 0);
        assertEq(vault.spent(), 0);
        assertEq(token.balanceOf(address(vault)), 10_000_000);
    }

    function testExecutionTransfersExactUnitsAndMemo() public {
        execute(1_000_000);
        assertEq(token.balanceOf(recipient), 1_000_000);
        assertEq(token.balanceOf(address(vault)), 9_000_000);
        assertEq(vault.spent(), 1_000_000);
        assertEq(vault.spentToday(), 1_000_000);
        assertEq(vault.nonce(), 1);
        assertTrue(vault.consumedRequests(keccak256(abi.encode("request", uint64(1)))));
    }

    function testZeroMemoUsesSafeTransfer() public {
        Vault.Execution memory r = request(1);
        r.memo = 0;
        bytes memory sig = sign(r);
        vm.prank(executor);
        vault.execute(r, sig);
        assertEq(token.balanceOf(recipient), 1);
    }

    function testDigestMatchesIndependentFlattenedEIP712Encoding() public view {
        Vault.Execution memory r = request(123);
        bytes32 structHash = keccak256(
            abi.encode(
                vault.EXECUTION_TYPEHASH(),
                r.chainId,
                r.vault,
                r.token,
                r.policyId,
                r.policyDigest,
                r.requirementsDigest,
                r.revision,
                r.nonce,
                r.recipient,
                r.amount,
                r.expiresAt,
                r.requestHash,
                r.assessmentHash,
                r.memo
            )
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("AllowIt Tempo Vault"),
                keccak256("1"),
                block.chainid,
                address(vault)
            )
        );
        assertEq(vault.executionDigest(r), keccak256(abi.encodePacked(hex"1901", domain, structHash)));
    }

    function testOnlyExecutorMaySpend() public {
        Vault.Execution memory r = request(1);
        bytes memory sig = sign(r);
        vm.expectRevert(Vault.Unauthorized.selector);
        vm.prank(owner);
        vault.execute(r, sig);
    }

    function testWrongSignatureRejected() public {
        Vault.Execution memory r = request(1);
        (uint8 v, bytes32 rs, bytes32 s) = vm.sign(0xBAD, vault.executionDigest(r));
        vm.expectRevert(Vault.InvalidAttestation.selector);
        vm.prank(executor);
        vault.execute(r, abi.encodePacked(rs, s, v));
    }

    function testMalformedSignatureRejected() public {
        Vault.Execution memory r = request(1);
        vm.expectRevert(Vault.InvalidAttestation.selector);
        vm.prank(executor);
        vault.execute(r, hex"deadbeef");
    }

    function testHighSSignatureRejected() public {
        Vault.Execution memory r = request(1);
        (uint8 v, bytes32 rs, bytes32 s) = vm.sign(AUTHORITY_KEY, vault.executionDigest(r));
        uint256 curveOrder = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;
        vm.expectRevert(Vault.InvalidAttestation.selector);
        vm.prank(executor);
        vault.execute(r, abi.encodePacked(rs, bytes32(curveOrder - uint256(s)), v == 27 ? uint8(28) : uint8(27)));
    }

    function testEveryBindingRejectsSubstitution() public {
        for (uint256 i; i < 11; ++i) {
            Vault.Execution memory r = request(1);
            if (i == 0) r.chainId++;
            else if (i == 1) r.vault = attacker;
            else if (i == 2) r.token = attacker;
            else if (i == 3) r.policyId = keccak256("other");
            else if (i == 4) r.policyDigest = keccak256("other");
            else if (i == 5) r.requirementsDigest = keccak256("other");
            else if (i == 6) r.revision++;
            else if (i == 7) r.recipient = address(0);
            else if (i == 8) r.recipient = address(vault);
            else if (i == 9) r.requestHash = 0;
            else r.assessmentHash = 0;
            reject(r, Vault.BindingMismatch.selector);
        }
    }

    function testSignatureProtectsAmountRecipientMemoRequestAndAssessment() public {
        for (uint256 i; i < 5; ++i) {
            Vault.Execution memory r = request(1);
            bytes memory sig = sign(r);
            if (i == 0) r.amount = 2;
            else if (i == 1) r.recipient = attacker;
            else if (i == 2) r.memo = keccak256("changed");
            else if (i == 3) r.requestHash = keccak256("changed");
            else r.assessmentHash = keccak256("changed");
            vm.expectRevert(Vault.InvalidAttestation.selector);
            vm.prank(executor);
            vault.execute(r, sig);
        }
    }

    function testRequestNonceMustIncreaseExactlyOne() public {
        Vault.Execution memory r = request(1);
        r.nonce = 0;
        reject(r, Vault.Replay.selector);
        r.nonce = 2;
        reject(r, Vault.Replay.selector);
    }

    function testExactExecutionCannotReplay() public {
        Vault.Execution memory r = request(1);
        bytes memory sig = sign(r);
        vm.prank(executor);
        vault.execute(r, sig);
        vm.expectRevert(Vault.Replay.selector);
        vm.prank(executor);
        vault.execute(r, sig);
        assertEq(vault.spent(), 1);
    }

    function testRequestHashCannotBeReusedWithNewNonceOrRevision() public {
        Vault.Execution memory r = request(1);
        bytes memory sig = sign(r);
        vm.prank(executor);
        vault.execute(r, sig);
        Vault.Terms memory t = terms();
        vm.prank(owner);
        vault.tune(t);
        r.revision = 2;
        r.nonce = 2;
        sig = sign(r);
        vm.expectRevert(Vault.Replay.selector);
        vm.prank(executor);
        vault.execute(r, sig);
    }

    function testExpiryBoundaryIsExclusive() public {
        Vault.Execution memory r = request(1);
        r.expiresAt = uint64(block.timestamp);
        reject(r, Vault.Expired.selector);
    }

    function testAttestationMaxFiveMinutes() public {
        Vault.Execution memory r = request(1);
        r.expiresAt = uint64(block.timestamp + 301);
        reject(r, Vault.InvalidAttestation.selector);
    }

    function testExpiresWithinMandate() public {
        Vault.Terms memory t = terms();
        t.expiresAt = uint64(block.timestamp + 10);
        vm.prank(owner);
        vault.tune(t);
        Vault.Execution memory r = request(1);
        bytes memory sig = sign(r);
        vm.expectRevert(Vault.InvalidAttestation.selector);
        vm.prank(executor);
        vault.execute(r, sig);
    }

    function testExpiredMandateBlocksExecutionAndFunding() public {
        Vault.Terms memory t = terms();
        vm.warp(t.expiresAt);
        Vault.Execution memory r = request(1);
        bytes memory sig = sign(r);
        vm.expectRevert(Vault.Expired.selector);
        vm.prank(executor);
        vault.execute(r, sig);
        vm.expectRevert(Vault.Expired.selector);
        vm.prank(owner);
        vault.fund(1);
    }

    function testPerActionAndZeroAmountBlocked() public {
        reject(request(0), Vault.LimitExceeded.selector);
        reject(request(1_000_001), Vault.LimitExceeded.selector);
    }

    function testDailyCapAndUtcDayRollover() public {
        execute(1_000_000);
        execute(1_000_000);
        execute(1_000_000);
        Vault.Execution memory r = request(1);
        bytes memory sig = sign(r);
        vm.expectRevert(Vault.LimitExceeded.selector);
        vm.prank(executor);
        vault.execute(r, sig);
        vm.warp((block.timestamp / 1 days + 1) * 1 days);
        execute(1);
        assertEq(vault.spentToday(), 1);
        assertEq(vault.spent(), 3_000_001);
    }

    function testTotalCapSurvivesFundingAndDayRollover() public {
        Vault.Terms memory t = terms();
        t.totalUnits = 1_000_000;
        t.dailyUnits = 1_000_000;
        vm.prank(owner);
        vault.tune(t);
        execute(1_000_000);
        vm.prank(owner);
        vault.fund(1);
        vm.warp(block.timestamp + 1 days);
        Vault.Execution memory r = request(1);
        bytes memory sig = sign(r);
        vm.expectRevert(Vault.LimitExceeded.selector);
        vm.prank(executor);
        vault.execute(r, sig);
    }

    function testFixedRecipientIfConfigured() public {
        Vault.Terms memory t = terms();
        t.recipient = attacker;
        vm.prank(owner);
        vault.tune(t);
        Vault.Execution memory r = request(1);
        bytes memory sig = sign(r);
        vm.expectRevert(Vault.BindingMismatch.selector);
        vm.prank(executor);
        vault.execute(r, sig);
        r.recipient = attacker;
        sig = sign(r);
        vm.prank(executor);
        vault.execute(r, sig);
        assertEq(token.balanceOf(attacker), 1);
    }

    function testOptionalSemanticAssessment() public {
        Vault.Terms memory t = terms();
        t.semanticRequired = false;
        vm.prank(owner);
        vault.tune(t);
        Vault.Execution memory r = request(1);
        r.assessmentHash = 0;
        bytes memory sig = sign(r);
        vm.prank(executor);
        vault.execute(r, sig);
        assertEq(vault.spent(), 1);
    }

    function testTuneInvalidatesOldSignatureAndPreservesUsage() public {
        execute(1);
        Vault.Execution memory old = request(1);
        bytes memory sig = sign(old);
        Vault.Terms memory t = terms();
        t.policyDigest = keccak256("source 2");
        vm.prank(owner);
        vault.tune(t);
        assertEq(vault.nonce(), 1);
        assertEq(vault.spent(), 1);
        assertEq(vault.spentToday(), 1);
        vm.expectRevert(Vault.BindingMismatch.selector);
        vm.prank(executor);
        vault.execute(old, sig);
        execute(1);
    }

    function testTuneCannotResetConsumedTotalOrDaily() public {
        execute(100);
        Vault.Terms memory t = terms();
        t.totalUnits = 99;
        t.dailyUnits = 99;
        t.actionUnits = 99;
        vm.expectRevert(Vault.LimitExceeded.selector);
        vm.prank(owner);
        vault.tune(t);
        t = terms();
        t.dailyUnits = 99;
        t.actionUnits = 99;
        vm.expectRevert(Vault.LimitExceeded.selector);
        vm.prank(owner);
        vault.tune(t);
    }

    function testOnlyOwnerMayTuneRevokeFundOrRecover() public {
        Vault.Terms memory t = terms();
        vm.startPrank(executor);
        vm.expectRevert(Vault.Unauthorized.selector);
        vault.tune(t);
        vm.expectRevert(Vault.Unauthorized.selector);
        vault.revoke();
        vm.expectRevert(Vault.Unauthorized.selector);
        vault.fund(1);
        vm.expectRevert(Vault.Unauthorized.selector);
        vault.withdrawRemaining();
        vm.stopPrank();
    }

    function testRevocationPermanentAndRecoveryWorksAfterExpiry() public {
        execute(100);
        vm.prank(owner);
        vault.revoke();
        vm.prank(owner);
        vault.revoke();
        Vault.Terms memory t = terms();
        vm.expectRevert(Vault.Inactive.selector);
        vm.prank(owner);
        vault.tune(t);
        vm.expectRevert(Vault.Inactive.selector);
        vm.prank(owner);
        vault.fund(1);
        Vault.Execution memory r = request(1);
        bytes memory sig = sign(r);
        vm.expectRevert(Vault.Inactive.selector);
        vm.prank(executor);
        vault.execute(r, sig);
        vm.warp(block.timestamp + 31 days);
        vm.prank(owner);
        vault.withdrawRemaining();
        assertEq(token.balanceOf(address(vault)), 0);
        assertTrue(vault.revoked());
        assertEq(vault.nonce(), 1);
        vm.prank(owner);
        vault.withdrawRemaining();
    }

    function testTokenRevertRollsBackUsageAndReplayMarker() public {
        Vault.Execution memory r = request(1);
        bytes memory sig = sign(r);
        token.setPaused(true);
        vm.expectRevert("token paused");
        vm.prank(executor);
        vault.execute(r, sig);
        assertEq(vault.nonce(), 0);
        assertEq(vault.spent(), 0);
        assertFalse(vault.consumedRequests(r.requestHash));
        token.setPaused(false);
        vm.prank(executor);
        vault.execute(r, sig);
    }

    function testFalseTokenReturnRollsBack() public {
        token.setFailing(true);
        Vault.Execution memory r = request(1);
        r.memo = 0;
        bytes memory sig = sign(r);
        vm.expectRevert();
        vm.prank(executor);
        vault.execute(r, sig);
        assertEq(vault.spent(), 0);
    }

    function testRedirectedTempoReceiptRollsBack() public {
        token.setRedirect(attacker);
        Vault.Execution memory r = request(1);
        bytes memory sig = sign(r);
        vm.expectRevert(Vault.DeliveryMismatch.selector);
        vm.prank(executor);
        vault.execute(r, sig);
        assertEq(token.balanceOf(attacker), 0);
        assertEq(vault.nonce(), 0);
        assertFalse(vault.consumedRequests(r.requestHash));
    }

    function testRedirectedFundingAndRecoveryRollBack() public {
        token.setRedirect(attacker);
        vm.expectRevert(Vault.DeliveryMismatch.selector);
        vm.prank(owner);
        vault.fund(1);
        vm.expectRevert(Vault.DeliveryMismatch.selector);
        vm.prank(owner);
        vault.withdrawRemaining();
        assertFalse(vault.revoked());
        assertEq(token.balanceOf(address(vault)), 10_000_000);
    }

    function testInsufficientVaultBalanceRollsBack() public {
        token.burn(address(vault), 10_000_000);
        Vault.Execution memory r = request(1);
        bytes memory sig = sign(r);
        vm.expectRevert();
        vm.prank(executor);
        vault.execute(r, sig);
        assertEq(vault.spent(), 0);
        assertEq(vault.nonce(), 0);
    }

    function testTokenCallbackCannotReenter() public {
        Vault.Execution memory r = request(1);
        bytes memory sig = sign(r);
        token.setReentry(address(vault), abi.encodeCall(Vault.execute, (r, sig)));
        vm.prank(executor);
        vault.execute(r, sig);
        assertTrue(token.reentryBlocked());
        assertEq(vault.spent(), 1);
    }

    function testFactoryPredictsAndFundsAtomically() public {
        Vault.Terms memory t = terms();
        address predicted = factory.predictVault(owner, policyId, address(token), executor, authority, t);
        vm.prank(owner);
        address created = factory.createVault(policyId, address(token), executor, authority, t, 1_000_000);
        assertEq(created, predicted);
        assertEq(factory.vaultOf(owner, policyId), created);
        assertEq(token.balanceOf(created), 1_000_000);
        assertEq(Vault(created).owner(), owner);
    }

    function testFactoryDuplicateAndOwnerIsolation() public {
        Vault.Terms memory t = terms();
        vm.prank(owner);
        factory.createVault(policyId, address(token), executor, authority, t, 1);
        vm.expectRevert(Factory.AlreadyCreated.selector);
        vm.prank(owner);
        factory.createVault(policyId, address(token), executor, authority, t, 1);
        token.mint(attacker, 1);
        vm.startPrank(attacker);
        token.approve(address(factory), 1);
        address created = factory.createVault(policyId, address(token), executor, authority, t, 1);
        vm.stopPrank();
        assertEq(Vault(created).owner(), attacker);
    }

    function testFactoryTransferFailureUndoesDeployment() public {
        Vault.Terms memory t = terms();
        address predicted = factory.predictVault(owner, policyId, address(token), executor, authority, t);
        token.setFailing(true);
        vm.expectRevert();
        vm.prank(owner);
        factory.createVault(policyId, address(token), executor, authority, t, 1);
        assertEq(factory.vaultOf(owner, policyId), address(0));
        assertEq(predicted.code.length, 0);
        token.setFailing(false);
        vm.prank(owner);
        factory.createVault(policyId, address(token), executor, authority, t, 1);
        assertGt(predicted.code.length, 0);
    }

    function testFactoryRedirectedFundingRollsBack() public {
        Vault.Terms memory t = terms();
        token.setRedirect(attacker);
        vm.expectRevert(Factory.DeliveryMismatch.selector);
        vm.prank(owner);
        factory.createVault(policyId, address(token), executor, authority, t, 1);
        assertEq(factory.vaultOf(owner, policyId), address(0));
        assertEq(token.balanceOf(attacker), 0);
    }

    function testFactoryRejectsZeroAndOverBudgetFunding() public {
        Vault.Terms memory t = terms();
        vm.startPrank(owner);
        vm.expectRevert(Factory.InvalidFunding.selector);
        factory.createVault(policyId, address(token), executor, authority, t, 0);
        vm.expectRevert(Factory.InvalidFunding.selector);
        factory.createVault(policyId, address(token), executor, authority, t, t.totalUnits + 1);
        vm.stopPrank();
    }

    function testUnknownTokenRejectedByCanonicalFactory() public {
        vm.clearMockedCalls();
        vm.expectRevert(Vault.InvalidToken.selector);
        new Vault(owner, address(token), executor, authority, policyId, terms());
    }

    function testInvalidOwnerAndZeroPolicyIdRejected() public {
        Vault.Terms memory t = terms();
        vm.expectRevert(Vault.InvalidConfiguration.selector);
        new Vault(address(0), address(token), executor, authority, policyId, t);
        vm.expectRevert(Vault.InvalidConfiguration.selector);
        new Vault(owner, address(token), executor, authority, 0, t);
    }

    function testInvalidLimitsAndDigestsRejected() public {
        for (uint256 i; i < 7; ++i) {
            Vault.Terms memory t = terms();
            if (i == 0) t.policyDigest = 0;
            else if (i == 1) t.requirementsDigest = 0;
            else if (i == 2) t.totalUnits = 0;
            else if (i == 3) t.dailyUnits = 0;
            else if (i == 4) t.actionUnits = 0;
            else if (i == 5) t.dailyUnits = t.totalUnits + 1;
            else t.actionUnits = t.dailyUnits + 1;
            vm.expectRevert(Vault.InvalidConfiguration.selector);
            new Vault(owner, address(token), executor, authority, policyId, t);
        }
    }

    function testFuzzExactConservation(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000);
        execute(amount);
        assertEq(token.balanceOf(address(vault)) + token.balanceOf(recipient), 10_000_000);
        assertEq(vault.spent(), amount);
    }

    function testFuzzAboveActionLimitAlwaysRejected(uint256 amount) public {
        amount = bound(amount, 1_000_001, type(uint256).max);
        reject(request(amount), Vault.LimitExceeded.selector);
    }

    function testFuzzAnyForeignChainRejected(uint256 chainId) public {
        vm.assume(chainId != block.chainid);
        Vault.Execution memory r = request(1);
        r.chainId = chainId;
        reject(r, Vault.BindingMismatch.selector);
    }
}
