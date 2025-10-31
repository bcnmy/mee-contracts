// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { MeeK1Validator_Base_Test } from "../MeeK1Validator_Base_Test.t.sol";
import { Vm } from "forge-std/Test.sol";
import { PackedUserOperation } from "account-abstraction/core/UserOperationLib.sol";
import { ERC20 } from "solady/tokens/ERC20.sol";
import { MockERC20PermitToken } from "../../../mock/MockERC20PermitToken.sol";
import { EIP1271_SUCCESS } from "contracts/types/Constants.sol";
import { MerkleTreeLib } from "solady/utils/MerkleTreeLib.sol";

import { EcdsaLib } from "contracts/lib/util/EcdsaLib.sol";
import {
    DecodedErc20PermitSig,
    DecodedErc20PermitSigShort,
    PERMIT_TYPEHASH
} from "contracts/lib/fusion/PermitValidatorLib.sol";
import { SIG_TYPE_ERC20_PERMIT } from "contracts/types/Constants.sol";
import { CopyUserOpLib } from "../../../util/CopyUserOpLib.sol";

contract MeeK1Validator_Permit_Mode_Test is MeeK1Validator_Base_Test {
    using CopyUserOpLib for PackedUserOperation;
    using MerkleTreeLib for bytes32[];

    function setUp() public virtual override {
        super.setUp();
    }

    function test_superTxFlow_permit_mode_ValidateUserOp_success(uint256 numOfClones) public {
        numOfClones = bound(numOfClones, 1, 25);
        MockERC20PermitToken erc20 = new MockERC20PermitToken("test", "TEST");
        deal(address(erc20), wallet.addr, 1000 ether); // mint erc20 tokens to the wallet
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

        PackedUserOperation[] memory userOps = _cloneUserOpToAnArray(userOp, wallet, numOfClones);

        userOps = _makePermitSuperTx({
            userOps: userOps,
            token: erc20,
            signer: wallet,
            spender: address(mockAccount),
            amount: amountToTransfer * userOps.length
        });

        vm.startPrank(MEE_NODE_EXECUTOR_EOA, MEE_NODE_EXECUTOR_EOA);
        ENTRYPOINT.handleOps(userOps, payable(MEE_NODE_ADDRESS));
        vm.stopPrank();

        assertEq(erc20.balanceOf(bob), amountToTransfer * numOfClones + 1e18);
    }

    function test_superTxFlow_permit_mode_1271_and_WithData_success(uint256 numOfObjs) public {
        numOfObjs = bound(numOfObjs, 2, 25);
        MockERC20PermitToken erc20 = new MockERC20PermitToken("test", "TEST");
        bytes[] memory meeSigs = new bytes[](numOfObjs);
        bytes32 baseHash = keccak256(abi.encode("test"));

        meeSigs = _makePermitSuperTxSignatures({
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

    // ==== PERMIT SUPER TX UTILS ====

    function _makePermitSuperTx(
        PackedUserOperation[] memory userOps,
        ERC20 token,
        Vm.Wallet memory signer,
        address spender,
        uint256 amount
    )
        internal
        view
        returns (PackedUserOperation[] memory)
    {
        PackedUserOperation[] memory superTxUserOps = new PackedUserOperation[](userOps.length);
        uint48 lowerBoundTimestamp = uint48(block.timestamp);
        uint48 upperBoundTimestamp = uint48(block.timestamp + 1000);
        bytes32[] memory leaves = _buildLeavesOutOfUserOps(userOps, lowerBoundTimestamp, upperBoundTimestamp);
        (userOps, lowerBoundTimestamp, upperBoundTimestamp);

        // make a tree
        bytes32[] memory tree = leaves.build();
        bytes32 root = tree.root();

        bytes32 structHash = keccak256(
            abi.encode(
                PERMIT_TYPEHASH,
                signer.addr,
                spender,
                amount,
                token.nonces(signer.addr), //nonce
                //root //we use deadline field to store the super tx root hash
                root
            )
        );

        bytes32 dataHashToSign = EcdsaLib.toTypedDataHash(token.DOMAIN_SEPARATOR(), structHash);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signer.privateKey, dataHashToSign);

        for (uint256 i = 0; i < userOps.length; i++) {
            superTxUserOps[i] = userOps[i].deepCopy();
            bytes32[] memory proof = tree.leafProof(i);

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
        }
        return superTxUserOps;
    }

    function _makePermitSuperTxSignatures(
        bytes32 baseHash,
        uint256 total,
        ERC20 token,
        Vm.Wallet memory signer,
        address spender,
        uint256 amount
    )
        internal
        view
        returns (bytes[] memory)
    {
        bytes[] memory meeSigs = new bytes[](total);
        require(total > 0, "total must be greater than 0");

        bytes32[] memory leaves = new bytes32[](total);

        for (uint256 i = 0; i < total; i++) {
            if (i / 2 == 0) {
                leaves[i] = keccak256(abi.encode(baseHash, i));
            } else {
                // safe hash
                leaves[i] = keccak256(abi.encodePacked(keccak256(abi.encode(baseHash, i)), spender));
            }
        }

        bytes32[] memory tree = leaves.build();
        bytes32 root = tree.root();

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

        bytes32 dataHashToSign = EcdsaLib.toTypedDataHash(token.DOMAIN_SEPARATOR(), structHash);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signer.privateKey, dataHashToSign);

        for (uint256 i = 0; i < total; i++) {
            bytes32[] memory proof = tree.leafProof(i);
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
}
