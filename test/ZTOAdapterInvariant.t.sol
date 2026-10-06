// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ZTOAdapter} from "src/ZTOAdapter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    IOFT,
    SendParam,
    OFTReceipt,
    MessagingFee,
    MessagingReceipt
} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {Origin} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {OAppReceiver} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppReceiver.sol";
import {MockZTO} from "./mocks/MockZTO.sol";
import {EndpointV2Mock} from "./mocks/EndpointV2Mock.sol";
import {RobinhoodOFTMock} from "./mocks/RobinhoodOFTMock.sol";

/// @dev Endpoints are a trusted transport boundary, not a model of DVN security. Only
/// messages actually emitted by a send enter the queues. Delivery order is arbitrary.
contract ZTOBridgeHandler is Test {
    uint256 public constant RATE = 1e12;
    uint256 public constant FEE = 1e12;
    uint256 public constant START_BALANCE = 1_000_000 ether + 17;
    address public constant OWNER = 0xcECc29B037f5064fCdF45a5C318F132ef76aA551;
    uint32 internal constant HOME = 30101;
    uint32 internal constant ROBINHOOD = 30416;

    ZTOAdapter public immutable adapter;
    MockZTO public immutable token;
    RobinhoodOFTMock public immutable remote;
    EndpointV2Mock public immutable homeEndpoint;
    EndpointV2Mock public immutable remoteEndpoint;
    address public immutable verifier;
    address[4] public actors = [address(0xA11CE), address(0xB0B), address(0xCA401), address(0xDA7E)];

    mapping(address => uint256) public expectedHome;
    mapping(address => uint256) public expectedRemote;
    uint256 public totalLocked;
    uint256 public totalReleased;
    uint256 public donations;
    uint256 public pendingMint;
    uint256 public pendingRelease;
    uint256 public successfulLocks;
    uint256 public successfulBurns;
    uint256 public rejectedCalls;

    struct Packet {
        Origin origin;
        bytes32 guid;
        bytes message;
        address recipient;
        uint256 amount;
    }

    Packet[] internal outbound;
    Packet[] internal inbound;
    Packet[] internal completed;

    constructor(
        ZTOAdapter adapter_,
        MockZTO token_,
        RobinhoodOFTMock remote_,
        EndpointV2Mock homeEndpoint_,
        EndpointV2Mock remoteEndpoint_
    ) {
        adapter = adapter_;
        token = token_;
        remote = remote_;
        homeEndpoint = homeEndpoint_;
        remoteEndpoint = remoteEndpoint_;
        verifier = msg.sender;
        for (uint256 i; i < actors.length; ++i) {
            token.mint(actors[i], START_BALANCE);
            expectedHome[actors[i]] = START_BALANCE;
            vm.deal(actors[i], 100 ether);
        }
    }

    function lock(uint256 actorSeed, uint256 recipientSeed, uint256 rawAmount, bool fullBalance, bool compose) public {
        address actor = _actor(actorSeed);
        address recipient = _actor(recipientSeed);
        uint256 amount = fullBalance ? expectedHome[actor] : bound(rawAmount, 0, expectedHome[actor]);
        uint256 bridged = amount - amount % RATE;
        SendParam memory param = _params(ROBINHOOD, recipient, amount, compose);
        vm.startPrank(actor);
        token.approve(address(adapter), amount);
        (MessagingReceipt memory receipt, OFTReceipt memory oft) =
            adapter.send{value: FEE}(param, MessagingFee(FEE, 0), actor);
        vm.stopPrank();
        _assertReceipt(oft, bridged);
        assertEq(token.allowance(actor, address(adapter)), amount - bridged, "dust spent from allowance");
        _assertWire(homeEndpoint.lastMessage(), recipient, actor, bridged, compose);
        assertEq(receipt.nonce, successfulLocks + 1, "outbound nonce");
        assertEq(homeEndpoint.lastReceiver(), _word(address(remote)), "wrong destination peer");
        outbound.push(
            Packet(
                Origin(HOME, _word(address(adapter)), receipt.nonce),
                receipt.guid,
                homeEndpoint.lastMessage(),
                recipient,
                bridged
            )
        );
        expectedHome[actor] -= bridged;
        totalLocked += bridged;
        pendingMint += bridged;
        ++successfulLocks;
    }

    function deliverRemote(uint256 indexSeed) public {
        if (outbound.length == 0) return;
        uint256 index = indexSeed % outbound.length;
        Packet memory packet = outbound[index];
        _queueAndDeliver(remoteEndpoint, address(remote), packet);
        expectedRemote[packet.recipient] += packet.amount;
        pendingMint -= packet.amount;
        outbound[index] = outbound[outbound.length - 1];
        outbound.pop();
    }

    function burn(uint256 actorSeed, uint256 recipientSeed, uint256 rawAmount, bool fullBalance, bool compose) public {
        address actor = _actor(actorSeed);
        address recipient = _actor(recipientSeed);
        uint256 amount = fullBalance ? expectedRemote[actor] : bound(rawAmount, 0, expectedRemote[actor]);
        uint256 bridged = amount - amount % RATE;
        SendParam memory param = _params(HOME, recipient, amount, compose);
        vm.prank(actor);
        (MessagingReceipt memory receipt, OFTReceipt memory oft) =
            remote.send{value: FEE}(param, MessagingFee(FEE, 0), actor);
        _assertReceipt(oft, bridged);
        _assertWire(remoteEndpoint.lastMessage(), recipient, actor, bridged, compose);
        assertEq(receipt.nonce, successfulBurns + 1, "return nonce");
        inbound.push(
            Packet(
                Origin(ROBINHOOD, _word(address(remote)), receipt.nonce),
                receipt.guid,
                remoteEndpoint.lastMessage(),
                recipient,
                bridged
            )
        );
        expectedRemote[actor] -= bridged;
        pendingRelease += bridged;
        ++successfulBurns;
    }

    function deliverHome(uint256 indexSeed) public {
        if (inbound.length == 0) return;
        uint256 index = indexSeed % inbound.length;
        Packet memory packet = inbound[index];
        _queueAndDeliver(homeEndpoint, address(adapter), packet);
        expectedHome[packet.recipient] += packet.amount;
        totalReleased += packet.amount;
        pendingRelease -= packet.amount;
        completed.push(packet);
        inbound[index] = inbound[inbound.length - 1];
        inbound.pop();
    }

    function donate(uint256 actorSeed, uint256 rawAmount) public {
        address actor = _actor(actorSeed);
        // Keep spendable funds in the actor population throughout long campaigns.
        uint256 maximum = expectedHome[actor] < 100 ether ? expectedHome[actor] : 100 ether;
        uint256 amount = bound(rawAmount, 0, maximum);
        vm.prank(actor);
        token.transfer(address(adapter), amount);
        expectedHome[actor] -= amount;
        donations += amount;
    }

    function transferBetweenActors(uint256 fromSeed, uint256 toSeed, uint256 rawAmount, bool onRemote) public {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        if (onRemote) {
            uint256 amount = bound(rawAmount, 0, expectedRemote[from]);
            vm.prank(from);
            remote.transfer(to, amount);
            expectedRemote[from] -= amount;
            expectedRemote[to] += amount;
        } else {
            uint256 amount = bound(rawAmount, 0, expectedHome[from]);
            vm.prank(from);
            token.transfer(to, amount);
            expectedHome[from] -= amount;
            expectedHome[to] += amount;
        }
    }

    /// @dev Expected failures are caught explicitly; all other handler reverts fail the campaign.
    function rejectedSend(uint256 actorSeed, uint256 rawAmount, uint8 failureSeed) public {
        address actor = _actor(actorSeed);
        uint256 amount = bound(rawAmount, 0, expectedHome[actor]);
        SendParam memory param = _params(ROBINHOOD, actor, amount, false);
        uint256 rounded = amount - amount % RATE;
        uint256 mode = failureSeed % 5;
        bytes memory reason;
        if (mode == 0) {
            param.minAmountLD = rounded + 1;
            reason = abi.encodeWithSelector(IOFT.SlippageExceeded.selector, rounded, rounded + 1);
        } else if (mode == 1) {
            token.setTransferMode(1);
            reason = abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token));
        } else if (mode == 2) {
            homeEndpoint.setFailures(false, true, false);
            reason = abi.encodeWithSelector(EndpointV2Mock.SendRejected.selector);
        } else if (mode == 3) {
            vm.prank(OWNER);
            adapter.setPeer(ROBINHOOD, bytes32(0));
            reason = abi.encodeWithSelector(IOAppCore.NoPeer.selector, ROBINHOOD);
        } else {
            // Even a zero-value send cannot pass an endpoint fee increase.
            homeEndpoint.setFees(FEE + 1, 0, address(0));
            reason = abi.encodeWithSelector(EndpointV2Mock.InsufficientFee.selector);
        }
        uint256 ethBefore = actor.balance;
        bytes32 messageBefore = keccak256(homeEndpoint.lastMessage());
        vm.startPrank(actor);
        token.approve(address(adapter), amount);
        vm.expectRevert(reason);
        adapter.send{value: FEE}(param, MessagingFee(FEE, 0), actor);
        vm.stopPrank();
        assertEq(actor.balance, ethBefore, "failed send spent native fee");
        assertEq(token.allowance(actor, address(adapter)), amount, "failed send spent allowance");
        assertEq(homeEndpoint.lastNonce(), successfulLocks, "failed send consumed nonce");
        assertEq(keccak256(homeEndpoint.lastMessage()), messageBefore, "failed send changed packet");
        token.setTransferMode(0);
        homeEndpoint.setFailures(false, false, false);
        homeEndpoint.setFees(FEE, 0, address(0));
        vm.prank(OWNER);
        adapter.setPeer(ROBINHOOD, _word(address(remote)));
        ++rejectedCalls;
    }

    function rejectedDeliveryThenRetry(uint256 indexSeed, uint8 failureSeed) public {
        if (inbound.length == 0) return;
        uint256 index = indexSeed % inbound.length;
        Packet memory packet = inbound[index];
        vm.prank(verifier);
        homeEndpoint.queue(packet.origin, address(adapter), packet.guid, packet.message);
        bytes32 key = homeEndpoint.packetKey(packet.origin, address(adapter));
        bytes32 payloadHash = homeEndpoint.verified(key);
        uint256 escrowBefore = token.balanceOf(address(adapter));
        uint256 userBefore = token.balanceOf(packet.recipient);
        bytes memory reason;
        uint256 mode = failureSeed % 3;
        if (mode == 0) {
            vm.prank(OWNER);
            adapter.setPeer(ROBINHOOD, bytes32(0));
            reason = abi.encodeWithSelector(IOAppCore.NoPeer.selector, ROBINHOOD);
        } else if (mode == 1 && packet.message.length > 40) {
            homeEndpoint.setFailures(false, false, true);
            reason = abi.encodeWithSelector(EndpointV2Mock.ComposeRejected.selector);
        } else {
            token.setTransferMode(3);
            reason = abi.encodeWithSelector(MockZTO.TransferRejected.selector);
        }
        vm.expectRevert(reason);
        homeEndpoint.deliver(packet.origin, address(adapter), packet.guid, packet.message);
        assertEq(token.balanceOf(address(adapter)), escrowBefore, "failed delivery lost custody");
        assertEq(token.balanceOf(packet.recipient), userBefore, "failed delivery credited user");
        assertEq(homeEndpoint.verified(key), payloadHash, "failed delivery consumed payload");
        assertFalse(homeEndpoint.delivered(key), "failed delivery marked complete");
        token.setTransferMode(0);
        homeEndpoint.setFailures(false, false, false);
        vm.prank(OWNER);
        adapter.setPeer(ROBINHOOD, _word(address(remote)));
        ++rejectedCalls;
        deliverHome(index);
    }

    function unauthorizedCalls(uint256 actorSeed, uint64 amountSD) public {
        address actor = _actor(actorSeed);
        bytes memory reason = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, actor);
        vm.startPrank(actor);
        vm.expectRevert(reason);
        adapter.setPeer(ROBINHOOD, _word(actor));
        vm.expectRevert(reason);
        adapter.setDelegate(actor);
        vm.expectRevert(abi.encodeWithSelector(OAppReceiver.OnlyEndpoint.selector, actor));
        adapter.lzReceive(
            Origin(ROBINHOOD, _word(address(remote)), 1),
            bytes32(0),
            abi.encodePacked(_word(actor), amountSD),
            actor,
            ""
        );
        vm.stopPrank();
        rejectedCalls += 3;
    }

    function replay(uint256 indexSeed) public {
        if (completed.length == 0) return;
        Packet memory packet = completed[indexSeed % completed.length];
        vm.expectRevert(EndpointV2Mock.AlreadyDelivered.selector);
        homeEndpoint.deliver(packet.origin, address(adapter), packet.guid, packet.message);
        ++rejectedCalls;
    }

    /// @dev Not targeted by the fuzzer; the invariant runner calls this after each campaign.
    function settleAll() external {
        while (outbound.length != 0) deliverRemote(outbound.length - 1);
        // ERC20 transfers can split shared-decimal units between users. Recombine
        // their dust before redemption; aggregate minted supply is a multiple of RATE.
        for (uint256 i = 1; i < actors.length; ++i) {
            transferBetweenActors(i, 0, expectedRemote[actors[i]], true);
        }
        burn(0, 0, 0, true, false);
        while (inbound.length != 0) deliverHome(inbound.length - 1);
    }

    function _queueAndDeliver(EndpointV2Mock endpoint, address receiver, Packet memory packet) internal {
        vm.prank(verifier);
        endpoint.queue(packet.origin, receiver, packet.guid, packet.message);
        endpoint.deliver(packet.origin, receiver, packet.guid, packet.message);
        assertTrue(endpoint.delivered(endpoint.packetKey(packet.origin, receiver)));
        assertEq(endpoint.verified(endpoint.packetKey(packet.origin, receiver)), bytes32(0));
        if (packet.message.length > 40) {
            assertEq(endpoint.composedTo(), packet.recipient);
            assertEq(endpoint.composedFrom(), receiver);
            assertEq(endpoint.composedGuid(), packet.guid);
            assertEq(endpoint.composedIndex(), 0);
            // Sender plus the fixed nonempty compose data generated by _params.
            bytes memory tail = new bytes(packet.message.length - 40);
            for (uint256 i; i < tail.length; ++i) {
                tail[i] = packet.message[i + 40];
            }
            assertEq(
                endpoint.composedMessage(),
                abi.encodePacked(packet.origin.nonce, packet.origin.srcEid, packet.amount, tail)
            );
        }
    }

    function _assertWire(bytes memory message, address recipient, address sender, uint256 amount, bool compose)
        internal
        pure
    {
        bytes memory expected = abi.encodePacked(_word(recipient), uint64(amount / RATE));
        if (compose) expected = abi.encodePacked(expected, _word(sender), hex"aabbcc");
        assertEq(message, expected, "noncanonical OFT packet");
    }

    function _assertReceipt(OFTReceipt memory receipt, uint256 amount) internal pure {
        assertEq(receipt.amountSentLD, amount, "incorrect debit receipt");
        assertEq(receipt.amountReceivedLD, amount, "unexpected bridge fee");
    }

    function _params(uint32 destination, address to, uint256 amount, bool compose)
        internal
        pure
        returns (SendParam memory)
    {
        return SendParam(
            destination, _word(to), amount, amount - amount % RATE, "", compose ? bytes(hex"aabbcc") : bytes(""), ""
        );
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _word(address account) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract ZTOAdapterInvariantTest is Test {
    address internal constant ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    address internal constant TOKEN = 0xd782Bdea4EF02a0Bd391eb9089470c8080f0A68e;
    address internal constant OWNER = 0xcECc29B037f5064fCdF45a5C318F132ef76aA551;
    ZTOBridgeHandler internal handler;
    ZTOAdapter internal adapter;
    MockZTO internal token;
    RobinhoodOFTMock internal remote;
    EndpointV2Mock internal homeEndpoint;
    EndpointV2Mock internal remoteEndpoint;

    function setUp() public {
        EndpointV2Mock implementation = new EndpointV2Mock(30101);
        vm.etch(ENDPOINT, address(implementation).code);
        homeEndpoint = EndpointV2Mock(ENDPOINT);
        homeEndpoint.setFees(1e12, 0, address(0));
        MockZTO tokenImplementation = new MockZTO();
        vm.etch(TOKEN, address(tokenImplementation).code);
        token = MockZTO(TOKEN);
        adapter = new ZTOAdapter();
        remoteEndpoint = new EndpointV2Mock(30416);
        remoteEndpoint.setFees(1e12, 0, address(0));
        remote = new RobinhoodOFTMock(address(remoteEndpoint), OWNER);
        vm.startPrank(OWNER);
        adapter.setPeer(30416, bytes32(uint256(uint160(address(remote)))));
        remote.setPeer(30101, bytes32(uint256(uint160(address(adapter)))));
        vm.stopPrank();
        handler = new ZTOBridgeHandler(adapter, token, remote, homeEndpoint, remoteEndpoint);

        // Nonzero completed and pending traffic makes the initial state nonvacuous.
        handler.lock(0, 1, 100 ether + 1, false, true);
        handler.deliverRemote(0);
        handler.burn(1, 2, 30 ether, false, true);
        handler.deliverHome(0);
        handler.burn(1, 3, 20 ether, false, false);
        handler.lock(3, 0, 50 ether + 7, false, false);

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.lock.selector;
        selectors[1] = handler.deliverRemote.selector;
        selectors[2] = handler.burn.selector;
        selectors[3] = handler.deliverHome.selector;
        selectors[4] = handler.donate.selector;
        selectors[5] = handler.transferBetweenActors.selector;
        selectors[6] = handler.rejectedSend.selector;
        selectors[7] = handler.rejectedDeliveryThenRetry.selector;
        selectors[8] = handler.unauthorizedCalls.selector;
        selectors[9] = handler.replay.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// @dev Exact accounting identities for a lossless lock/mint/burn/release bridge.
    function invariant_custodySupplyAndActorBalancesAreConserved() public view {
        uint256 supply = 4 * handler.START_BALANCE();
        uint256 custody = token.balanceOf(address(adapter));
        assertEq(token.totalSupply(), supply, "home supply changed");
        assertEq(custody + handler.totalReleased(), handler.totalLocked() + handler.donations(), "custody ledger");
        assertEq(
            custody,
            remote.totalSupply() + handler.pendingMint() + handler.pendingRelease() + handler.donations(),
            "unbacked remote or pending funds"
        );
        uint256 homeBalances;
        uint256 remoteBalances;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            assertEq(token.balanceOf(actor), handler.expectedHome(actor), "wrong home beneficiary or debit");
            assertEq(remote.balanceOf(actor), handler.expectedRemote(actor), "wrong remote beneficiary or debit");
            homeBalances += token.balanceOf(actor);
            remoteBalances += remote.balanceOf(actor);
        }
        assertEq(homeBalances + custody, supply, "home token conservation");
        assertEq(remoteBalances, remote.totalSupply(), "remote token conservation");
        assertEq(address(adapter).balance, 0, "native fee stranded in adapter");
        assertEq(ENDPOINT.balance, handler.successfulLocks() * handler.FEE(), "incorrect send fee accounting");
        assertEq(address(remoteEndpoint).balance, handler.successfulBurns() * handler.FEE(), "incorrect return fees");
        assertEq(adapter.owner(), OWNER);
        assertEq(homeEndpoint.delegates(address(adapter)), OWNER);
        assertEq(adapter.peers(30416), bytes32(uint256(uint160(address(remote)))));
        assertGt(handler.totalLocked(), 0);
        assertGt(handler.totalReleased(), 0);
    }

    function afterInvariant() public {
        handler.settleAll();
        invariant_custodySupplyAndActorBalancesAreConserved();
        assertEq(remote.totalSupply(), 0, "could not redeem remote supply");
        assertEq(handler.pendingMint(), 0);
        assertEq(handler.pendingRelease(), 0);
        assertEq(token.balanceOf(address(adapter)), handler.donations(), "redeemable funds stranded");
    }

    function testHandlerExercisesFailuresAndOutOfOrderSettlement() public {
        for (uint8 mode; mode < 5; ++mode) {
            handler.rejectedSend(0, 1 ether, mode);
        }
        handler.unauthorizedCalls(0, type(uint64).max);
        handler.replay(0);
        handler.deliverRemote(0);
        handler.transferBetweenActors(0, 2, 1 ether + 1, true);
        handler.transferBetweenActors(2, 1, 1 ether + 1, false);
        for (uint8 mode; mode < 3; ++mode) {
            handler.burn(0, 2, 1 ether, false, true);
            // Select the newly appended packet ahead of the older pending return.
            handler.rejectedDeliveryThenRetry(1, mode);
        }
        handler.donate(3, 123);
        handler.lock(1, 3, 0, true, false);
        assertEq(handler.rejectedCalls(), 12);
        invariant_custodySupplyAndActorBalancesAreConserved();
        afterInvariant();
    }
}
