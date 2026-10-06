// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ZTOAdapter} from "../src/ZTOAdapter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EndpointV2Mock} from "./mocks/EndpointV2Mock.sol";
import {MockZTO} from "./mocks/MockZTO.sol";

contract DeploymentFactoryMock {
    function deploy(bytes32 salt) external returns (ZTOAdapter) {
        return new ZTOAdapter{salt: salt}();
    }
}

contract ZTOAdapterDeploymentTest is Test {
    address private constant OWNER = 0xcECc29B037f5064fCdF45a5C318F132ef76aA551;
    address private constant ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    address private constant TOKEN = 0xd782Bdea4EF02a0Bd391eb9089470c8080f0A68e;

    function testConstructorWithNeitherDependencyDeployed() public {
        assertEq(ENDPOINT.code.length, 0);
        assertEq(TOKEN.code.length, 0);
        ZTOAdapter adapter = new ZTOAdapter();
        assertEq(adapter.owner(), OWNER);
        assertEq(adapter.token(), TOKEN);
        assertEq(address(adapter.endpoint()), ENDPOINT);
        assertEq(adapter.LOCAL_DECIMALS(), 18);
        assertEq(adapter.sharedDecimals(), 6);
        assertEq(adapter.decimalConversionRate(), 1e12);
        assertEq(adapter.HOME_EID(), 30101);
        assertEq(adapter.ROBINHOOD_EID(), 30416);
        assertEq(adapter.peers(30416), bytes32(0));
        assertTrue(adapter.approvalRequired());
    }

    function testConstructorRegistersDelegateWithEndpointCodeAndNoTokenCode() public {
        EndpointV2Mock endpoint = _installEndpoint();
        assertEq(TOKEN.code.length, 0);
        ZTOAdapter adapter = new ZTOAdapter();
        assertEq(endpoint.delegates(address(adapter)), OWNER);
        assertEq(endpoint.delegateCalls(), 1);
    }

    function testConstructorNeverReadsTokenMetadataEvenWhenCodeExists() public {
        MockZTO token = new MockZTO();
        vm.etch(TOKEN, address(token).code);
        vm.expectRevert(MockZTO.MetadataMustNotBeRead.selector);
        MockZTO(TOKEN).decimals();
        ZTOAdapter withoutEndpoint = new ZTOAdapter();
        assertEq(withoutEndpoint.decimalConversionRate(), 1e12);
        EndpointV2Mock endpoint = _installEndpoint();
        ZTOAdapter withEndpoint = new ZTOAdapter();
        assertEq(endpoint.delegates(address(withEndpoint)), OWNER);
        assertEq(withEndpoint.decimalConversionRate(), 1e12);
    }

    function testDeferredDelegateRegistrationIsOwnerOnly() public {
        ZTOAdapter adapter = new ZTOAdapter();
        EndpointV2Mock endpoint = _installEndpoint();
        assertEq(endpoint.delegates(address(adapter)), address(0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        adapter.setDelegate(OWNER);
        vm.prank(OWNER);
        adapter.setDelegate(OWNER);
        assertEq(endpoint.delegates(address(adapter)), OWNER);
        assertEq(endpoint.delegateCalls(), 1);
    }

    function testConstructorPropagatesFailureWhenEndpointHasCode() public {
        EndpointV2Mock endpoint = _installEndpoint();
        endpoint.setFailures(true, false, false);
        vm.expectRevert(EndpointV2Mock.DelegateRejected.selector);
        new ZTOAdapter();
    }

    function testExplicitSetDelegateDoesNotSilentlySucceedWithoutCode() public {
        ZTOAdapter adapter = new ZTOAdapter();
        vm.prank(OWNER);
        vm.expectRevert();
        adapter.setDelegate(OWNER);
    }

    function testFactoryCreate2DeploymentAndRuntimeConstraints() public {
        DeploymentFactoryMock factory = new DeploymentFactoryMock();
        bytes32 salt = keccak256("ZTO rehearsal");
        bytes memory initCode = type(ZTOAdapter).creationCode;
        address predicted = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), salt, keccak256(initCode)))))
        );
        ZTOAdapter adapter = factory.deploy(salt);
        assertEq(address(adapter), predicted);
        assertEq(adapter.owner(), OWNER);
        assertLe(initCode.length, 49_152);
        bytes memory code = address(adapter).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 opcode = uint8(code[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
                continue;
            }
            assertTrue(opcode != 0xf4 && opcode != 0xf2 && opcode != 0xff, "forbidden runtime opcode");
        }
    }

    function _installEndpoint() private returns (EndpointV2Mock) {
        EndpointV2Mock implementation = new EndpointV2Mock(30101);
        vm.etch(ENDPOINT, address(implementation).code);
        return EndpointV2Mock(ENDPOINT);
    }
}
