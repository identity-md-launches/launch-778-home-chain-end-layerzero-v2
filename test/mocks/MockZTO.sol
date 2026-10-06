// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockZTO is ERC20 {
    uint8 public transferMode;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackSucceeded;
    bytes public callbackResult;

    error MetadataMustNotBeRead();
    error TransferRejected();

    constructor() ERC20("Zero To One Mock", "ZTO") {}

    function decimals() public pure override returns (uint8) {
        revert MetadataMustNotBeRead();
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setTransferMode(uint8 mode) external {
        transferMode = mode;
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function _callback() private {
        address target = callbackTarget;
        if (target != address(0)) {
            callbackTarget = address(0);
            (callbackSucceeded, callbackResult) = target.call(callbackData);
        }
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (transferMode == 1) return false;
        if (transferMode == 3) revert TransferRejected();
        super.transfer(to, amount);
        _callback();
        if (transferMode == 2) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (transferMode == 1) return false;
        if (transferMode == 3) revert TransferRejected();
        super.transferFrom(from, to, amount);
        _callback();
        if (transferMode == 2) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return true;
    }
}
