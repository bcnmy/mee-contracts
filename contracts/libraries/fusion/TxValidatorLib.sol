// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@account-abstraction/interfaces/PackedUserOperation.sol";
import "@account-abstraction/core/Helpers.sol";
import "../rlp/RLPDecoder.sol";
import "../rlp/RLPEncoder.sol";
import "../util/BytesLib.sol";
import "../util/UserOpLib.sol";
import "../util/EcdsaLib.sol";

library TxValidatorLib {

    uint8 constant LEGACY_TX_TYPE = 0x00;
    uint8 constant EIP1559_TX_TYPE = 0x02;

    uint8 constant RLP_ENCODED_R_S_BYTE_SIZE = 66; // 2 * 33bytes (for r, s components)
    uint8 constant EIP_155_MIN_V_VALUE = 37;
    uint8 constant HASH_BYTE_SIZE = 32;

    uint8 constant TIMESTAMP_BYTE_SIZE = 6;
    uint8 constant PROOF_ITEM_BYTE_SIZE = 32;
    uint8 constant ITX_HASH_BYTE_SIZE = 32;

    using RLPDecoder for RLPDecoder.RLPItem;
    using RLPDecoder for bytes;
    using RLPEncoder for uint;
    using BytesLib for bytes;
    
    struct TxData {
        uint8 txType;
        uint8 v;
        bytes32 r;
        bytes32 s;
        bytes32 utxHash;
        bytes32 appendedHash;
        bytes32[] proof;
        uint48 lowerBoundTimestamp;
        uint48 upperBoundTimestamp;
    }

    struct TxParams {
        uint256 v;
        bytes32 r;
        bytes32 s;
        bytes callData;
    }

    /**
    * This function parses the given userOpSignature into a valid fully signed EVM transaction.
    * Once parsed, the function will check for three conditions:
    *      1. is the expected hash found in the tx.data as the last 32bytes?
    *      2. is the recovered tx signer equal to the expected signer?
    *      2. is the given UserOp a part of the merkle tree 
    * 
    * If all the conditions are met - outside contract can be sure that the expected signer has indeed
    * approved the given hash by performing given on-chain transaction.
    * 
    * NOTES: This function will revert if either of following is met:
    *    1. the userOpSignature couldn't be parsed to a valid fully signed EVM transaction
    *    2. hash couldn't be extracted from the tx.data
    *    3. extracted hash wasn't equal to the provided expected hash
    *    4. recovered signer wasn't equal to the expected signer
    * 
    * Returns true if the expected signer did indeed approve the given expectedHash by signing an on-chain transaction.
    * 
    * @param userOp UserOp being validated.
    * @param parsedSignature Signature provided as the userOp.signature parameter (minus the prepended tx type byte). 
    *                        Expecting to receive fully signed serialized EVM transcaction here of type 0x00 (LEGACY)
    *                        or 0x02 (EIP1556).
    *                        For LEGACY tx type the "0x00" prefix has to be added manually while the EIP1559 tx type
    *                        already contains 0x02 prefix.
    * @param expectedSigner Expected EOA signer of the given userOp and the EVM transaction.
    */
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes memory parsedSignature,
        address expectedSigner
    ) internal view returns (uint256) {
        TxData memory decodedTx = decodeTx(parsedSignature);

        bytes32 expectedHash = UserOpLib.getUserOpHash(userOp, decodedTx.lowerBoundTimestamp, decodedTx.upperBoundTimestamp);
        if (decodedTx.appendedHash != expectedHash) {
            return SIG_VALIDATION_FAILED;
        }

        bytes memory signature = abi.encodePacked(decodedTx.r, decodedTx.s, decodedTx.v);
        if (!EcdsaLib.isValidSignature(expectedSigner, decodedTx.utxHash, signature)) {
            return SIG_VALIDATION_FAILED;
        }

        if (!MerkleProof.verify(decodedTx.proof, decodedTx.appendedHash, expectedHash)) {
            return SIG_VALIDATION_FAILED;
        }

        return _packValidationData(false, decodedTx.upperBoundTimestamp, decodedTx.lowerBoundTimestamp);
    }

    function validateSignatureForOwner(address expectedSigner, bytes32 hash, bytes memory parsedSignature) internal pure returns (bool) {
        TxData memory decodedTx = decodeTx(parsedSignature);
        if (decodedTx.appendedHash != hash) { return false; }
        return EcdsaLib.isValidSignature(
            expectedSigner,
            decodedTx.utxHash,
            abi.encodePacked(decodedTx.r, decodedTx.s, decodedTx.v)
        );
    }

    function decodeTx(bytes memory self) internal pure returns (TxData memory) {
        uint8 txType = uint8(self[0]); //first byte is tx type
        uint48 lowerBoundTimestamp = uint48(bytes6((self.slice(self.length - 2 * TIMESTAMP_BYTE_SIZE, TIMESTAMP_BYTE_SIZE))));
        uint48 upperBoundTimestamp = uint48(bytes6(self.slice(self.length - TIMESTAMP_BYTE_SIZE, TIMESTAMP_BYTE_SIZE)));
        uint8 proofItemsCount = uint8(self[self.length - 2 * TIMESTAMP_BYTE_SIZE - 1]);
        uint256 appendedDataLen = (uint256(proofItemsCount) * PROOF_ITEM_BYTE_SIZE + 1) + 2 * TIMESTAMP_BYTE_SIZE;
        bytes memory rlpEncodedTx = self.slice(1, self.length - appendedDataLen - 1);
        RLPDecoder.RLPItem memory parsedRlpEncodedTx = rlpEncodedTx.toRlpItem();
        RLPDecoder.RLPItem[] memory parsedRlpEncodedTxItems = parsedRlpEncodedTx.toList();
        TxParams memory params = extractParams(txType, parsedRlpEncodedTxItems);        

        return TxData(
            txType,
            _adjustV(params.v),
            params.r,
            params.s,
            calculateUnsignedTxHash(txType, rlpEncodedTx, parsedRlpEncodedTx.payloadLen(), params.v),
            extractAppendedHash(params.callData),
            extractProof(self, proofItemsCount),
            lowerBoundTimestamp,
            upperBoundTimestamp
        );
    }

    function extractParams(uint8 txType, RLPDecoder.RLPItem[] memory items) private pure returns (TxParams memory params) {
        uint8 dataPos;
        uint8 vPos;
        uint8 rPos;
        uint8 sPos;
        
        if (txType == LEGACY_TX_TYPE) {
            dataPos = 5;
            vPos = 6;
            rPos = 7;
            sPos = 8;
        } else if (txType == EIP1559_TX_TYPE) {
            dataPos = 7;
            vPos = 9;
            rPos = 10;
            sPos = 11;
        } else { revert("TxDecoder:: unsupported evm tx type"); }

        return TxParams(
            items[vPos].toUint(),
            bytes32(items[rPos].toUint()),
            bytes32(items[sPos].toUint()),
            items[dataPos].toBytes()
        );
    }

    function extractAppendedHash(bytes memory callData) private pure returns (bytes32 iTxHash) {
        if (callData.length < ITX_HASH_BYTE_SIZE) { revert("TxDecoder:: callData length too short"); }
        iTxHash = bytes32(callData.slice(callData.length - ITX_HASH_BYTE_SIZE, ITX_HASH_BYTE_SIZE));
    }

    function extractProof(bytes memory signedTx, uint8 proofItemsCount) private pure returns (bytes32[] memory proof) {
        proof = new bytes32[](proofItemsCount);
        uint256 pos = signedTx.length - 2 * TIMESTAMP_BYTE_SIZE - 1;
        for (proofItemsCount; proofItemsCount > 0; proofItemsCount--) {
            proof[proofItemsCount - 1] = bytes32(signedTx.slice(pos - PROOF_ITEM_BYTE_SIZE, PROOF_ITEM_BYTE_SIZE));
        }
    }

    function calculateUnsignedTxHash(uint8 txType, bytes memory rlpEncodedTx, uint256 rlpEncodedTxPayloadLen, uint256 v) private pure returns (bytes32 hash) {
        uint256 totalSignatureSize = RLP_ENCODED_R_S_BYTE_SIZE + v.encodeUint().length;
        uint256 totalPrefixSize = rlpEncodedTx.length - rlpEncodedTxPayloadLen;
        bytes memory rlpEncodedTxNoSigAndPrefix = rlpEncodedTx.slice(totalPrefixSize, rlpEncodedTx.length - totalSignatureSize - totalPrefixSize);
        if (txType == EIP1559_TX_TYPE) {
            return keccak256(abi.encodePacked(txType, prependRlpContentSize(rlpEncodedTxNoSigAndPrefix, "")));    
        } else if (txType == LEGACY_TX_TYPE) {
            if (v >= EIP_155_MIN_V_VALUE) {
                return keccak256(
                    prependRlpContentSize(
                        rlpEncodedTxNoSigAndPrefix,
                        abi.encodePacked(
                            uint256(_extractChainIdFromV(v)).encodeUint(),
                            uint256(0).encodeUint(),
                            uint256(0).encodeUint()
                        )    
                    ));
            } else {
                return keccak256(prependRlpContentSize(rlpEncodedTxNoSigAndPrefix, ""));
            }
        } else {
            revert("TxDecoder:: unsupported tx type");
        }
    }

    function prependRlpContentSize(bytes memory content, bytes memory extraData) public pure returns (bytes memory) {
        bytes memory combinedContent = abi.encodePacked(content, extraData);
        return abi.encodePacked(combinedContent.length.encodeLength(RLPDecoder.LIST_SHORT_START), combinedContent);
    }

    function _adjustV(uint256 v) internal pure returns (uint8) {
        if (v >= EIP_155_MIN_V_VALUE) {
            return uint8((v - 2 * _extractChainIdFromV(v) - 35) + 27);
        } else if (v <= 1) {
            return uint8(v + 27);
        } else {
            return uint8(v);
        }
    }

    function _extractChainIdFromV(uint256 v) internal pure returns (uint256 chainId) {
        chainId = (v - 35) / 2;
    }
}
