// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {BaseTest} from "../Base.t.sol";
import {Vm} from "forge-std/Test.sol";
import {PackedUserOperation, UserOperationLib} from "account-abstraction/core/UserOperationLib.sol";
import {MockTarget} from "../mock/MockTarget.sol";
import {MockAccount} from "../mock/MockAccount.sol";
import {IEntryPointSimulations} from "account-abstraction/interfaces/IEntryPointSimulations.sol";
import {EntryPointSimulations} from "account-abstraction/core/EntryPointSimulations.sol";
import {NodePaymaster} from "contracts/NodePaymaster.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {MEEUserOpLib} from "contracts/lib/util/MEEUserOpLib.sol";
import {MockERC20PermitToken} from "../mock/MockERC20PermitToken.sol";
import {IERC20Permit} from "openzeppelin/token/ERC20/extensions/IERC20Permit.sol";
import {Strings} from "openzeppelin/utils/Strings.sol";
import "forge-std/console2.sol";

interface IGetOwner {
    function getOwner(address account) external view returns (address);
}

contract K1MEEValidatorTest is BaseTest {

    using UserOperationLib for PackedUserOperation;
    using MEEUserOpLib for PackedUserOperation;
    using Strings for address;
    using Strings for uint256;
    Vm.Wallet wallet;
    MockAccount mockAccount;
    uint256 constant PREMIUM_CALCULATION_BASE = 100e5;
    uint256 valueToSet;

    function setUp() public virtual override {
        super.setUp();
        wallet = createAndFundWallet("wallet", 5 ether);
        mockAccount = deployMockAccount({
            validator: address(k1MeeValidator)
        });
        vm.prank(address(mockAccount));
        k1MeeValidator.transferOwnership(wallet.addr);
        valueToSet = MEE_NODE_HEX;
    }

    function test_regular_userOp_flow_success() public returns (PackedUserOperation[] memory) {
        bytes memory innerCallData = abi.encodeWithSelector(MockTarget.setValue.selector, valueToSet);
        bytes memory callData = abi.encodeWithSelector(mockAccount.execute.selector, address(mockTarget), uint256(0), innerCallData);
        PackedUserOperation memory userOp = buildUserOpWithCalldata(
            {
                account: address(mockAccount), 
                callData: callData, 
                wallet: wallet, 
                preVerificationGasLimit: 3e5, 
                verificationGasLimit: 500e3, 
                callGasLimit: 3e6
            }
        );

        userOp = makeMEEUserOp({
            userOp: userOp, 
            pmValidationGasLimit: 22_000, 
            pmPostOpGasLimit: 45_000, 
            premiumPercentage: 17_00000, 
            wallet: wallet, 
            sigType: bytes4(0)
        });

        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);     
        userOps[0] = userOp;

        vm.startPrank(MEE_NODE_ADDRESS, MEE_NODE_ADDRESS);
        vm.recordLogs();
        MEE_ENTRYPOINT.handleOps(userOps, payable(MEE_NODE_ADDRESS));
        vm.stopPrank();

        assertEq(mockTarget.value(), valueToSet); 

        return (userOps);
    }

    function test_superTxFlow_simple_mode_ValidateUserOp_success() public returns (PackedUserOperation[] memory) {
        uint256 counterBefore = mockTarget.counter();
        bytes memory innerCallData = abi.encodeWithSelector(MockTarget.incrementCounter.selector);
        PackedUserOperation memory userOp = buildSimpleMEEUserOpWithCalldata({
            callData: abi.encodeWithSelector(mockAccount.execute.selector, address(mockTarget), uint256(0), innerCallData),
            account: address(mockAccount),
            userOpSigner: wallet
        });

        uint256 numOfClones = 3;
        PackedUserOperation[] memory userOps = cloneUserOpToAnArray(userOp, wallet, numOfClones);

        userOps = makeSimpleSuperTx(userOps, wallet);

        vm.startPrank(MEE_NODE_ADDRESS, MEE_NODE_ADDRESS);
        vm.recordLogs();
        MEE_ENTRYPOINT.handleOps(userOps, payable(MEE_NODE_ADDRESS));
        vm.stopPrank();
        
        assertEq(mockTarget.counter(), counterBefore + numOfClones + 1);
        return userOps;
    }

    function test_superTxFlow_simple_mode_1271_and_WithData_success() public {
        uint256 numOfObjs = 2;
        bytes[] memory meeSigs = new bytes[](numOfObjs);
        bytes32 baseHash = keccak256(abi.encode("test"));
        meeSigs = makeSimpleSuperTxSignatures({
            baseHash: baseHash,
            total: numOfObjs,
            superTxSigner: wallet
        });

        for(uint256 i=0; i<numOfObjs; i++) {
            bytes32 signedHash = keccak256(abi.encode(baseHash, i));
            assertTrue(mockAccount.isValidSignature_test(signedHash, meeSigs[i]));
            assertTrue(mockAccount.validateSignatureWithData(signedHash, meeSigs[i], abi.encodePacked(wallet.addr)));
        }
    }

    function test_superTxFlow_permit_mode_ValidateUserOp_success() public {
        MockERC20PermitToken erc20 = new MockERC20PermitToken("test", "TEST");
        deal(address(erc20), wallet.addr, 1_000 ether); // mint erc20 tokens to the wallet
        address bob = address(0xb0bb0b);
        assertEq(erc20.balanceOf(bob), 0);
        uint256 amountToTransfer = 1 ether;

        // userOps will transfer tokens from wallet, not from mockAccount
        // because of permit applies in the first userop validation
        bytes memory innerCallData = abi.encodeWithSelector(erc20.transferFrom.selector, wallet.addr, bob, amountToTransfer);

        PackedUserOperation memory userOp = buildSimpleMEEUserOpWithCalldata({
            callData: abi.encodeWithSelector(mockAccount.execute.selector, address(erc20), uint256(0), innerCallData),
            account: address(mockAccount),
            userOpSigner: wallet
        });

        uint256 numOfClones = 5;
        PackedUserOperation[] memory userOps = cloneUserOpToAnArray(userOp, wallet, numOfClones);

        userOps = makePermitSuperTx({
            userOps: userOps, 
            token: erc20, 
            signer: wallet, 
            spender: address(mockAccount), 
            amount: amountToTransfer*userOps.length 
        });

        vm.startPrank(MEE_NODE_ADDRESS, MEE_NODE_ADDRESS);
        vm.recordLogs();
        MEE_ENTRYPOINT.handleOps(userOps, payable(MEE_NODE_ADDRESS));
        vm.stopPrank();

        assertEq(erc20.balanceOf(bob), amountToTransfer*numOfClones+1e18);
    }       

    function test_superTxFlow_permit_mode_1271_and_WithData_success() public {
        MockERC20PermitToken erc20 = new MockERC20PermitToken("test", "TEST");
        uint256 numOfObjs = 5;
        bytes[] memory meeSigs = new bytes[](numOfObjs);
        bytes32 baseHash = keccak256(abi.encode("test"));

        meeSigs = makePermitSuperTxSignatures({
            baseHash: baseHash,
            total: numOfObjs,
            token: erc20,
            signer: wallet,
            spender: address(mockAccount),
            amount: 1e18
        });

        for(uint256 i=0; i<numOfObjs; i++) {
            bytes32 signedHash = keccak256(abi.encode(baseHash, i));
            assertTrue(mockAccount.isValidSignature_test(signedHash, meeSigs[i]));
            assertTrue(mockAccount.validateSignatureWithData(signedHash, meeSigs[i], abi.encodePacked(wallet.addr)));
        }
    }

    // test txn mode
    function test_superTxFlow_txn_mode_ValidateUserOp_success() public {
        MockERC20PermitToken erc20 = new MockERC20PermitToken("test", "TEST");
        deal(address(erc20), wallet.addr, 1_000 ether); // mint erc20 tokens to the wallet
        address bob = address(0xb0bb0b);
        assertEq(erc20.balanceOf(bob), 0);
        assertEq(erc20.balanceOf(address(mockAccount)), 0);
        uint256 amountToTransfer = 1 ether; // 1 token

        bytes memory innerCallData = abi.encodeWithSelector(erc20.transfer.selector, bob, amountToTransfer); // mock Account transfers tokens to bob
        PackedUserOperation memory userOp = buildSimpleMEEUserOpWithCalldata({
            callData: abi.encodeWithSelector(mockAccount.execute.selector, address(erc20), uint256(0), innerCallData),
            account: address(mockAccount),
            userOpSigner: wallet
        });

        uint256 numOfClones = 5;
        PackedUserOperation[] memory userOps = cloneUserOpToAnArray(userOp, wallet, numOfClones);
        
        bytes memory asd = abi.encodeWithSelector(erc20.transfer.selector, address(mockAccount), amountToTransfer*(numOfClones+1));
        //console2.logBytes(asd);
        vm.startPrank(wallet.addr);
        erc20.transfer(address(mockAccount), amountToTransfer*(numOfClones+1));
        vm.stopPrank();

        bytes memory serializedTx = hex"02f8d1827a6980843b9aca00848321560082c3509470997970c51812dc3a010c7d01b50e0d17dc79c880b864a9059cbb000000000000000000000000c7183455a4c133ae270771860664b6b7ec320bb100000000000000000000000000000000000000000000000053444835ec5800001d69c064e2bd749cfe331b748be1dd5324cbf4e1839dda346cbb741a3e3169d1c001a00d20bce300797773daa18e485e5babb3cc42364c6d69d7d048b757d96d0ea4e6a04adf97b9e62d2f57a993bc6c69a81a0a41594aacfd3797d3e0144c494a64c0cb";
        userOps = makeOnChainTxnSuperTx(
            userOps,
            wallet,
            serializedTx
        );

        vm.startPrank(MEE_NODE_ADDRESS, MEE_NODE_ADDRESS);
        vm.recordLogs();
        MEE_ENTRYPOINT.handleOps(userOps, payable(MEE_NODE_ADDRESS));
        vm.stopPrank();

        assertEq(erc20.balanceOf(bob), amountToTransfer*(numOfClones+1));
    }

    // make mixed mode : one userOp from different trees (permit, simple, txn) - one handleOps call

    // ================================

    function buildSimpleMEEUserOpWithCalldata(bytes memory callData, address account, Vm.Wallet memory userOpSigner) public returns (PackedUserOperation memory) {
        PackedUserOperation memory userOp = buildUserOpWithCalldata({
            account: account, 
            callData: callData, 
            wallet: userOpSigner, 
            preVerificationGasLimit: 3e5, 
            verificationGasLimit: 500e3, 
            callGasLimit: 3e6
        });

        userOp = makeMEEUserOp({
            userOp: userOp, 
            pmValidationGasLimit: 22_000, 
            pmPostOpGasLimit: 45_000, 
            premiumPercentage: 17_00000, 
            wallet: userOpSigner, 
            sigType: bytes4(0)
        });

        return userOp;
    }

    function iToHex(bytes memory buffer) public pure returns (string memory) {

        // Fixed buffer size for hexadecimal convertion
        bytes memory converted = new bytes(buffer.length * 2);

        bytes memory _base = "0123456789abcdef";

        for (uint256 i = 0; i < buffer.length; i++) {
            converted[i * 2] = _base[uint8(buffer[i]) / _base.length];
            converted[i * 2 + 1] = _base[uint8(buffer[i]) % _base.length];
        }

        return string(abi.encodePacked("0x", converted));
    }
}
