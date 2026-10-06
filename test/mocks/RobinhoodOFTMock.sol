// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OFT} from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev Interoperability fixture only; the actual Robinhood deployment is outside this task.
contract RobinhoodOFTMock is OFT {
    constructor(address endpoint_, address owner_) OFT("Zero To One", "ZTO", endpoint_, owner_) Ownable(owner_) {}
}
