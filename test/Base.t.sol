// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { Test, Vm, console2 } from "forge-std/Test.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {EntryPoint} from "account-abstraction/core/EntryPoint.sol";
import {PackedUserOperation, UserOperationLib} from "account-abstraction/core/UserOperationLib.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {MockAccount} from "./mock/MockAccount.sol";
import {MockTarget} from "./mock/MockTarget.sol";
import {NodePaymaster} from "../contracts/NodePaymaster.sol";
import {K1MeeValidator} from "../contracts/validators/K1MeeValidator.sol";
import {MEEEntryPoint} from "../contracts/MEEEntryPoint.sol";
import {MerkleProof} from "openzeppelin/utils/cryptography/MerkleProof.sol";
import {MEEUserOpLib} from "../contracts/lib/util/MEEUserOpLib.sol";
import {Merkle} from "murky-trees/Merkle.sol";
import {CopyUserOpLib} from "./util/CopyUserOpLib.sol";
import "contracts/types/Constants.sol";
import {LibZip} from "solady/utils/LibZip.sol";

contract BaseTest is Test {

    using CopyUserOpLib for PackedUserOperation;
    using LibZip for bytes;

    bytes32 constant NODE_PM_CODE_HASH = 0x953893521ff5c48cec7282fcc5835105a4621aeaad353558e80c85277b46fa08;

    address constant ENTRYPOINT_V07_ADDRESS = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address constant MEE_NODE_ADDRESS = 0x177EE170D31177Ee170D31177ee170d31177eE17;
    uint256 constant MEE_NODE_HEX = 0x177ee170de;

    IEntryPoint internal ENTRYPOINT;
    MEEEntryPoint internal MEE_ENTRYPOINT;
    NodePaymaster internal NODE_PAYMASTER;
    K1MeeValidator internal k1MeeValidator;
    
    MockTarget internal mockTarget;
    address nodePmDeployer = address(0x011a23423423423);

    function setUp() public virtual {
        setupEntrypoint();
        deployMEEEntryPoint();
        vm.deal(MEE_NODE_ADDRESS, 1_000 ether);
        deployNodePaymaster(ENTRYPOINT, MEE_NODE_ADDRESS);
        mockTarget = new MockTarget();
        k1MeeValidator = new K1MeeValidator();
    }

    function deployMEEEntryPoint() internal {
        MEE_ENTRYPOINT = new MEEEntryPoint(ENTRYPOINT, NODE_PM_CODE_HASH);
    }

    function deployNodePaymaster(IEntryPoint ep, address meeNodeAddress) internal {
        vm.prank(nodePmDeployer);
        NODE_PAYMASTER = new NodePaymaster(ENTRYPOINT, MEE_NODE_ADDRESS);

        assertEq(NODE_PAYMASTER.owner(), MEE_NODE_ADDRESS, "Owner should be properly set");

        vm.deal(address(NODE_PAYMASTER), 100 ether);

        vm.prank(address(NODE_PAYMASTER));
        ENTRYPOINT.depositTo{value: 10 ether}(address(NODE_PAYMASTER));
    }

    function deployMockAccount(address validator) internal returns (MockAccount) {
        return new MockAccount(validator);
    }

    function setupEntrypoint() internal {
        if (block.chainid == 31337) {
            if(address(ENTRYPOINT) != address(0)){
                return;
            }
            ENTRYPOINT = new EntryPoint();
            vm.etch(address(ENTRYPOINT_V07_ADDRESS), address(ENTRYPOINT).code);
            ENTRYPOINT = IEntryPoint(ENTRYPOINT_V07_ADDRESS);
        } else {
            ENTRYPOINT = IEntryPoint(ENTRYPOINT_V07_ADDRESS);
        }
    }

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
        userOp = buildPackedUserOp(account, nonce, verificationGasLimit, callGasLimit, preVerificationGasLimit);
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
    ) internal pure returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: sender,
            nonce: nonce,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(abi.encodePacked(verificationGasLimit, callGasLimit)), // verification and call gas limit
            preVerificationGas: preVerificationGasLimit, // Adjusted preVerificationGas
            gasFees: bytes32(abi.encodePacked(uint128(11e9), uint128(1e9))), // maxFeePerGas = 11gwei and maxPriorityFeePerGas = 1gwei
            paymasterAndData: "",
            signature: ""
        });
    }

    function signUserOp(Vm.Wallet memory wallet, PackedUserOperation memory userOp) internal view returns (bytes memory) {
        bytes32 opHash = ENTRYPOINT.getUserOpHash(userOp);
        opHash = MessageHashUtils.toEthSignedMessageHash(opHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wallet.privateKey, opHash);
        return abi.encodePacked(r, s, v);
    }

    function makeMEEUserOp(
        PackedUserOperation memory userOp,
        uint128 pmValidationGasLimit,
        uint128 pmPostOpGasLimit,
        uint256 premiumPercentage,
        Vm.Wallet memory wallet,
        bytes4 sigType
    ) internal view returns (PackedUserOperation memory) {
        uint256 maxGasLimit = userOp.preVerificationGas + unpackVerificationGasLimitMemory(userOp) + unpackCallGasLimitMemory(userOp) + pmValidationGasLimit + pmPostOpGasLimit;
        userOp.paymasterAndData = makePMAndDataForOwnPM(address(NODE_PAYMASTER), pmValidationGasLimit, pmPostOpGasLimit, maxGasLimit, premiumPercentage);
        userOp.signature = signUserOp(wallet, userOp);
        if (sigType != bytes4(0)) {
            userOp.signature = abi.encodePacked(sigType, userOp.signature);
        }
        return userOp;
    }

    function duplicateUserOpAndIncrementNonce(PackedUserOperation memory userOp, Vm.Wallet memory userOpSigner) internal view returns (PackedUserOperation memory) {
        PackedUserOperation memory newUserOp = userOp.deepCopy();
        newUserOp.nonce = userOp.nonce + 1;
        newUserOp.signature = signUserOp(userOpSigner, newUserOp);
        return newUserOp;
    }

    function cloneUserOpToAnArray(PackedUserOperation memory userOp, Vm.Wallet memory userOpSigner, uint256 numOfClones) internal view returns (PackedUserOperation[] memory) {
        PackedUserOperation[] memory userOps = new PackedUserOperation[](numOfClones+1);
        userOps[0] = userOp;
        for (uint256 i = 0; i < numOfClones; i++) {
            assertEq(userOps[i].nonce, i);
            userOps[i+1] = duplicateUserOpAndIncrementNonce(userOps[i], userOpSigner);
        }
        return userOps;
    }

    function makeSimpleSuperTx(PackedUserOperation[] memory userOps, Vm.Wallet memory superTxSigner) internal returns (PackedUserOperation[] memory) {
        PackedUserOperation[] memory superTxUserOps = new PackedUserOperation[](userOps.length);
        bytes32[] memory leaves = new bytes32[](userOps.length);

        uint48 lowerBoundTimestamp = uint48(block.timestamp);
        uint48 upperBoundTimestamp = uint48(block.timestamp + 1000);

        // build leaves
        for (uint256 i = 0; i < userOps.length; i++) {
            bytes32 userOpHash = ENTRYPOINT.getUserOpHash(userOps[i]);
            leaves[i] = MEEUserOpLib.getMEEUserOpHash(userOpHash, lowerBoundTimestamp, upperBoundTimestamp);
        }

        // make a tree
        Merkle tree = new Merkle();
        bytes32 root = tree.getRoot(leaves);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(superTxSigner.privateKey, root);
        bytes memory superTxHashSignature = abi.encodePacked(r, s, v);

        for (uint256 i = 0; i < userOps.length; i++) {
            superTxUserOps[i] = userOps[i].deepCopy();
            bytes32[] memory proof = tree.getProof(leaves, i);
            bytes memory signature = 
                abi.encodePacked(
                    SIG_TYPE_SIMPLE,
                    abi.encode(
                        root,
                        proof,
                        lowerBoundTimestamp,
                        upperBoundTimestamp,
                        superTxHashSignature
                    )//.flzCompress()
            );
            superTxUserOps[i].signature = signature;
        }
        return superTxUserOps;
    }

    // TODO: makeSuperTx with custom timestamps

    function makeSuperTxSignatures(bytes32 baseHash, uint256 total, Vm.Wallet memory superTxSigner
    ) internal returns (bytes[] memory) {
        bytes[] memory meeSigs = new bytes[](total);
        require(total > 0, "total must be greater than 0");

        bytes32[] memory leaves = new bytes32[](total);

        for(uint256 i=0; i<total; i++) {
            bytes32 hash = keccak256(abi.encode(baseHash, i));
            leaves[i] = hash;
        }

        Merkle tree = new Merkle();
        bytes32 root = tree.getRoot(leaves);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(superTxSigner.privateKey, root);
        bytes memory superTxHashSignature = abi.encodePacked(r, s, v);

        for(uint256 i=0; i<total; i++) {
            bytes32[] memory proof = tree.getProof(leaves, i);
            bytes memory signature = abi.encodePacked(SIG_TYPE_SIMPLE, abi.encode(root, proof, superTxHashSignature));
            meeSigs[i] = signature;
        }
        return meeSigs;
    }

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

    function unpackMaxPriorityFeePerGasMemory(PackedUserOperation memory userOp)
    internal pure returns (uint256) {
        return UserOperationLib.unpackHigh128(userOp.gasFees);
    }

    function unpackMaxFeePerGasMemory(PackedUserOperation memory userOp)
    internal pure returns (uint256) {
        return UserOperationLib.unpackLow128(userOp.gasFees);
    }

    function unpackVerificationGasLimitMemory(PackedUserOperation memory userOp)
    internal pure returns (uint256) {
        return UserOperationLib.unpackHigh128(userOp.accountGasLimits);
    }

    function unpackCallGasLimitMemory(PackedUserOperation memory userOp)
    internal pure returns (uint256) {
        return UserOperationLib.unpackLow128(userOp.accountGasLimits);
    }

    function makePMAndDataForOwnPM(
        address nodePM, 
        uint128 pmValidationGasLimit, 
        uint128 pmPostOpGasLimit, 
        uint256 maxGasLimit, 
        uint256 premiumPercentage
    ) internal view returns (bytes memory) {
        return abi.encodePacked(
            nodePM, 
            pmValidationGasLimit, // pm validation gas limit
            pmPostOpGasLimit, // pm post-op gas limit
            premiumPercentage
        );
    }

}

