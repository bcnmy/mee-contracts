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
import "forge-std/console2.sol";

interface IGetOwner {
    function getOwner(address account) external view returns (address);
}

contract K1MEEValidatorTest is BaseTest {

    using UserOperationLib for PackedUserOperation;
    using MEEUserOpLib for PackedUserOperation;

    Vm.Wallet wallet;
    MockAccount mockAccount;
    uint256 constant PREMIUM_CALCULATION_BASE = 100e5;
    uint256 valueToSet;

    function setUp() public virtual override {
        super.setUp();
        wallet = createAndFundWallet("wallet", 1 ether);
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
}
