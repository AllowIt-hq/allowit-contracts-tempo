// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {StdPrecompiles} from "tempo-std/StdPrecompiles.sol";
import {AllowItTempoVault as Vault} from "../src/AllowItTempoVault.sol";
import {MockTIP20} from "./MockTIP20.sol";

contract VaultHandler is Test {
    uint256 constant KEY = 0xA11CE;
    Vault public vault;
    MockTIP20 public token;
    address public owner;
    address public executor;
    address public recipient;
    uint256 public executions;
    uint256 public totalPaid;
    uint256 public totalMinted = 100_000_000;

    constructor(Vault v, MockTIP20 t, address o, address e, address r) {
        vault = v;
        token = t;
        owner = o;
        executor = e;
        recipient = r;
    }

    function pay(uint256 amount) external {
        if (vault.revoked()) return;
        (Vault.Terms memory terms, uint64 rev, uint64 n, uint256 spent, uint256 daily, uint256 day,,) = vault.getState();
        if (block.timestamp >= terms.expiresAt) return;
        uint256 available = terms.totalUnits - spent;
        uint256 today = day == block.timestamp / 1 days ? daily : 0;
        available = _min(available, terms.dailyUnits - today);
        available = _min(available, terms.actionUnits);
        available = _min(available, token.balanceOf(address(vault)));
        if (available == 0) return;
        amount = bound(amount, 1, available);
        Vault.Execution memory r = Vault.Execution(
            block.chainid,
            address(vault),
            address(token),
            vault.policyId(),
            terms.policyDigest,
            terms.requirementsDigest,
            rev,
            n + 1,
            recipient,
            amount,
            uint64(_min(block.timestamp + 180, terms.expiresAt)),
            keccak256(abi.encode(n + 1)),
            keccak256("assessment"),
            bytes32("invariant")
        );
        (uint8 v, bytes32 rs, bytes32 s) = vm.sign(KEY, vault.executionDigest(r));
        vm.prank(executor);
        vault.execute(r, abi.encodePacked(rs, s, v));
        ++executions;
        totalPaid += amount;
        assertEq(vault.nonce(), n + 1);
        assertEq(vault.spent(), spent + amount);
    }

    function fund(uint256 amount) external {
        if (vault.revoked()) return;
        (Vault.Terms memory terms,,,,,,,) = vault.getState();
        if (block.timestamp >= terms.expiresAt) return;
        amount = bound(amount, 1, 1_000_000);
        token.mint(owner, amount);
        totalMinted += amount;
        vm.prank(owner);
        vault.fund(amount);
    }

    function advance(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 2 days));
    }

    function revise(bytes32 source) external {
        if (vault.revoked()) return;
        (Vault.Terms memory terms,,,,,,,) = vault.getState();
        terms.policyDigest = source == 0 ? bytes32(uint256(1)) : source;
        terms.expiresAt = uint64(block.timestamp + 30 days);
        vm.prank(owner);
        vault.tune(terms);
    }

    function recover(uint256 trigger) external {
        if (trigger % 16 != 0 || vault.revoked()) return;
        vm.prank(owner);
        vault.withdrawRemaining();
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

contract AllowItTempoVaultInvariantTest is StdInvariant, Test {
    Vault vault;
    MockTIP20 token;
    VaultHandler handler;
    address owner = address(0x1001);
    address executor = address(0x1002);
    address recipient = address(0x1003);

    function setUp() public {
        vm.warp(1_900_000_000);
        token = new MockTIP20();
        vm.mockCall(
            address(StdPrecompiles.TIP20_FACTORY),
            abi.encodeWithSignature("isTIP20(address)", address(token)),
            abi.encode(true)
        );
        Vault.Terms memory terms = Vault.Terms(
            keccak256("source"),
            keccak256("requirements"),
            10_000_000,
            3_000_000,
            1_000_000,
            uint64(block.timestamp + 30 days),
            address(0),
            true
        );
        vault = new Vault(owner, address(token), executor, vm.addr(0xA11CE), keccak256("invariant policy"), terms);
        token.mint(owner, 100_000_000);
        vm.startPrank(owner);
        token.approve(address(vault), type(uint256).max);
        vault.fund(10_000_000);
        vm.stopPrank();
        handler = new VaultHandler(vault, token, owner, executor, recipient);
        targetContract(address(handler));
    }

    function invariantHardCapsAndNonceAlwaysHold() public view {
        (Vault.Terms memory terms,,,,,,,) = vault.getState();
        assertLe(vault.spent(), terms.totalUnits);
        assertLe(vault.spentToday(), terms.dailyUnits);
        assertEq(vault.nonce(), handler.executions());
        assertEq(vault.spent(), handler.totalPaid());
    }

    function invariantTokensConservedAndOwnerOnlyRecovery() public view {
        assertEq(
            token.balanceOf(owner) + token.balanceOf(address(vault)) + token.balanceOf(recipient), handler.totalMinted()
        );
        assertEq(token.balanceOf(recipient), handler.totalPaid());
        if (vault.revoked()) assertEq(token.balanceOf(address(vault)), 0);
    }
}
