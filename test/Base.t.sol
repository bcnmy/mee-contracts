// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { Test, Vm } from "forge-std/Test.sol";
import { IEntryPoint } from "account-abstraction/interfaces/IEntryPoint.sol";
import { EntryPoint } from "account-abstraction/core/EntryPoint.sol";
import { PackedUserOperation, UserOperationLib } from "account-abstraction/core/UserOperationLib.sol";
import { MockAccount } from "./mock/MockAccount.sol";

import { BaseNodePaymaster } from "../contracts/BaseNodePaymaster.sol";
import { NodePaymaster } from "../contracts/NodePaymaster.sol";
import { EmittingNodePaymaster } from "./mock/EmittingNodePaymaster.sol";
import { MockNodePaymaster } from "./mock/MockNodePaymaster.sol";
import { K1MeeValidator } from "../contracts/validators/K1MeeValidator.sol";
import { CopyUserOpLib } from "./util/CopyUserOpLib.sol";
import "contracts/types/Constants.sol";
import { LibZip } from "solady/utils/LibZip.sol";
import { MockTarget } from "./mock/MockTarget.sol";
import { ECDSA } from "solady/utils/ECDSA.sol";

address constant ENTRYPOINT_V07_ADDRESS = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

contract BaseTest is Test {
    struct TestTemps {
        bytes32 userOpHash;
        bytes32 contents;
        address signer;
        uint256 privateKey;
        uint8 v;
        bytes32 r;
        bytes32 s;
        uint256 missingAccountFunds;
    }

    struct AccountDomainStruct {
        string name;
        string version;
        uint256 chainId;
        address verifyingContract;
        bytes32 salt;
    }

    using CopyUserOpLib for PackedUserOperation;
    using LibZip for bytes;

    uint256 constant MEE_NODE_HEX = 0x177ee170de;

    address constant MEE_NODE_EXECUTOR_EOA = address(0xa11cebeefb0bdecaf0);

    IEntryPoint internal ENTRYPOINT;

    NodePaymaster internal NODE_PAYMASTER;
    EmittingNodePaymaster internal EMITTING_NODE_PAYMASTER;
    MockNodePaymaster internal MOCK_NODE_PAYMASTER;
    K1MeeValidator internal k1MeeValidator;
    address internal MEE_NODE_ADDRESS;
    Vm.Wallet internal MEE_NODE;
    MockTarget internal mockTarget;

    address nodePmDeployer = address(0x011a23423423423);

    string constant MEE_USER_OP_SIGNATURE =
        "MEEUserOp(bytes32 userOpHash,uint256 lowerBoundTimestamp,uint256 upperBoundTimestamp)";
    string constant SUPER_TX_SIGNATURE_HEADER = "SuperTx";

    function setUp() public virtual {
        setupEntrypoint();

        MEE_NODE = createAndFundWallet("MEE_NODE", 1000 ether);
        MEE_NODE_ADDRESS = MEE_NODE.addr;

        deployNodePaymaster();
        k1MeeValidator = new K1MeeValidator();
        mockTarget = new MockTarget();
    }

    function deployNodePaymaster() internal {
        vm.prank(nodePmDeployer);

        address[] memory workerEOAs = new address[](1);
        workerEOAs[0] = MEE_NODE_EXECUTOR_EOA;

        NODE_PAYMASTER = new NodePaymaster(ENTRYPOINT, MEE_NODE_ADDRESS, workerEOAs);
        EMITTING_NODE_PAYMASTER = new EmittingNodePaymaster(ENTRYPOINT, MEE_NODE_ADDRESS);
        MOCK_NODE_PAYMASTER = new MockNodePaymaster(ENTRYPOINT, MEE_NODE_ADDRESS);

        address payable[] memory nodePaymasters = new address payable[](3);
        nodePaymasters[0] = payable(address(NODE_PAYMASTER));
        nodePaymasters[1] = payable(address(EMITTING_NODE_PAYMASTER));
        nodePaymasters[2] = payable(address(MOCK_NODE_PAYMASTER));

        for (uint256 i = 0; i < nodePaymasters.length; i++) {
            assertEq(BaseNodePaymaster(nodePaymasters[i]).owner(), MEE_NODE_ADDRESS, "Owner should be properly set");

            vm.deal(nodePaymasters[i], 100 ether);

            vm.prank(nodePaymasters[i]);
            ENTRYPOINT.depositTo{ value: 10 ether }(nodePaymasters[i]);
        }
    }

    function deployMockAccount(address validator, address handler) internal returns (MockAccount) {
        return new MockAccount(validator, handler);
    }

    function setupEntrypoint() internal {
        if (block.chainid == 31_337) {
            if (address(ENTRYPOINT) != address(0)) {
                return;
            }
            ENTRYPOINT = new EntryPoint();
            vm.etch(address(ENTRYPOINT_V07_ADDRESS), address(ENTRYPOINT).code);
            ENTRYPOINT = IEntryPoint(ENTRYPOINT_V07_ADDRESS);
        } else {
            ENTRYPOINT = IEntryPoint(ENTRYPOINT_V07_ADDRESS);
        }
    }

    // ============ BUILD USER OP UTILS ============

    function buildUserOpWithCalldata(
        address account,
        bytes memory callData,
        Vm.Wallet memory wallet,
        uint256 preVerificationGasLimit,
        uint128 verificationGasLimit,
        uint128 callGasLimit
    )
        internal
        view
        returns (PackedUserOperation memory userOp)
    {
        uint256 nonce = ENTRYPOINT.getNonce(account, 0);
        userOp = buildPackedUserOp({
            sender: account,
            nonce: nonce,
            verificationGasLimit: verificationGasLimit,
            callGasLimit: callGasLimit,
            preVerificationGasLimit: preVerificationGasLimit
        });
        userOp.callData = callData;

        bytes memory signature = signUserOp(wallet, userOp);
        userOp.signature = signature;
    }

    /// @notice Builds a user operation struct for account abstraction tests
    /// @param sender The sender address
    /// @param nonce The nonce
    /// @return userOp The built user operation
    function buildPackedUserOp(
        address sender,
        uint256 nonce,
        uint128 verificationGasLimit,
        uint128 callGasLimit,
        uint256 preVerificationGasLimit
    )
        internal
        pure
        returns (PackedUserOperation memory)
    {
        return PackedUserOperation({
            sender: sender,
            nonce: nonce,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(abi.encodePacked(verificationGasLimit, callGasLimit)), // verification and call gas
                // limit
            preVerificationGas: preVerificationGasLimit, // Adjusted preVerificationGas
            gasFees: bytes32(abi.encodePacked(uint128(11e9), uint128(1e9))), // maxFeePerGas = 11gwei and
                // maxPriorityFeePerGas = 1gwei
            paymasterAndData: "",
            signature: ""
        });
    }

    function signUserOp(Vm.Wallet memory wallet, PackedUserOperation memory userOp) internal view returns (bytes memory) {
        bytes32 opHash = ECDSA.toEthSignedMessageHash(_getUserOpHash(userOp));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wallet.privateKey, opHash);
        return abi.encodePacked(r, s, v);
    }

    function _getUserOpHash(PackedUserOperation memory userOp) internal view returns (bytes32) {
        return ENTRYPOINT.getUserOpHash(userOp);
    }

    // ============ WALLET UTILS ============

    function createAndFundWallet(string memory name, uint256 amount) internal returns (Vm.Wallet memory) {
        Vm.Wallet memory wallet = newWallet(name);
        vm.deal(wallet.addr, amount);
        return wallet;
    }

    function newWallet(string memory name) internal returns (Vm.Wallet memory) {
        Vm.Wallet memory wallet = vm.createWallet(name);
        vm.label(wallet.addr, name);
        return wallet;
    }

    // ============ USER OP UTILS ============

    function unpackMaxPriorityFeePerGasMemory(PackedUserOperation memory userOp) internal pure returns (uint256) {
        return UserOperationLib.unpackHigh128(userOp.gasFees);
    }

    function unpackMaxFeePerGasMemory(PackedUserOperation memory userOp) internal pure returns (uint256) {
        return UserOperationLib.unpackLow128(userOp.gasFees);
    }

    function unpackVerificationGasLimitMemory(PackedUserOperation memory userOp) internal pure returns (uint256) {
        return UserOperationLib.unpackHigh128(userOp.accountGasLimits);
    }

    function unpackCallGasLimitMemory(PackedUserOperation memory userOp) internal pure returns (uint256) {
        return UserOperationLib.unpackLow128(userOp.accountGasLimits);
    }
}
