// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {Test} from "forge-std/Test.sol";
import {ITIP20, ITIP20Token} from "tempo-std/interfaces/ITIP20.sol";
import {ITIP403Registry} from "tempo-std/interfaces/ITIP403Registry.sol";
import {StdPrecompiles} from "tempo-std/StdPrecompiles.sol";
import {StdTokens} from "tempo-std/StdTokens.sol";
import {AllowItTempoVault as Vault} from "../src/AllowItTempoVault.sol";
import {AllowItTempoVaultFactory as Factory} from "../src/AllowItTempoVaultFactory.sol";

/// @notice Runs the real Tempo TIP-20/TIP-403 stateful precompiles, without RPC or mock tokens.
contract TempoNativeTest is Test {
    uint256 constant AUTHORITY_KEY = 0xA11CE;
    address owner = address(0x1001);
    address executor = address(0x1002);
    address recipient = address(0x1003);
    ITIP20Token token;
    Vault vault;
    Factory factory;

    function setUp() public {
        vm.warp(1_900_000_000);
        address created = StdPrecompiles.TIP20_FACTORY
            .createToken(
                "Allowit test USD", "AIT", "USD", StdTokens.PATH_USD, address(this), keccak256("allowit-native")
            );
        token = ITIP20Token(created);
        token.grantRole(token.ISSUER_ROLE(), address(this));
        token.grantRole(token.PAUSE_ROLE(), address(this));
        token.grantRole(token.UNPAUSE_ROLE(), address(this));
        token.mint(owner, 10_000_000);
        factory = new Factory();
        vm.startPrank(owner);
        token.approve(address(factory), 10_000_000);
        address createdVault = factory.createVault(
            keccak256("native-policy"), address(token), executor, vm.addr(AUTHORITY_KEY), terms(), 10_000_000
        );
        vm.stopPrank();
        vault = Vault(createdVault);
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

    function request() internal view returns (Vault.Execution memory) {
        return Vault.Execution(
            block.chainid,
            address(vault),
            address(token),
            keccak256("native-policy"),
            keccak256("source"),
            keccak256("requirements"),
            1,
            1,
            recipient,
            1_000_000,
            uint64(block.timestamp + 180),
            keccak256("request"),
            keccak256("assessment"),
            bytes32("invoice-native")
        );
    }

    function sign(Vault.Execution memory r) internal view returns (bytes memory) {
        (uint8 v, bytes32 rs, bytes32 s) = vm.sign(AUTHORITY_KEY, vault.executionDigest(r));
        return abi.encodePacked(rs, s, v);
    }

    function testRealTIP20FactoryFundExecuteMemoAndOwnerRecovery() public {
        assertTrue(StdPrecompiles.TIP20_FACTORY.isTIP20(address(token)));
        assertEq(token.decimals(), 6);
        Vault.Execution memory r = request();
        bytes memory sig = sign(r);
        vm.prank(executor);
        vault.execute(r, sig);
        assertEq(token.balanceOf(recipient), 1_000_000);
        assertEq(token.balanceOf(address(vault)), 9_000_000);
        assertEq(vault.spent(), 1_000_000);
        vm.prank(owner);
        vault.withdrawRemaining();
        assertEq(token.balanceOf(owner), 9_000_000);
        assertTrue(vault.revoked());
    }

    function testRealTIP20PauseRollsBackAccounting() public {
        token.pause();
        Vault.Execution memory r = request();
        bytes memory sig = sign(r);
        vm.expectRevert(ITIP20.ContractPaused.selector);
        vm.prank(executor);
        vault.execute(r, sig);
        assertEq(vault.spent(), 0);
        assertEq(vault.nonce(), 0);
        assertFalse(vault.consumedRequests(r.requestHash));
        token.unpause();
        vm.prank(executor);
        vault.execute(r, sig);
        assertEq(token.balanceOf(recipient), 1_000_000);
    }

    function testRealTIP403BlacklistedRecipientCannotSpend() public {
        ITIP403Registry registry = StdPrecompiles.TIP403_REGISTRY;
        uint64 policy = registry.createPolicy(address(this), ITIP403Registry.PolicyType.BLACKLIST);
        registry.modifyPolicyBlacklist(policy, recipient, true);
        token.changeTransferPolicyId(policy);
        Vault.Execution memory r = request();
        bytes memory sig = sign(r);
        vm.expectRevert(ITIP20.PolicyForbids.selector);
        vm.prank(executor);
        vault.execute(r, sig);
        assertEq(vault.spent(), 0);
        assertEq(token.balanceOf(address(vault)), 10_000_000);
    }

    function testRealReceivePolicyRedirectCannotLookLikeSuccessfulPayment() public {
        ITIP403Registry registry = StdPrecompiles.TIP403_REGISTRY;
        uint64 blockedSenderPolicy = registry.createPolicy(address(this), ITIP403Registry.PolicyType.WHITELIST);
        // Policy 1 is the protocol always-allow policy; the empty whitelist blocks this vault.
        vm.prank(recipient);
        registry.setReceivePolicy(blockedSenderPolicy, 1, recipient);
        Vault.Execution memory r = request();
        bytes memory sig = sign(r);
        vm.expectRevert(Vault.DeliveryMismatch.selector);
        vm.prank(executor);
        vault.execute(r, sig);
        assertEq(vault.spent(), 0);
        assertEq(vault.nonce(), 0);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.balanceOf(address(vault)), 10_000_000);
    }
}
