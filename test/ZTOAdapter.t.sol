// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ZTOAdapter} from "../src/ZTOAdapter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    IOFT,
    SendParam,
    OFTLimit,
    OFTFeeDetail,
    OFTReceipt,
    MessagingFee,
    MessagingReceipt
} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {Origin} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {IOAppCore} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import {OAppSender} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";
import {OAppReceiver} from "@layerzerolabs/oapp-evm/contracts/oapp/OAppReceiver.sol";
import {
    IOAppPreCrimeSimulator,
    InboundPacket
} from "@layerzerolabs/oapp-evm/contracts/precrime/interfaces/IOAppPreCrimeSimulator.sol";
import {
    IOAppOptionsType3,
    EnforcedOptionParam
} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppOptionsType3.sol";
import {MockZTO} from "./mocks/MockZTO.sol";
import {EndpointV2Mock} from "./mocks/EndpointV2Mock.sol";
import {RobinhoodOFTMock} from "./mocks/RobinhoodOFTMock.sol";

contract RejectingInspector {
    error InspectionRejected();

    function inspect(bytes calldata, bytes calldata) external pure {
        revert InspectionRejected();
    }
}

contract ZTOAdapterTest is Test {
    address internal constant OWNER = 0xcECc29B037f5064fCdF45a5C318F132ef76aA551;
    address internal constant ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    address internal constant TOKEN = 0xd782Bdea4EF02a0Bd391eb9089470c8080f0A68e;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    uint32 internal constant HOME = 30101;
    uint32 internal constant ROBINHOOD = 30416;
    uint256 internal constant RATE = 1e12;
    uint256 internal constant FEE = 0.001 ether;
    uint256 internal constant INITIAL_BALANCE = 1000 ether;

    ZTOAdapter internal adapter;
    MockZTO internal token;
    EndpointV2Mock internal endpoint;
    EndpointV2Mock internal remoteEndpoint;
    RobinhoodOFTMock internal remote;
    bytes32 internal peer;

    function setUp() public {
        EndpointV2Mock endpointImplementation = new EndpointV2Mock(HOME);
        vm.etch(ENDPOINT, address(endpointImplementation).code);
        endpoint = EndpointV2Mock(ENDPOINT);
        endpoint.setFees(FEE, 0, address(0));
        MockZTO tokenImplementation = new MockZTO();
        vm.etch(TOKEN, address(tokenImplementation).code);
        token = MockZTO(TOKEN);
        adapter = new ZTOAdapter();
        remoteEndpoint = new EndpointV2Mock(ROBINHOOD);
        remoteEndpoint.setFees(FEE, 0, address(0));
        remote = new RobinhoodOFTMock(address(remoteEndpoint), OWNER);
        peer = _addressBytes(address(remote));
        vm.startPrank(OWNER);
        adapter.setPeer(ROBINHOOD, peer);
        remote.setPeer(HOME, _addressBytes(address(adapter)));
        vm.stopPrank();
        token.mint(ALICE, INITIAL_BALANCE);
        vm.deal(ALICE, 10 ether);
        vm.deal(BOB, 10 ether);
    }

    function testInterfaceVersionsAndPathInitialization() public view {
        (bytes4 interfaceId, uint64 version) = adapter.oftVersion();
        assertEq(interfaceId, type(IOFT).interfaceId);
        assertEq(version, 1);
        (uint64 senderVersion, uint64 receiverVersion) = adapter.oAppVersion();
        assertEq(senderVersion, 1);
        assertEq(receiverVersion, 2);
        assertTrue(adapter.allowInitializePath(_origin(1)));
        assertFalse(adapter.allowInitializePath(Origin(ROBINHOOD, bytes32(uint256(7)), 1)));
        assertFalse(adapter.allowInitializePath(Origin(HOME, peer, 1)));
        assertEq(adapter.nextNonce(ROBINHOOD, peer), 0);
        assertTrue(adapter.isPeer(ROBINHOOD, peer));
        assertTrue(adapter.isComposeMsgSender(_origin(1), "", address(adapter)));
        assertFalse(adapter.isComposeMsgSender(_origin(1), "", ALICE));
    }

    function testOnlyOwnerCanSetPeer() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        adapter.setPeer(ROBINHOOD, _addressBytes(ALICE));
        assertEq(adapter.peers(ROBINHOOD), peer);
        vm.expectEmit(true, false, false, true, address(adapter));
        emit IOAppCore.PeerSet(ROBINHOOD, _addressBytes(BOB));
        vm.prank(OWNER);
        adapter.setPeer(ROBINHOOD, _addressBytes(BOB));
        assertEq(adapter.peers(ROBINHOOD), _addressBytes(BOB));
    }

    function testOwnerCannotEnableAnotherChain() public {
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ZTOAdapter.UnsupportedEndpoint.selector, HOME));
        adapter.setPeer(HOME, peer);
    }

    function testPeerRemovalBlocksSendQuoteAndReceive() public {
        vm.prank(OWNER);
        adapter.setPeer(ROBINHOOD, bytes32(0));
        SendParam memory p = _params(1 ether);
        vm.expectRevert(abi.encodeWithSelector(IOAppCore.NoPeer.selector, ROBINHOOD));
        adapter.quoteSend(p, false);
        _approve(p.amountLD);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IOAppCore.NoPeer.selector, ROBINHOOD));
        adapter.send{value: FEE}(p, MessagingFee(FEE, 0), ALICE);
        assertEq(token.balanceOf(ALICE), INITIAL_BALANCE);
        vm.prank(ENDPOINT);
        vm.expectRevert(abi.encodeWithSelector(IOAppCore.NoPeer.selector, ROBINHOOD));
        adapter.lzReceive(_origin(1), bytes32(0), _message(BOB, 1e6), address(0), "");
    }

    function testDelegateChangeAndOwnershipTransferAreSeparate() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        adapter.setDelegate(ALICE);
        vm.prank(OWNER);
        adapter.setDelegate(BOB);
        assertEq(endpoint.delegates(address(adapter)), BOB);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, BOB));
        adapter.setPeer(ROBINHOOD, _addressBytes(BOB));
        vm.prank(OWNER);
        adapter.transferOwnership(ALICE);
        assertEq(adapter.owner(), ALICE);
        assertEq(endpoint.delegates(address(adapter)), BOB);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OWNER));
        adapter.setDelegate(OWNER);
        vm.prank(ALICE);
        adapter.setDelegate(ALICE);
        assertEq(endpoint.delegates(address(adapter)), ALICE);
    }

    function testQuoteHasNoApplicationFeeAndDoesNotMoveTokens() public view {
        SendParam memory p = _params(5 ether + 123);
        (OFTLimit memory limit, OFTFeeDetail[] memory fees, OFTReceipt memory receipt) = adapter.quoteOFT(p);
        assertEq(limit.minAmountLD, 0);
        assertEq(limit.maxAmountLD, INITIAL_BALANCE);
        assertEq(fees.length, 0);
        assertEq(receipt.amountSentLD, 5 ether);
        assertEq(receipt.amountReceivedLD, 5 ether);
        MessagingFee memory fee = adapter.quoteSend(p, false);
        assertEq(fee.nativeFee, FEE);
        assertEq(fee.lzTokenFee, 0);
        assertEq(token.balanceOf(ALICE), INITIAL_BALANCE);
        assertEq(token.balanceOf(address(adapter)), 0);
    }

    function testSendLocksRoundedAmountAndEncodesCanonicalMessage() public {
        SendParam memory p = _params(5 ether + 123);
        p.extraOptions = _receiveOptions(200_000);
        _approve(p.amountLD);
        uint256 aliceETH = ALICE.balance;
        MessagingFee memory quotedFee = adapter.quoteSend(p, false);
        bytes32 guid = keccak256(abi.encodePacked(uint64(1), HOME, address(adapter), ROBINHOOD, peer));
        vm.expectEmit(true, true, false, true, address(adapter));
        emit IOFT.OFTSent(guid, ROBINHOOD, ALICE, 5 ether, 5 ether);
        vm.prank(ALICE);
        (MessagingReceipt memory msgReceipt, OFTReceipt memory receipt) = adapter.send{value: FEE}(p, quotedFee, BOB);
        assertEq(receipt.amountSentLD, 5 ether);
        assertEq(receipt.amountReceivedLD, 5 ether);
        assertEq(msgReceipt.guid, guid);
        assertEq(msgReceipt.nonce, 1);
        assertEq(msgReceipt.fee.nativeFee, FEE);
        assertEq(token.balanceOf(ALICE), INITIAL_BALANCE - 5 ether);
        assertEq(token.balanceOf(address(adapter)), 5 ether);
        assertEq(token.allowance(ALICE, address(adapter)), 123);
        assertEq(token.totalSupply(), INITIAL_BALANCE);
        assertEq(endpoint.lastMessage(), abi.encodePacked(_addressBytes(BOB), uint64(5e6)));
        assertEq(endpoint.lastOptions(), p.extraOptions);
        assertEq(endpoint.lastReceiver(), peer);
        assertEq(endpoint.lastDstEid(), ROBINHOOD);
        assertEq(endpoint.lastSender(), address(adapter));
        assertEq(endpoint.lastRefundAddress(), BOB);
        assertEq(ALICE.balance, aliceETH - FEE);
        assertEq(address(adapter).balance, 0);
        assertEq(ENDPOINT.balance, FEE);
    }

    function testSendRequiresApprovalAndRollsBack() public {
        SendParam memory p = _params(1 ether);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(adapter), 0, 1 ether)
        );
        adapter.send{value: FEE}(p, MessagingFee(FEE, 0), ALICE);
        _assertNoSend();
    }

    function testSendRequiresBalanceAndRollsBackAllowance() public {
        SendParam memory p = _params(INITIAL_BALANCE + 1 ether);
        _approve(p.amountLD);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, INITIAL_BALANCE, p.amountLD)
        );
        adapter.send{value: FEE}(p, MessagingFee(FEE, 0), ALICE);
        assertEq(token.allowance(ALICE, address(adapter)), p.amountLD);
        _assertNoSend();
    }

    function testDustCannotSatisfyMinimum() public {
        SendParam memory p = _params(1 ether + 1);
        p.minAmountLD = p.amountLD;
        bytes memory errorData = abi.encodeWithSelector(IOFT.SlippageExceeded.selector, 1 ether, p.amountLD);
        vm.expectRevert(errorData);
        adapter.quoteOFT(p);
        vm.expectRevert(errorData);
        adapter.quoteSend(p, false);
        _approve(p.amountLD);
        vm.prank(ALICE);
        vm.expectRevert(errorData);
        adapter.send{value: FEE}(p, MessagingFee(FEE, 0), ALICE);
        _assertNoSend();
    }

    function testSubDustZeroMinimumFollowsUpstreamZeroSendSemantics() public {
        SendParam memory p = _params(RATE - 1);
        (, OFTReceipt memory receipt) = _send(p);
        assertEq(receipt.amountSentLD, 0);
        assertEq(receipt.amountReceivedLD, 0);
        assertEq(token.balanceOf(ALICE), INITIAL_BALANCE);
        assertEq(token.balanceOf(address(adapter)), 0);
        assertEq(endpoint.lastMessage(), _message(BOB, 0));
    }

    function testSharedDecimalOverflowRevertsAtomically() public {
        uint256 amountSD = uint256(type(uint64).max) + 1;
        SendParam memory p = _params(amountSD * RATE);
        token.mint(ALICE, p.amountLD);
        _approve(p.amountLD);
        vm.expectRevert(abi.encodeWithSelector(IOFT.AmountSDOverflowed.selector, amountSD));
        adapter.quoteSend(p, false);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IOFT.AmountSDOverflowed.selector, amountSD));
        adapter.send{value: FEE}(p, MessagingFee(FEE, 0), ALICE);
        assertEq(token.balanceOf(address(adapter)), 0);
        assertEq(token.balanceOf(ALICE), INITIAL_BALANCE + p.amountLD);
        assertEq(token.allowance(ALICE, address(adapter)), p.amountLD);
        assertEq(endpoint.lastNonce(), 0);
    }

    function testMaximumSharedDecimalAmountIsSupported() public {
        uint256 amount = uint256(type(uint64).max) * RATE;
        token.mint(ALICE, amount);
        _send(_params(amount));
        assertEq(endpoint.lastMessage(), _message(BOB, type(uint64).max));
        _receive(BOB, type(uint64).max, 1);
        assertEq(token.balanceOf(BOB), amount);
        assertEq(token.balanceOf(address(adapter)), 0);
    }

    function testIncorrectMsgValueAndStaleFeeRevertAtomically() public {
        SendParam memory p = _params(1 ether);
        _approve(p.amountLD);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(OAppSender.NotEnoughNative.selector, FEE - 1));
        adapter.send{value: FEE - 1}(p, MessagingFee(FEE, 0), ALICE);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(OAppSender.NotEnoughNative.selector, FEE + 1));
        adapter.send{value: FEE + 1}(p, MessagingFee(FEE, 0), ALICE);
        vm.prank(ALICE);
        vm.expectRevert(EndpointV2Mock.InsufficientFee.selector);
        adapter.send{value: FEE - 1}(p, MessagingFee(FEE - 1, 0), ALICE);
        _assertNoSend();
        assertEq(token.allowance(ALICE, address(adapter)), p.amountLD);
    }

    function testEndpointRefundGoesToRequestedAddress() public {
        SendParam memory p = _params(1 ether);
        _approve(p.amountLD);
        uint256 beforeBalance = BOB.balance;
        vm.prank(ALICE);
        adapter.send{value: FEE + 123}(p, MessagingFee(FEE + 123, 0), BOB);
        assertEq(BOB.balance, beforeBalance + 123);
        assertEq(ENDPOINT.balance, FEE);
        assertEq(address(adapter).balance, 0);
    }

    function testEndpointSendFailureRollsBackTokenAndETH() public {
        endpoint.setFailures(false, true, false);
        SendParam memory p = _params(1 ether);
        _approve(p.amountLD);
        uint256 beforeBalance = ALICE.balance;
        vm.prank(ALICE);
        vm.expectRevert(EndpointV2Mock.SendRejected.selector);
        adapter.send{value: FEE}(p, MessagingFee(FEE, 0), ALICE);
        _assertNoSend();
        assertEq(ALICE.balance, beforeBalance);
        assertEq(token.allowance(ALICE, address(adapter)), p.amountLD);
    }

    function testLzTokenPaymentRequiresAvailabilityAndApproval() public {
        SendParam memory p = _params(1 ether);
        _approve(p.amountLD);
        vm.prank(ALICE);
        vm.expectRevert(OAppSender.LzTokenUnavailable.selector);
        adapter.send{value: FEE}(p, MessagingFee(FEE, 5 ether), ALICE);
        MockZTO feeToken = new MockZTO();
        feeToken.mint(ALICE, 5 ether);
        endpoint.setFees(FEE, 5 ether, address(feeToken));
        MessagingFee memory fee = adapter.quoteSend(p, true);
        assertEq(fee.lzTokenFee, 5 ether);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(adapter), 0, 5 ether)
        );
        adapter.send{value: FEE}(p, fee, ALICE);
        _assertNoSend();
        vm.startPrank(ALICE);
        feeToken.approve(address(adapter), 5 ether);
        adapter.send{value: FEE}(p, fee, ALICE);
        vm.stopPrank();
        assertEq(feeToken.balanceOf(ENDPOINT), 5 ether);
        assertEq(feeToken.balanceOf(address(adapter)), 0);
        assertEq(token.balanceOf(address(adapter)), 1 ether);
        assertTrue(endpoint.lastPayInLzToken());
    }

    function testReceiveReleasesCustodyAndEmitsReceipt() public {
        _send(_params(5 ether));
        bytes32 guid = bytes32(uint256(1));
        Origin memory origin = _origin(1);
        bytes memory message = _message(BOB, 3e6);
        endpoint.queue(origin, address(adapter), guid, message);
        vm.expectEmit(true, true, false, true, address(adapter));
        emit IOFT.OFTReceived(guid, ROBINHOOD, BOB, 3 ether);
        endpoint.deliver(origin, address(adapter), guid, message);
        assertEq(token.balanceOf(BOB), 3 ether);
        assertEq(token.balanceOf(address(adapter)), 2 ether);
        assertEq(token.totalSupply(), INITIAL_BALANCE);
    }

    function testReceiveRejectsNonEndpointWrongPeerAndWrongSource() public {
        _send(_params(5 ether));
        bytes memory message = _message(BOB, 1e6);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(OAppReceiver.OnlyEndpoint.selector, OWNER));
        adapter.lzReceive(_origin(1), bytes32(0), message, address(0), "");
        Origin memory wrongPeer = Origin(ROBINHOOD, _addressBytes(ALICE), 1);
        vm.prank(ENDPOINT);
        vm.expectRevert(abi.encodeWithSelector(IOAppCore.OnlyPeer.selector, ROBINHOOD, wrongPeer.sender));
        adapter.lzReceive(wrongPeer, bytes32(0), message, address(0), "");
        vm.prank(ENDPOINT);
        vm.expectRevert(abi.encodeWithSelector(IOAppCore.NoPeer.selector, HOME));
        adapter.lzReceive(Origin(HOME, peer, 1), bytes32(0), message, address(0), "");
        assertEq(token.balanceOf(address(adapter)), 5 ether);
        assertEq(token.balanceOf(BOB), 0);
    }

    function testRejectedReceiveIsRetryableAndEndpointPreventsReplay() public {
        Origin memory origin = _origin(1);
        bytes32 guid = bytes32(uint256(1));
        bytes memory message = _message(BOB, 5e6);
        endpoint.queue(origin, address(adapter), guid, message);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(adapter), 0, 5 ether)
        );
        endpoint.deliver(origin, address(adapter), guid, message);
        assertFalse(endpoint.delivered(endpoint.packetKey(origin, address(adapter))));
        _send(_params(5 ether));
        endpoint.deliver(origin, address(adapter), guid, message);
        vm.expectRevert(EndpointV2Mock.AlreadyDelivered.selector);
        endpoint.deliver(origin, address(adapter), guid, message);
        assertEq(token.balanceOf(BOB), 5 ether);
        assertEq(token.balanceOf(address(adapter)), 0);
    }

    function testUnverifiedOrAlteredPacketCannotReleaseCustody() public {
        _send(_params(5 ether));
        Origin memory origin = _origin(1);
        bytes32 guid = bytes32(uint256(1));
        bytes memory message = _message(BOB, 1e6);
        vm.expectRevert(EndpointV2Mock.NotVerified.selector);
        endpoint.deliver(origin, address(adapter), guid, message);
        endpoint.queue(origin, address(adapter), guid, message);
        vm.expectRevert(EndpointV2Mock.NotVerified.selector);
        endpoint.deliver(origin, address(adapter), guid, _message(BOB, 5e6));
        assertEq(token.balanceOf(address(adapter)), 5 ether);
    }

    function testMalformedReceiveAndZeroRecipientDoNotReleaseCustody() public {
        _send(_params(5 ether));
        vm.prank(ENDPOINT);
        vm.expectRevert();
        adapter.lzReceive(_origin(1), bytes32(0), hex"00", address(0), "");
        vm.prank(ENDPOINT);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        adapter.lzReceive(_origin(1), bytes32(0), _message(address(0), 1e6), address(0), "");
        assertEq(token.balanceOf(address(adapter)), 5 ether);
    }

    function testFalseReturningTokenCannotLockOrRelease() public {
        SendParam memory p = _params(5 ether);
        _approve(p.amountLD);
        token.setTransferMode(1);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, TOKEN));
        adapter.send{value: FEE}(p, MessagingFee(FEE, 0), ALICE);
        _assertNoSend();
        token.setTransferMode(0);
        _send(p);
        token.setTransferMode(1);
        vm.prank(ENDPOINT);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, TOKEN));
        adapter.lzReceive(_origin(1), bytes32(0), _message(BOB, 5e6), address(0), "");
        assertEq(token.balanceOf(address(adapter)), 5 ether);
        assertEq(token.balanceOf(BOB), 0);
    }

    function testNoReturnTokenIsSupported() public {
        token.setTransferMode(2);
        _send(_params(5 ether));
        _receive(BOB, 5e6, 1);
        assertEq(token.balanceOf(BOB), 5 ether);
        assertEq(token.balanceOf(address(adapter)), 0);
    }

    function testTokenRevertOnReceiveRollsBackAndCanRetry() public {
        _send(_params(5 ether));
        Origin memory origin = _origin(1);
        bytes memory message = _message(BOB, 5e6);
        endpoint.queue(origin, address(adapter), bytes32(0), message);
        token.setTransferMode(3);
        vm.expectRevert(MockZTO.TransferRejected.selector);
        endpoint.deliver(origin, address(adapter), bytes32(0), message);
        assertEq(token.balanceOf(address(adapter)), 5 ether);
        token.setTransferMode(0);
        endpoint.deliver(origin, address(adapter), bytes32(0), message);
        assertEq(token.balanceOf(BOB), 5 ether);
    }

    function testTokenCallbackCannotForgeReceiveOrEnterSimulation() public {
        bytes memory message = _message(BOB, 5e6);
        token.setCallback(
            address(adapter),
            abi.encodeCall(adapter.lzReceive, (_origin(1), bytes32(0), message, address(0), bytes("")))
        );
        _send(_params(5 ether));
        assertFalse(token.callbackSucceeded());
        assertEq(token.callbackResult(), abi.encodeWithSelector(OAppReceiver.OnlyEndpoint.selector, TOKEN));
        assertEq(token.balanceOf(address(adapter)), 5 ether);
        token.setCallback(
            address(adapter),
            abi.encodeCall(adapter.lzReceiveSimulate, (_origin(1), bytes32(0), message, address(0), bytes("")))
        );
        _receive(BOB, 5e6, 1);
        assertFalse(token.callbackSucceeded());
        assertEq(token.callbackResult(), abi.encodeWithSelector(IOAppPreCrimeSimulator.OnlySelf.selector));
        assertEq(token.balanceOf(BOB), 5 ether);
    }

    function testSimulationAlwaysRevertsAllCustodyChanges() public {
        _send(_params(5 ether));
        InboundPacket[] memory packets = new InboundPacket[](1);
        packets[0] = InboundPacket({
            origin: _origin(1),
            dstEid: HOME,
            receiver: address(adapter),
            guid: bytes32(0),
            value: 0,
            executor: address(0),
            message: _message(BOB, 5e6),
            extraData: ""
        });
        vm.expectRevert(abi.encodeWithSelector(IOAppPreCrimeSimulator.SimulationResult.selector, bytes("simulated")));
        adapter.lzReceiveAndRevert(packets);
        assertEq(token.balanceOf(address(adapter)), 5 ether);
        assertEq(token.balanceOf(BOB), 0);
    }

    function buildSimulationResult() external view returns (bytes memory) {
        require(msg.sender == address(adapter), "unexpected caller");
        assertEq(token.balanceOf(BOB), 5 ether);
        return bytes("simulated");
    }

    function testEnforcedOptionsAndComposeSenderEncoding() public {
        EnforcedOptionParam[] memory options = new EnforcedOptionParam[](2);
        options[0] = EnforcedOptionParam(ROBINHOOD, 1, _receiveOptions(100_000));
        options[1] = EnforcedOptionParam(ROBINHOOD, 2, _receiveOptions(300_000));
        vm.prank(OWNER);
        adapter.setEnforcedOptions(options);
        SendParam memory p = _params(5 ether);
        p.extraOptions = _receiveOptions(50_000);
        _send(p);
        assertEq(
            endpoint.lastOptions(),
            abi.encodePacked(options[0].options, uint8(1), uint16(17), uint8(1), uint128(50_000))
        );
        p.composeMsg = hex"112233";
        _send(p);
        assertEq(
            endpoint.lastMessage(), abi.encodePacked(_addressBytes(BOB), uint64(5e6), _addressBytes(ALICE), hex"112233")
        );
        assertEq(
            endpoint.lastOptions(),
            abi.encodePacked(options[1].options, uint8(1), uint16(17), uint8(1), uint128(50_000))
        );
    }

    function testInvalidOptionsRevertAndAdminHooksRequireOwner() public {
        EnforcedOptionParam[] memory options = new EnforcedOptionParam[](1);
        options[0] = EnforcedOptionParam(ROBINHOOD, 1, hex"0001");
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(IOAppOptionsType3.InvalidOptions.selector, hex"0001"));
        adapter.setEnforcedOptions(options);
        options[0].options = _receiveOptions(100_000);
        bytes memory unauthorized = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE);
        vm.startPrank(ALICE);
        vm.expectRevert(unauthorized);
        adapter.setEnforcedOptions(options);
        vm.expectRevert(unauthorized);
        adapter.setMsgInspector(ALICE);
        vm.expectRevert(unauthorized);
        adapter.setPreCrime(ALICE);
        vm.stopPrank();
        vm.prank(OWNER);
        adapter.setEnforcedOptions(options);
        SendParam memory p = _params(1 ether);
        p.extraOptions = hex"0001";
        _approve(p.amountLD);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IOAppOptionsType3.InvalidOptions.selector, hex"0001"));
        adapter.send{value: FEE}(p, MessagingFee(FEE, 0), ALICE);
        _assertNoSend();
    }

    function testInspectorRejectionAppliesToQuoteAndSend() public {
        RejectingInspector inspector = new RejectingInspector();
        vm.prank(OWNER);
        adapter.setMsgInspector(address(inspector));
        SendParam memory p = _params(1 ether);
        vm.expectRevert(RejectingInspector.InspectionRejected.selector);
        adapter.quoteSend(p, false);
        _approve(p.amountLD);
        vm.prank(ALICE);
        vm.expectRevert(RejectingInspector.InspectionRejected.selector);
        adapter.send{value: FEE}(p, MessagingFee(FEE, 0), ALICE);
        _assertNoSend();
    }

    function testComposeReceiveUsesLocalAmountAndRollsBackIfQueueFails() public {
        _send(_params(5 ether));
        bytes memory message = abi.encodePacked(_message(BOB, 5e6), _addressBytes(ALICE), hex"aabb");
        Origin memory origin = _origin(7);
        bytes32 guid = bytes32(uint256(123));
        endpoint.queue(origin, address(adapter), guid, message);
        endpoint.setFailures(false, false, true);
        vm.expectRevert(EndpointV2Mock.ComposeRejected.selector);
        endpoint.deliver(origin, address(adapter), guid, message);
        assertEq(token.balanceOf(address(adapter)), 5 ether);
        assertEq(token.balanceOf(BOB), 0);
        endpoint.setFailures(false, false, false);
        endpoint.deliver(origin, address(adapter), guid, message);
        assertEq(token.balanceOf(BOB), 5 ether);
        assertEq(endpoint.composedFrom(), address(adapter));
        assertEq(endpoint.composedTo(), BOB);
        assertEq(endpoint.composedGuid(), guid);
        assertEq(endpoint.composedIndex(), 0);
        assertEq(
            endpoint.composedMessage(),
            abi.encodePacked(uint64(7), ROBINHOOD, uint256(5 ether), _addressBytes(ALICE), hex"aabb")
        );
    }

    function testFuzzRoundTripConservesSupplyAndLeavesDust(uint64 amountSD, uint256 rawDust) public {
        uint256 dust = rawDust % RATE;
        uint256 amount = uint256(amountSD) * RATE;
        token.mint(ALICE, amount + dust);
        uint256 beforeBalance = token.balanceOf(ALICE);
        uint256 supply = token.totalSupply();
        _send(_params(amount + dust));
        assertEq(token.balanceOf(ALICE), beforeBalance - amount);
        assertEq(token.balanceOf(address(adapter)), amount);
        assertEq(remote.totalSupply(), 0);
        // Relay the exact outbound wire payload into an actual upstream OFT implementation.
        Origin memory outboundOrigin = Origin(HOME, _addressBytes(address(adapter)), endpoint.lastNonce());
        remoteEndpoint.queue(outboundOrigin, address(remote), endpoint.lastGuid(), endpoint.lastMessage());
        remoteEndpoint.deliver(outboundOrigin, address(remote), endpoint.lastGuid(), endpoint.lastMessage());
        assertEq(remote.balanceOf(BOB), amount);
        assertEq(remote.totalSupply(), token.balanceOf(address(adapter)));
        assertEq(token.balanceOf(ALICE) + remote.totalSupply(), supply);
        SendParam memory returning = SendParam(HOME, _addressBytes(ALICE), amount, amount, "", "", "");
        vm.prank(BOB);
        remote.send{value: FEE}(returning, MessagingFee(FEE, 0), BOB);
        assertEq(remote.totalSupply(), 0);
        Origin memory returningOrigin = _origin(remoteEndpoint.lastNonce());
        endpoint.queue(returningOrigin, address(adapter), remoteEndpoint.lastGuid(), remoteEndpoint.lastMessage());
        endpoint.deliver(returningOrigin, address(adapter), remoteEndpoint.lastGuid(), remoteEndpoint.lastMessage());
        assertEq(token.balanceOf(ALICE), beforeBalance);
        assertEq(token.balanceOf(address(adapter)), 0);
        assertEq(token.totalSupply(), supply);
    }

    function _params(uint256 amount) internal pure returns (SendParam memory) {
        return SendParam(ROBINHOOD, _addressBytes(BOB), amount, amount / RATE * RATE, "", "", "");
    }

    function _approve(uint256 amount) internal {
        vm.prank(ALICE);
        token.approve(address(adapter), amount);
    }

    function _send(SendParam memory p) internal returns (MessagingReceipt memory, OFTReceipt memory) {
        _approve(p.amountLD);
        vm.prank(ALICE);
        return adapter.send{value: FEE}(p, MessagingFee(FEE, 0), ALICE);
    }

    function _receive(address to, uint64 amountSD, uint64 nonce) internal {
        Origin memory origin = _origin(nonce);
        bytes32 guid = bytes32(uint256(nonce));
        bytes memory message = _message(to, amountSD);
        endpoint.queue(origin, address(adapter), guid, message);
        endpoint.deliver(origin, address(adapter), guid, message);
    }

    function _origin(uint64 nonce) internal view returns (Origin memory) {
        return Origin(ROBINHOOD, peer, nonce);
    }

    function _message(address to, uint64 amountSD) internal pure returns (bytes memory) {
        return abi.encodePacked(_addressBytes(to), amountSD);
    }

    function _addressBytes(address account) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }

    function _receiveOptions(uint128 gasLimit) internal pure returns (bytes memory) {
        return abi.encodePacked(uint16(3), uint8(1), uint16(17), uint8(1), gasLimit);
    }

    function _assertNoSend() internal view {
        assertEq(token.balanceOf(ALICE), INITIAL_BALANCE);
        assertEq(token.balanceOf(address(adapter)), 0);
        assertEq(endpoint.lastNonce(), 0);
        assertEq(ENDPOINT.balance, 0);
    }
}
