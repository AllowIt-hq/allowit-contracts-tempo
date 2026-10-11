// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AllowItTempoVault} from "./AllowItTempoVault.sol";

/// @notice Permissionless factory. A caller can create/fund only its own vault.
contract AllowItTempoVaultFactory is ReentrancyGuard {
    using SafeERC20 for IERC20;
    mapping(address owner => mapping(bytes32 policyId => address vault)) public vaultOf;
    error AlreadyCreated();
    error DeliveryMismatch();
    error InvalidFunding();
    event VaultCreated(
        address indexed owner,
        bytes32 indexed policyId,
        address indexed vault,
        address token,
        address executor,
        address authority
    );

    function createVault(
        bytes32 policyId,
        address token,
        address executor,
        address authority,
        AllowItTempoVault.Terms calldata terms,
        uint256 initialAmount
    ) external nonReentrant returns (address vault) {
        if (vaultOf[msg.sender][policyId] != address(0)) revert AlreadyCreated();
        if (initialAmount == 0 || initialAmount > terms.totalUnits) revert InvalidFunding();
        bytes32 salt = keccak256(abi.encode(msg.sender, policyId));
        vault = address(new AllowItTempoVault{salt: salt}(msg.sender, token, executor, authority, policyId, terms));
        vaultOf[msg.sender][policyId] = vault;
        uint256 beforeBalance = IERC20(token).balanceOf(vault);
        IERC20(token).safeTransferFrom(msg.sender, vault, initialAmount);
        uint256 afterBalance = IERC20(token).balanceOf(vault);
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != initialAmount) revert DeliveryMismatch();
        emit VaultCreated(msg.sender, policyId, vault, token, executor, authority);
    }

    function predictVault(
        address owner,
        bytes32 policyId,
        address token,
        address executor,
        address authority,
        AllowItTempoVault.Terms calldata terms
    ) external view returns (address) {
        bytes32 salt = keccak256(abi.encode(owner, policyId));
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(AllowItTempoVault).creationCode, abi.encode(owner, token, executor, authority, policyId, terms)
            )
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }
}
