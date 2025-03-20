// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {EntryPoint} from "account-abstraction/core/EntryPoint.sol";
import {PackedUserOperation, UserOperationLib} from "account-abstraction/core/UserOperationLib.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {MockAccount, ENTRY_POINT_V07} from "./mock/MockAccount.sol";
import {MockTarget} from "./mock/MockTarget.sol";
import {NodePaymaster} from "../contracts/NodePaymaster.sol";
import {K1MeeValidator} from "../contracts/validators/K1MeeValidator.sol";
import {MEEEntryPoint} from "../contracts/MEEEntryPoint.sol";
import {MerkleProof} from "openzeppelin/utils/cryptography/MerkleProof.sol";
import {MEEUserOpHashLib} from "../contracts/lib/util/MEEUserOpHashLib.sol";
import {Merkle} from "murky-trees/Merkle.sol";
import {CopyUserOpLib} from "./util/CopyUserOpLib.sol";
import "contracts/types/Constants.sol";
import {LibZip} from "solady/utils/LibZip.sol";
import {ERC20Permit} from "openzeppelin/token/ERC20/extensions/ERC20Permit.sol";
import {IERC20Permit} from "openzeppelin/token/ERC20/extensions/IERC20Permit.sol";
import {
    PERMIT_TYPEHASH,
    DecodedErc20PermitSig,
    DecodedErc20PermitSigShort,
    PermitValidatorLib
} from "contracts/lib/fusion/PermitValidatorLib.sol";
import {LibRLP} from "solady/utils/LibRLP.sol";

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
    using LibRLP for LibRLP.List;

    address constant ENTRYPOINT_V07_ADDRESS = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    uint256 constant MEE_NODE_HEX = 0x177ee170de;

    address constant MEE_NODE_EXECUTOR_EOA = address(0xa11cebeefb0bdecaf0);

    IEntryPoint internal ENTRYPOINT;
    MEEEntryPoint internal MEE_ENTRYPOINT;
    NodePaymaster internal NODE_PAYMASTER;
    K1MeeValidator internal k1MeeValidator;
    address internal MEE_NODE_ADDRESS;
    Vm.Wallet internal MEE_NODE;
    
    MockTarget internal mockTarget;
    address nodePmDeployer = address(0x011a23423423423);

    function setUp() public virtual {
        setupEntrypoint();
        
        MEE_NODE = createAndFundWallet("MEE_NODE", 1_000 ether);
        MEE_NODE_ADDRESS = MEE_NODE.addr;
        
        deployNodePaymaster(ENTRYPOINT, MEE_NODE_ADDRESS);
        
        deployMEEEntryPoint(address(NODE_PAYMASTER).codehash);

        mockTarget = new MockTarget();
        k1MeeValidator = new K1MeeValidator();
    }

    function deployMEEEntryPoint(bytes32 nodePmCodeHash) internal {
        MEE_ENTRYPOINT = new MEEEntryPoint(ENTRYPOINT, nodePmCodeHash);
    }

    function deployNodePaymaster(IEntryPoint ep, address meeNodeAddress) internal {
        vm.prank(nodePmDeployer);
        NODE_PAYMASTER = new NodePaymaster(ENTRYPOINT, MEE_NODE_ADDRESS);

        assertEq(NODE_PAYMASTER.owner(), MEE_NODE_ADDRESS, "Owner should be properly set");

        vm.deal(address(NODE_PAYMASTER), 100 ether);

        vm.prank(address(NODE_PAYMASTER));
        ENTRYPOINT.depositTo{value: 10 ether}(address(NODE_PAYMASTER));
    }

    function deployMockAccount(address validator, address handler) internal returns (MockAccount) {
        return new MockAccount(validator, handler);
    }

    function setupEntrypoint() internal {
        if (block.chainid == 31337) {
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
    ) internal view returns (PackedUserOperation memory userOp) {
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
        bytes32 opHash = MessageHashUtils.toEthSignedMessageHash(_getUserOpHash(userOp));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wallet.privateKey, opHash);
        return abi.encodePacked(r, s, v);
    }

    function addNodeMasterSig(PackedUserOperation memory userOp, Vm.Wallet memory nodeMaster, address approvedEOA) internal view returns (PackedUserOperation memory) {
         bytes32 hashToSign = MessageHashUtils.toEthSignedMessageHash(keccak256(abi.encodePacked(
            _getUserOpHash(userOp),
            approvedEOA
        )));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(nodeMaster.privateKey, hashToSign);
        bytes memory nodeMasterSig = abi.encodePacked(r, s, v);
        userOp.signature = abi.encodePacked(userOp.signature, nodeMasterSig);
        return userOp;
    }

    function _getUserOpHash(PackedUserOperation memory userOp) internal view returns (bytes32) {
        return ENTRYPOINT.getUserOpHash(userOp);
    }

    // ============ MEE USER OP SUPER TX UTILS ============

    function makeMEEUserOp(
        PackedUserOperation memory userOp,
        uint128 pmValidationGasLimit,
        uint128 pmPostOpGasLimit,
        uint256 impliedCostPercentageOfMaxGasCost,
        Vm.Wallet memory wallet,
        bytes4 sigType
    ) internal view returns (PackedUserOperation memory) {
        uint256 maxGasLimit = userOp.preVerificationGas + unpackVerificationGasLimitMemory(userOp)
            + unpackCallGasLimitMemory(userOp) + pmValidationGasLimit + pmPostOpGasLimit;
        uint256 maxGasCost = maxGasLimit * unpackMaxFeePerGasMemory(userOp);
        userOp.paymasterAndData = makePMAndDataForOwnPM({
            nodePM: address(NODE_PAYMASTER),
            pmValidationGasLimit: pmValidationGasLimit,
            pmPostOpGasLimit: pmPostOpGasLimit,
            pmMode: NODE_PM_MODE_USER,
            premiumMode: NODE_PM_PREMIUM_PERCENT,
            financialData: 17_00000 // percentage premium = 17% of maxGasCost
        });
        userOp.signature = signUserOp(wallet, userOp);
        if (sigType != bytes4(0)) {
            userOp.signature = abi.encodePacked(sigType, userOp.signature);
        }
        return userOp;
    }

    function duplicateUserOpAndIncrementNonce(PackedUserOperation memory userOp, Vm.Wallet memory userOpSigner)
        internal
        view
        returns (PackedUserOperation memory)
    {
        PackedUserOperation memory newUserOp = userOp.deepCopy();
        newUserOp.nonce = userOp.nonce + 1;
        newUserOp.signature = signUserOp(userOpSigner, newUserOp);
        return newUserOp;
    }

    function cloneUserOpToAnArray(PackedUserOperation memory userOp, Vm.Wallet memory userOpSigner, uint256 numOfClones)
        internal
        view
        returns (PackedUserOperation[] memory)
    {
        PackedUserOperation[] memory userOps = new PackedUserOperation[](numOfClones + 1);
        userOps[0] = userOp;
        for (uint256 i = 0; i < numOfClones; i++) {
            assertEq(userOps[i].nonce, i);
            userOps[i + 1] = duplicateUserOpAndIncrementNonce(userOps[i], userOpSigner);
        }
        return userOps;
    }

    function buildLeavesOutOfUserOps(
        PackedUserOperation[] memory userOps,
        uint48 lowerBoundTimestamp,
        uint48 upperBoundTimestamp
    ) internal view returns (bytes32[] memory) {
        bytes32[] memory leaves = new bytes32[](userOps.length);
        for (uint256 i = 0; i < userOps.length; i++) {
            bytes32 userOpHash = ENTRYPOINT.getUserOpHash(userOps[i]);
            leaves[i] = MEEUserOpHashLib.getMEEUserOpHash(userOpHash, lowerBoundTimestamp, upperBoundTimestamp);
        }
        return leaves;
    }
    // ==== SIMPLE SUPER TX UTILS ====

    function makeSimpleSuperTx(PackedUserOperation[] memory userOps, Vm.Wallet memory superTxSigner)
        internal
        returns (PackedUserOperation[] memory)
    {
        PackedUserOperation[] memory superTxUserOps = new PackedUserOperation[](userOps.length);
        uint48 lowerBoundTimestamp = uint48(block.timestamp);
        uint48 upperBoundTimestamp = uint48(block.timestamp + 1000);
        bytes32[] memory leaves = buildLeavesOutOfUserOps(userOps, lowerBoundTimestamp, upperBoundTimestamp);

        // make a tree
        Merkle tree = new Merkle();
        bytes32 root = tree.getRoot(leaves);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(superTxSigner.privateKey, root);
        bytes memory superTxHashSignature = abi.encodePacked(r, s, v);

        for (uint256 i = 0; i < userOps.length; i++) {
            superTxUserOps[i] = userOps[i].deepCopy();
            bytes32[] memory proof = tree.getProof(leaves, i);
            bytes memory signature = abi.encodePacked(
                SIG_TYPE_SIMPLE, abi.encode(root, lowerBoundTimestamp, upperBoundTimestamp, proof, superTxHashSignature)
            );
            superTxUserOps[i].signature = signature;
            superTxUserOps[i] = addNodeMasterSig(superTxUserOps[i], MEE_NODE, MEE_NODE_EXECUTOR_EOA);
        }
        return superTxUserOps;
    }

    function makeSimpleSuperTxSignatures(
        bytes32 baseHash,
        uint256 total,
        Vm.Wallet memory superTxSigner,
        address mockAccount
    ) internal returns (bytes[] memory) {
        bytes[] memory meeSigs = new bytes[](total);
        require(total > 0, "total must be greater than 0");

        bytes32[] memory leaves = new bytes32[](total);

        bytes32 hash;
        for (uint256 i = 0; i < total; i++) {
            if (i / 2 == 0) {
                hash = keccak256(abi.encode(baseHash, i));
            } else {
                hash = keccak256(abi.encodePacked(keccak256(abi.encode(baseHash, i)), address(mockAccount)));
            }
            leaves[i] = hash;
        }

        Merkle tree = new Merkle();
        bytes32 root = tree.getRoot(leaves);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(superTxSigner.privateKey, root);
        bytes memory superTxHashSignature = abi.encodePacked(r, s, v);

        for (uint256 i = 0; i < total; i++) {
            bytes32[] memory proof = tree.getProof(leaves, i);
            bytes memory signature = abi.encodePacked(SIG_TYPE_SIMPLE, abi.encode(root, proof, superTxHashSignature));
            meeSigs[i] = signature;
        }
        return meeSigs;
    }

    // ==== PERMIT SUPER TX UTILS ====

    function makePermitSuperTx(
        PackedUserOperation[] memory userOps,
        IERC20Permit token,
        Vm.Wallet memory signer,
        address spender,
        uint256 amount
    ) internal returns (PackedUserOperation[] memory) {
        PackedUserOperation[] memory superTxUserOps = new PackedUserOperation[](userOps.length);
        uint48 lowerBoundTimestamp = uint48(block.timestamp);
        uint48 upperBoundTimestamp = uint48(block.timestamp + 1000);
        bytes32[] memory leaves = buildLeavesOutOfUserOps(userOps, lowerBoundTimestamp, upperBoundTimestamp);

        // make a tree
        Merkle tree = new Merkle();
        bytes32 root = tree.getRoot(leaves);

        bytes32 structHash = keccak256(
            abi.encode(
                PERMIT_TYPEHASH,
                signer.addr,
                spender,
                amount,
                token.nonces(signer.addr), //nonce
                root //we use deadline field to store the super tx root hash
            )
        );

        bytes32 dataHashToSign = MessageHashUtils.toTypedDataHash(token.DOMAIN_SEPARATOR(), structHash);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signer.privateKey, dataHashToSign);

        for (uint256 i = 0; i < userOps.length; i++) {
            superTxUserOps[i] = userOps[i].deepCopy();
            bytes32[] memory proof = tree.getProof(leaves, i);

            bytes memory signature = abi.encodePacked(
                SIG_TYPE_ERC20_PERMIT,
                abi.encode(
                    DecodedErc20PermitSig({
                        token: token,
                        spender: spender,
                        domainSeparator: token.DOMAIN_SEPARATOR(),
                        amount: amount,
                        nonce: token.nonces(signer.addr),
                        isPermitTx: i == 0 ? true : false,
                        superTxHash: root,
                        lowerBoundTimestamp: lowerBoundTimestamp,
                        upperBoundTimestamp: upperBoundTimestamp,
                        v: v,
                        r: r,
                        s: s,
                        proof: proof
                    })
                )
            );

            superTxUserOps[i].signature = signature;
            superTxUserOps[i] = addNodeMasterSig(superTxUserOps[i], MEE_NODE, MEE_NODE_EXECUTOR_EOA);
        }
        return superTxUserOps;
    }

    function makePermitSuperTxSignatures(
        bytes32 baseHash,
        uint256 total,
        IERC20Permit token,
        Vm.Wallet memory signer,
        address spender,
        uint256 amount
    ) internal returns (bytes[] memory) {
        bytes[] memory meeSigs = new bytes[](total);
        require(total > 0, "total must be greater than 0");

        bytes32[] memory leaves = new bytes32[](total);

        for (uint256 i = 0; i < total; i++) {
            if (i / 2 == 0) {
                leaves[i] = keccak256(abi.encode(baseHash, i));
            } else {
                leaves[i] = keccak256(abi.encodePacked(keccak256(abi.encode(baseHash, i)), spender));
            }
        }

        Merkle tree = new Merkle();
        bytes32 root = tree.getRoot(leaves);

        bytes32 structHash = keccak256(
            abi.encode(
                PERMIT_TYPEHASH,
                signer.addr,
                spender,
                amount,
                token.nonces(signer.addr), //nonce
                root //we use deadline field to store the super tx root hash
            )
        );

        bytes32 dataHashToSign = MessageHashUtils.toTypedDataHash(token.DOMAIN_SEPARATOR(), structHash);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signer.privateKey, dataHashToSign);

        for (uint256 i = 0; i < total; i++) {
            bytes32[] memory proof = tree.getProof(leaves, i);
            bytes memory signature = abi.encodePacked(
                SIG_TYPE_ERC20_PERMIT,
                abi.encode(
                    DecodedErc20PermitSigShort({
                        spender: spender,
                        domainSeparator: token.DOMAIN_SEPARATOR(),
                        amount: amount,
                        nonce: token.nonces(signer.addr),
                        superTxHash: root,
                        v: v,
                        r: r,
                        s: s,
                        proof: proof
                    })
                )
            );
            meeSigs[i] = signature;
        }
        return meeSigs;
    }

    //                  ========== ON CHAIN TXN MODE ==========

    function makeOnChainTxnSuperTx(
        PackedUserOperation[] memory userOps,
        Vm.Wallet memory superTxSigner,
        bytes memory callData
    ) internal returns (PackedUserOperation[] memory) {
        PackedUserOperation[] memory superTxUserOps = new PackedUserOperation[](userOps.length);
        uint48 lowerBoundTimestamp = uint48(block.timestamp);
        uint48 upperBoundTimestamp = uint48(block.timestamp + 1000);
        bytes32[] memory leaves = buildLeavesOutOfUserOps(userOps, lowerBoundTimestamp, upperBoundTimestamp);

        // make a tree
        Merkle tree = new Merkle();
        bytes32 root = tree.getRoot(leaves);

        callData = abi.encodePacked(callData, root);

        bytes memory serializedTx = getSerializedTxn(callData, address(0xa11cebeefb0bdecaf0), superTxSigner);

        for (uint256 i = 0; i < userOps.length; i++) {
            superTxUserOps[i] = userOps[i].deepCopy();
            bytes32[] memory proof = tree.getProof(leaves, i);
            bytes memory signature = abi.encodePacked(
                SIG_TYPE_ON_CHAIN,
                serializedTx,
                abi.encodePacked(proof),
                uint8(proof.length),
                lowerBoundTimestamp,
                upperBoundTimestamp
            );
            superTxUserOps[i].signature = signature;
            superTxUserOps[i] = addNodeMasterSig(superTxUserOps[i], MEE_NODE, MEE_NODE_EXECUTOR_EOA);
        }
        return superTxUserOps;
    }

    function makeOnChainTxnSuperTxSignatures(
        bytes32 baseHash,
        uint256 total,
        bytes memory callData,
        address smartAccount,
        Vm.Wallet memory superTxSigner
    ) internal returns (bytes[] memory) {
        bytes[] memory meeSigs = new bytes[](total);
        require(total > 0, "total must be greater than 0");

        bytes32[] memory leaves = new bytes32[](total);

        for (uint256 i = 0; i < total; i++) {
            if (i / 2 == 0) {
                leaves[i] = keccak256(abi.encode(baseHash, i));
            } else {
                leaves[i] = keccak256(abi.encodePacked(keccak256(abi.encode(baseHash, i)), smartAccount));
            }
        }

        Merkle tree = new Merkle();
        bytes32 root = tree.getRoot(leaves);
        callData = abi.encodePacked(callData, root);

        bytes memory serializedTx = getSerializedTxn(callData, address(0xa11cebeefb0bdecaf0), superTxSigner);

        for (uint256 i = 0; i < total; i++) {
            bytes32[] memory proof = tree.getProof(leaves, i);
            bytes memory signature =
                abi.encodePacked(SIG_TYPE_ON_CHAIN, serializedTx, abi.encodePacked(proof), uint8(proof.length));
            meeSigs[i] = signature;
        }
        return meeSigs;
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

    // ============ PM DATA UTILS ============

    function makePMAndDataForOwnPM(
        address nodePM,
        uint128 pmValidationGasLimit,
        uint128 pmPostOpGasLimit,
        bytes4 pmMode,
        bytes4 premiumMode,
        uint256 financialData
    ) internal view returns (bytes memory) {
        return abi.encodePacked(
            nodePM,
            pmValidationGasLimit, // pm validation gas limit
            pmPostOpGasLimit, // pm post-op gas limit
            pmMode,
            premiumMode,
            uint192(financialData)
        );
    }

    // ============ TXN SERIALIZATION UTILS ============

    function getSerializedTxn(
        bytes memory txnData, // calldata + root
        address to,
        Vm.Wallet memory signer
    ) internal view returns (bytes memory) {
        LibRLP.List memory accessList = LibRLP.p();

        LibRLP.List memory serializedTxList = 
            LibRLP.p(block.chainid). // chainId
                p(0). // nonce
                    p(uint256(1)). // maxPriorityFeePerGas
                        p(uint256(20)). // maxFeePerGas
                            p(uint256(50000)). // gasLimit
                                p(to). // to
                                    p(uint256(0)). // value
                                        p(txnData). // txn data
                                            p(accessList); // empty access list

        bytes32 uTxHash = keccak256(abi.encodePacked(hex"02", serializedTxList.encode()));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signer.privateKey, uTxHash);

        serializedTxList = serializedTxList.p(v == 28 ? true : false).p(uint256(r)).p(uint256(s)); // add v, r, s to the list
        return abi.encodePacked(hex"02", serializedTxList.encode()); // add tx type to the list
    }
}
