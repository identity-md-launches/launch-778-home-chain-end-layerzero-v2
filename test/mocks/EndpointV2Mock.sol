// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    MessagingParams,
    MessagingFee,
    MessagingReceipt,
    Origin
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {ILayerZeroReceiver} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroReceiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Test boundary only. Queueing stands in for DVN verification; delivery consumes a
///      verified payload before calling the receiver and rolls back consumption on failure.
///      This is not an implementation or security test of the production EndpointV2.
contract EndpointV2Mock {
    uint32 public immutable eid;
    address public immutable verifier;
    mapping(address => address) public delegates;
    uint256 public delegateCalls;
    bool public rejectDelegate;
    bool public rejectSend;
    bool public rejectCompose;
    uint256 public nativeFee;
    uint256 public lzFee;
    address public lzToken;
    mapping(bytes32 => uint64) public outboundNonce;
    mapping(bytes32 => bytes32) public verified;
    mapping(bytes32 => bool) public delivered;

    bytes public lastMessage;
    bytes public lastOptions;
    bytes32 public lastReceiver;
    uint32 public lastDstEid;
    address public lastSender;
    address public lastRefundAddress;
    bool public lastPayInLzToken;
    bytes32 public lastGuid;
    uint64 public lastNonce;
    bytes public composedMessage;
    address public composedTo;
    bytes32 public composedGuid;
    uint16 public composedIndex;
    address public composedFrom;

    error DelegateRejected();
    error SendRejected();
    error ComposeRejected();
    error InsufficientFee();
    error NotVerified();
    error AlreadyDelivered();

    constructor(uint32 eid_) {
        eid = eid_;
        verifier = msg.sender;
    }

    function setFailures(bool delegate_, bool send_, bool compose_) external {
        rejectDelegate = delegate_;
        rejectSend = send_;
        rejectCompose = compose_;
    }

    function setFees(uint256 native_, uint256 lz_, address token_) external {
        nativeFee = native_;
        lzFee = lz_;
        lzToken = token_;
    }

    function setDelegate(address delegate_) external {
        if (rejectDelegate) revert DelegateRejected();
        delegates[msg.sender] = delegate_;
        ++delegateCalls;
    }

    function quote(MessagingParams calldata params, address) external view returns (MessagingFee memory) {
        return MessagingFee(nativeFee, params.payInLzToken ? lzFee : 0);
    }

    function send(MessagingParams calldata params, address refundAddress)
        external
        payable
        returns (MessagingReceipt memory receipt)
    {
        if (rejectSend) revert SendRejected();
        if (msg.value < nativeFee) revert InsufficientFee();
        if (params.payInLzToken && IERC20(lzToken).balanceOf(address(this)) < lzFee) revert InsufficientFee();
        bytes32 path = keccak256(abi.encode(msg.sender, params.dstEid, params.receiver));
        uint64 nonce = ++outboundNonce[path];
        bytes32 guid = keccak256(abi.encodePacked(nonce, eid, msg.sender, params.dstEid, params.receiver));
        lastMessage = params.message;
        lastOptions = params.options;
        lastReceiver = params.receiver;
        lastDstEid = params.dstEid;
        lastSender = msg.sender;
        lastRefundAddress = refundAddress;
        lastPayInLzToken = params.payInLzToken;
        lastGuid = guid;
        lastNonce = nonce;
        receipt = MessagingReceipt(guid, nonce, MessagingFee(nativeFee, params.payInLzToken ? lzFee : 0));
        if (msg.value > nativeFee) {
            (bool success,) = refundAddress.call{value: msg.value - nativeFee}("");
            require(success, "refund failed");
        }
    }

    function packetKey(Origin calldata origin, address receiver) public pure returns (bytes32) {
        return keccak256(abi.encode(origin.srcEid, origin.sender, origin.nonce, receiver));
    }

    function queue(Origin calldata origin, address receiver, bytes32 guid, bytes calldata message) external {
        require(msg.sender == verifier, "not mock verifier");
        bytes32 key = packetKey(origin, receiver);
        if (delivered[key]) revert AlreadyDelivered();
        verified[key] = keccak256(abi.encodePacked(guid, message));
    }

    function deliver(Origin calldata origin, address receiver, bytes32 guid, bytes calldata message) external {
        bytes32 key = packetKey(origin, receiver);
        if (delivered[key]) revert AlreadyDelivered();
        if (verified[key] == bytes32(0) || verified[key] != keccak256(abi.encodePacked(guid, message))) {
            revert NotVerified();
        }
        delete verified[key];
        delivered[key] = true;
        ILayerZeroReceiver(receiver).lzReceive(origin, guid, message, msg.sender, "");
    }

    function sendCompose(address to, bytes32 guid, uint16 index, bytes calldata message) external {
        if (rejectCompose) revert ComposeRejected();
        composedFrom = msg.sender;
        composedTo = to;
        composedGuid = guid;
        composedIndex = index;
        composedMessage = message;
    }
}
