// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Deliberately hostile ERC20-shaped token, admitted only by a mocked factory in unit tests.
contract MockTIP20 is ERC20 {
    bool public failing;
    bool public paused;
    address public redirect;
    address public reentryTarget;
    bytes public reentryData;
    bool public reentryBlocked;
    constructor() ERC20("Unit test dollars", "TEST") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function currency() external pure returns (string memory) {
        return "USD";
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function setFailing(bool value) external {
        failing = value;
    }

    function setPaused(bool value) external {
        paused = value;
    }

    function setRedirect(address value) external {
        redirect = value;
    }

    function setReentry(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryData = data;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (failing) return false;
        require(!paused, "token paused");
        if (reentryTarget != address(0)) {
            (bool ok,) = reentryTarget.call(reentryData);
            reentryBlocked = !ok;
        }
        return super.transfer(redirect == address(0) ? to : redirect, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (failing) return false;
        require(!paused, "token paused");
        return super.transferFrom(from, redirect == address(0) ? to : redirect, amount);
    }

    function transferWithMemo(address to, uint256 amount, bytes32) external {
        require(transfer(to, amount), "failed");
    }
}
