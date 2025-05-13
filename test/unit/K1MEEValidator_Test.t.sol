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
import {MEEUserOpHashLib} from "contracts/lib/util/MEEUserOpHashLib.sol";
import {MockERC20PermitToken} from "../mock/MockERC20PermitToken.sol";
import {IERC20Permit} from "openzeppelin/token/ERC20/extensions/IERC20Permit.sol";
import {Strings} from "openzeppelin/utils/Strings.sol";
import {EIP1271_SUCCESS, EIP1271_FAILED} from "contracts/types/Constants.sol";
import {EIP712} from "solady/utils/EIP712.sol";
import {MockDelegationManager} from "../mock/MockDelegationManager.sol";
interface IGetOwner {
    function getOwner(address account) external view returns (address);
}

contract K1MEEValidatorTest is BaseTest {
    using UserOperationLib for PackedUserOperation;
    using MEEUserOpHashLib for PackedUserOperation;
    using Strings for address;
    using Strings for uint256;

    uint256 constant PREMIUM_CALCULATION_BASE = 100e5;
    bytes32 internal constant APP_DOMAIN_SEPARATOR = 0xa1a044077d7677adbbfa892ded5390979b33993e0e2a457e3f974bbcda53821b;

    Vm.Wallet wallet;
    MockAccount mockAccount;
    uint256 valueToSet;

    function setUp() public virtual override {
        super.setUp();
        wallet = createAndFundWallet("wallet", 5 ether);
        mockAccount = deployMockAccount({validator: address(k1MeeValidator), handler: address(0)});
        vm.prank(address(mockAccount));
        k1MeeValidator.transferOwnership(wallet.addr);
        valueToSet = MEE_NODE_HEX;
    }

    // =================== test simple mode ===================

    function test_superTxFlow_simple_mode_ValidateUserOp_success(uint256 numOfClones)
        public
        returns (PackedUserOperation[] memory)
    {
        numOfClones = bound(numOfClones, 1, 25);
        uint256 counterBefore = mockTarget.counter();
        bytes memory innerCallData = abi.encodeWithSelector(MockTarget.incrementCounter.selector);
        PackedUserOperation memory userOp = buildBasicMEEUserOpWithCalldata({
            callData: abi.encodeWithSelector(mockAccount.execute.selector, address(mockTarget), uint256(0), innerCallData),
            account: address(mockAccount),
            userOpSigner: wallet
        });

        PackedUserOperation[] memory userOps = cloneUserOpToAnArray(userOp, wallet, numOfClones);

        userOps = makeSimpleSuperTx(userOps, wallet);

        vm.startPrank(MEE_NODE_EXECUTOR_EOA, MEE_NODE_EXECUTOR_EOA);
        ENTRYPOINT.handleOps(userOps, payable(MEE_NODE_ADDRESS));
        vm.stopPrank();

        assertEq(mockTarget.counter(), counterBefore + numOfClones + 1);
        return userOps;
    }

    function test_superTxFlow_simple_mode_1271_and_WithData_success(uint256 numOfObjs) public {
        numOfObjs = bound(numOfObjs, 2, 25);
        bytes[] memory meeSigs = new bytes[](numOfObjs);
        bytes32 baseHash = keccak256(abi.encode("test"));
        meeSigs = makeSimpleSuperTxSignatures({
            baseHash: baseHash,
            total: numOfObjs,
            superTxSigner: wallet,
            mockAccount: address(mockAccount)
        });

        for (uint256 i = 0; i < numOfObjs; i++) {
            // pass the 'unsafe hash' here. however, the root is made with the 'safe' one
            // hash will rehashed in the K1MEEValidator.isValidSignatureWithSender by hashing the SA address into it
            bytes32 includedLeafHash = keccak256(abi.encode(baseHash, i));
            if (i / 2 == 0) {
                assertTrue(
                    mockAccount.validateSignatureWithData(includedLeafHash, meeSigs[i], abi.encodePacked(wallet.addr))
                );
            } else {
                assertTrue(mockAccount.isValidSignature(includedLeafHash, meeSigs[i]) == EIP1271_SUCCESS);
            }
        }
    }

    // =================== test permit mode ===================

    function test_superTxFlow_permit_mode_ValidateUserOp_success(uint256 numOfClones) public {
        numOfClones = bound(numOfClones, 1, 25);
        MockERC20PermitToken erc20 = new MockERC20PermitToken("test", "TEST");
        deal(address(erc20), wallet.addr, 1_000 ether); // mint erc20 tokens to the wallet
        address bob = address(0xb0bb0b);
        assertEq(erc20.balanceOf(bob), 0);
        uint256 amountToTransfer = 1 ether;

        // userOps will transfer tokens from wallet, not from mockAccount
        // because of permit applies in the first userop validation
        bytes memory innerCallData =
            abi.encodeWithSelector(erc20.transferFrom.selector, wallet.addr, bob, amountToTransfer);

        PackedUserOperation memory userOp = buildBasicMEEUserOpWithCalldata({
            callData: abi.encodeWithSelector(mockAccount.execute.selector, address(erc20), uint256(0), innerCallData),
            account: address(mockAccount),
            userOpSigner: wallet
        });

        PackedUserOperation[] memory userOps = cloneUserOpToAnArray(userOp, wallet, numOfClones);

        userOps = makePermitSuperTx({
            userOps: userOps,
            token: erc20,
            signer: wallet,
            spender: address(mockAccount),
            amount: amountToTransfer * userOps.length
        });

        vm.startPrank(MEE_NODE_EXECUTOR_EOA, MEE_NODE_EXECUTOR_EOA);
        ENTRYPOINT.handleOps(userOps, payable(MEE_NODE_ADDRESS));
        vm.stopPrank();
        // as the total # of userOps is numOfClones + 1, the balance of bob should be amountToTransfer * (numOfClones + 1)
        assertEq(erc20.balanceOf(bob), amountToTransfer * (numOfClones + 1));
    }

    function test_superTxFlow_permit_mode_1271_and_WithData_success(uint256 numOfObjs) public {
        numOfObjs = bound(numOfObjs, 2, 25);
        MockERC20PermitToken erc20 = new MockERC20PermitToken("test", "TEST");
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

        for (uint256 i = 0; i < numOfObjs; i++) {
            bytes32 includedLeafHash = keccak256(abi.encode(baseHash, i));
            if (i / 2 == 0) {
                assertTrue(
                    mockAccount.validateSignatureWithData(includedLeafHash, meeSigs[i], abi.encodePacked(wallet.addr))
                );
            } else {
                assertTrue(mockAccount.isValidSignature(includedLeafHash, meeSigs[i]) == EIP1271_SUCCESS);
            }
        }
    }

    // =================== test txn mode ===================

    function test_superTxFlow_txn_mode_ValidateUserOp_success(uint256 numOfClones) public {
        numOfClones = bound(numOfClones, 1, 25);
        MockERC20PermitToken erc20 = new MockERC20PermitToken("test", "TEST");
        deal(address(erc20), wallet.addr, 1_000 ether); // mint erc20 tokens to the wallet
        address bob = address(0xb0bb0b);
        assertEq(erc20.balanceOf(bob), 0);
        assertEq(erc20.balanceOf(address(mockAccount)), 0);
        uint256 amountToTransfer = 1 ether; // 1 token

        bytes memory innerCallData = abi.encodeWithSelector(erc20.transfer.selector, bob, amountToTransfer); // mock Account transfers tokens to bob
        PackedUserOperation memory userOp = buildBasicMEEUserOpWithCalldata({
            callData: abi.encodeWithSelector(mockAccount.execute.selector, address(erc20), uint256(0), innerCallData),
            account: address(mockAccount),
            userOpSigner: wallet
        });

        PackedUserOperation[] memory userOps = cloneUserOpToAnArray(userOp, wallet, numOfClones);

        // simulate the txn execution
        vm.startPrank(wallet.addr);
        erc20.transfer(address(mockAccount), amountToTransfer * (numOfClones + 1));
        vm.stopPrank();

        // it is not possible to get the actual executed and serialized txn (above) from Foundry tests
        // so this is just some calldata for testing purposes
        bytes memory callData = hex"a9059cbb000000000000000000000000c7183455a4c133ae270771860664b6b7ec320bb100000000000000000000000000000000000000000000000053444835ec580000";

        userOps = makeOnChainTxnSuperTx(
            userOps,
            wallet,
            callData
        );

        vm.startPrank(MEE_NODE_EXECUTOR_EOA, MEE_NODE_EXECUTOR_EOA);
        ENTRYPOINT.handleOps(userOps, payable(MEE_NODE_ADDRESS));
        vm.stopPrank();

        assertEq(erc20.balanceOf(bob), amountToTransfer * (numOfClones + 1));
    }

    function test_superTxFlow_txn_mode_1271_and_WithData_success() public {
        uint256 numOfObjs = 5;
        bytes[] memory meeSigs = new bytes[](numOfObjs);
        bytes32 baseHash = keccak256(abi.encode("test"));

        bytes memory callData = abi.encodeWithSelector(MockTarget.incrementCounter.selector);

        meeSigs = makeOnChainTxnSuperTxSignatures(baseHash, numOfObjs, callData, address(mockAccount), wallet);

        for (uint256 i = 0; i < numOfObjs; i++) {
            bytes32 includedLeafHash = keccak256(abi.encode(baseHash, i));
            if (i / 2 == 0) {
                assertTrue(
                    mockAccount.validateSignatureWithData(includedLeafHash, meeSigs[i], abi.encodePacked(wallet.addr))
                );
            } else {
                assertTrue(mockAccount.isValidSignature(includedLeafHash, meeSigs[i]) == EIP1271_SUCCESS);
            }
        }
    }

    // =================== test MM DTK flow ===================

    // The full flow in the wild is:
    // - deploy the MM DelegationManager
    // - deploy the gator account for the eoa
    // - grant permission to the MEE node to transfer tokens from the gator to the mockAccount
    // - MEE Node redeems the permission, tokens are sent to the mockAccount
    // We skip the steps above in the test and we assume that the permission is already granted and redeemed

    // - superTxn is executed, mockAccount transfers tokens to bob as a result of several userOps which are part of the superTxn

    function test_superTxFlow_mm_dtk_ValidateUserOp_success(uint256 numOfClones) public {
        numOfClones = bound(numOfClones, 1, 25); 
         
        MockERC20PermitToken erc20 = new MockERC20PermitToken("test", "TEST");
        MockDelegationManager delegationManager = new MockDelegationManager();
        uint256 amountToTransfer = 1 ether;
        // fund the mockAccount with enough tokens, emulating those tokens being transferred from the gator account
        deal(address(erc20), address(mockAccount), amountToTransfer * (numOfClones + 1));

        address bob = address(0xb0bb0b);
        assertEq(erc20.balanceOf(bob), 0);

        // delegation calldata
        // it allows transfering tokens from the gator account to the mockAccount
        // this is what we could have used in the wild to request the permission
        bytes memory delegationInnerCalldata = abi.encodeWithSelector(
            erc20.transfer.selector, 
            address(mockAccount), 
            amountToTransfer * (numOfClones + 1)
        );

        // mock Account transfers tokens to bob - this is the calldata to be used in the userOps of 
        // the superTxn
        bytes memory innerCallData = abi.encodeWithSelector(erc20.transfer.selector, bob, amountToTransfer);

        PackedUserOperation memory userOp = buildBasicMEEUserOpWithCalldata({
            callData: abi.encodeWithSelector(mockAccount.execute.selector, address(erc20), uint256(0), innerCallData),
            account: address(mockAccount),
            userOpSigner: wallet
        });

        PackedUserOperation[] memory userOps = cloneUserOpToAnArray(userOp, wallet, numOfClones);
 
        userOps = makeDTKSuperTx({
            userOps: userOps,
            signer: wallet,
            executionTo: address(erc20),
            executionCalldata: delegationInnerCalldata,
            delegationManager: delegationManager
        });

        vm.startPrank(MEE_NODE_EXECUTOR_EOA, MEE_NODE_EXECUTOR_EOA);
        ENTRYPOINT.handleOps(userOps, payable(MEE_NODE_ADDRESS));
        vm.stopPrank();

        assertEq(erc20.balanceOf(bob), amountToTransfer * (numOfClones + 1));
    }

    // =================== test non-MEE flow ===================

    function test_nonMEEFlow_ValidateUserOp_success() public {
        uint256 counterBefore = mockTarget.counter();
        bytes memory innerCallData = abi.encodeWithSelector(MockTarget.incrementCounter.selector);

        vm.deal(address(mockAccount), 100 ether);
        
        PackedUserOperation memory userOp = buildUserOpWithCalldata({
            account: address(mockAccount), 
            callData: abi.encodeWithSelector(mockAccount.execute.selector, address(mockTarget), uint256(0), innerCallData),
            wallet: wallet, 
            preVerificationGasLimit: 3e5, 
            verificationGasLimit: 500e3, 
            callGasLimit: 3e6
        });

        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        userOps[0] = userOp;

        vm.startPrank(MEE_NODE_EXECUTOR_EOA);
        ENTRYPOINT.handleOps(userOps, payable(MEE_NODE_ADDRESS));
        vm.stopPrank();

        assertEq(mockTarget.counter(), counterBefore + 1);
    }

    function test_nonMEEFlow_validateSignatureWithData_success() public {
        bytes memory innerCallData = abi.encodeWithSelector(MockTarget.incrementCounter.selector);
        PackedUserOperation memory userOp = buildBasicMEEUserOpWithCalldata({
            callData: abi.encodeWithSelector(mockAccount.execute.selector, address(mockTarget), uint256(0), innerCallData),
            account: address(mockAccount),
            userOpSigner: wallet
        });
        bytes32 userOpHash = ENTRYPOINT.getUserOpHash(userOp);
        assertTrue(mockAccount.validateSignatureWithData(userOpHash, userOp.signature, abi.encodePacked(wallet.addr)));
    }

    function test_nonMEEFlow_isValidSignature_7739_success() public {
        TestTemps memory t;
        t.contents = keccak256("0x1234");
        bytes32 dataToSign = toERC1271Hash(t.contents, address(mockAccount));
        (t.v, t.r, t.s) = vm.sign(wallet.privateKey, dataToSign);
        bytes memory contentsType = "Contents(bytes32 stuff)";
        bytes memory signature =
            abi.encodePacked(t.r, t.s, t.v, APP_DOMAIN_SEPARATOR, t.contents, contentsType, uint16(contentsType.length));
        bytes4 ret = mockAccount.isValidSignature(toContentsHash(t.contents), signature);
        assertEq(ret, bytes4(EIP1271_SUCCESS));
    }

    // ================================

    function buildBasicMEEUserOpWithCalldata(bytes memory callData, address account, Vm.Wallet memory userOpSigner)
        public
        returns (PackedUserOperation memory)
    {
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
            pmValidationGasLimit: 40_000, 
            pmPostOpGasLimit: 50_000, 
            impliedCostPercentageOfMaxGasCost: 75, 
            wallet: userOpSigner, 
            sigType: bytes4(0)
        });

        return userOp;
    }

    /// @notice Generates an ERC-1271 hash for the given contents and account.
    /// @param contents The contents hash.
    /// @param account The account address.
    /// @return The ERC-1271 hash.
    function toERC1271Hash(bytes32 contents, address account) internal view returns (bytes32) {
        bytes32 parentStructHash = keccak256(
            abi.encodePacked(
                abi.encode(
                    keccak256(
                        "TypedDataSign(Contents contents,string name,string version,uint256 chainId,address verifyingContract,bytes32 salt)Contents(bytes32 stuff)"
                    ),
                    contents
                ),
                accountDomainStructFields(account)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", APP_DOMAIN_SEPARATOR, parentStructHash));
    }

    /// @notice Generates a contents hash.
    /// @param contents The contents hash.
    /// @return The EIP-712 hash.
    function toContentsHash(bytes32 contents) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(hex"1901", APP_DOMAIN_SEPARATOR, contents));
    }

    /// @notice Retrieves the EIP-712 domain struct fields.
    /// @param account The account address.
    /// @return The encoded EIP-712 domain struct fields.
    function accountDomainStructFields(address account) internal view returns (bytes memory) {
        AccountDomainStruct memory t;
        ( /*fields*/ , t.name, t.version, t.chainId, t.verifyingContract, t.salt, /*extensions*/ ) =
            EIP712(account).eip712Domain();

        return abi.encode(
            keccak256(bytes(t.name)),
            keccak256(bytes(t.version)),
            t.chainId,
            t.verifyingContract, // Use the account address as the verifying contract.
            t.salt
        );
    }
}
