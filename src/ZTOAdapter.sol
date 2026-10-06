// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OFTAdapter} from "@layerzerolabs/oft-evm/contracts/OFTAdapter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @notice Ethereum custody adapter for the existing Zero To One token.
/// @dev A single Robinhood OFT must mint/burn the representation backed by this adapter.
///      Token transfers must be lossless and the remote OFT must use six shared decimals.
contract ZTOAdapter is OFTAdapter {
    address public constant ZTO = 0xd782Bdea4EF02a0Bd391eb9089470c8080f0A68e;
    address public constant ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    address public constant INITIAL_OWNER = 0xcECc29B037f5064fCdF45a5C318F132ef76aA551;
    uint32 public constant HOME_EID = 30101;
    uint32 public constant ROBINHOOD_EID = 30416;
    uint8 public constant LOCAL_DECIMALS = 18;

    error UnsupportedEndpoint(uint32 eid);

    /// @dev No arguments, no token metadata calls, and no dependency on the deployer's identity.
    ///      OAppCore registers INITIAL_OWNER as delegate only if ENDPOINT has code.
    constructor() OFTAdapter(ZTO, LOCAL_DECIMALS, ENDPOINT, INITIAL_OWNER) Ownable(INITIAL_OWNER) {}

    /// @notice Configure, replace, or remove the sole remote peer (zero removes it).
    function setPeer(uint32 eid, bytes32 peer) public override onlyOwner {
        if (eid != ROBINHOOD_EID) revert UnsupportedEndpoint(eid);
        _setPeer(eid, peer);
    }
}
