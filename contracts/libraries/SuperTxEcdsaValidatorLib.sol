// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.27;

import "@account-abstraction/interfaces/PackedUserOperation.sol";
import "./fusion/PermitValidatorLib.sol";
import "./fusion/TxValidatorLib.sol";
import "./fusion/EcdsaValidatorLib.sol";
import "./fusion/UserOpValidatorLib.sol";
import "./util/BytesLib.sol";

library SuperTxEcdsaValidatorLib {
    using BytesLib for bytes;

    enum SuperSignatureType {
        OFF_CHAIN,
        ON_CHAIN,
        ERC20_PERMIT,
        USEROP
    }

    uint8 constant SIG_TYPE_OFF_CHAIN = 0x00;
    uint8 constant SIG_TYPE_ON_CHAIN = 0x01;
    uint8 constant SIG_TYPE_ERC20_PERMIT = 0x02;
    // ...leave space for other sig types: ERC-7683, Permit2, etc
    uint8 constant SIG_TYPE_USEROP = 0xff;

    struct SuperSignature {
        SuperSignatureType signatureType;
        bytes signature;
    }

    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, address owner)
        internal
        returns (uint256)
    {
        SuperSignature memory decodedSig = decodeSignature(userOp.signature);

        if (decodedSig.signatureType == SuperSignatureType.OFF_CHAIN) {
            return EcdsaValidatorLib.validateUserOp(userOp, decodedSig.signature, owner);
        } else if (decodedSig.signatureType == SuperSignatureType.ON_CHAIN) {
            return TxValidatorLib.validateUserOp(userOp, decodedSig.signature, owner);
        } else if (decodedSig.signatureType == SuperSignatureType.ERC20_PERMIT) {
            return PermitValidatorLib.validateUserOp(userOp, decodedSig.signature, owner);
        } else if (decodedSig.signatureType == SuperSignatureType.USEROP) {
            return UserOpValidatorLib.validateUserOp(userOpHash, decodedSig.signature, owner);
        } else {
            revert("SuperTxEcdsaValidatorLib:: invalid userOp sig type");
        }
    }

    function validateSignatureForOwner(address owner, bytes32 hash, bytes memory signature)
        internal
        pure
        returns (bool)
    {
        SuperSignature memory decodedSig = decodeSignature(signature);

        if (decodedSig.signatureType == SuperSignatureType.OFF_CHAIN) {
            return EcdsaValidatorLib.validateSignatureForOwner(owner, hash, decodedSig.signature);
        } else if (decodedSig.signatureType == SuperSignatureType.ON_CHAIN) {
            return TxValidatorLib.validateSignatureForOwner(owner, hash, decodedSig.signature);
        } else if (decodedSig.signatureType == SuperSignatureType.ERC20_PERMIT) {
            return PermitValidatorLib.validateSignatureForOwner(owner, hash, decodedSig.signature);
        } else if (decodedSig.signatureType == SuperSignatureType.USEROP) {
            return UserOpValidatorLib.validateSignatureForOwner(owner, hash, decodedSig.signature);
        } else {
            revert("SuperTxEcdsaValidatorLib:: invalid userOp sig type");
        }
    }

    function decodeSignature(bytes memory self) internal pure returns (SuperSignature memory) {
        bytes memory sig = self.slice(1, self.length - 1);
        if (uint8(self[0]) == SIG_TYPE_OFF_CHAIN) {
            return SuperSignature(SuperSignatureType.OFF_CHAIN, sig);
        } else if (uint8(self[0]) == SIG_TYPE_ON_CHAIN) {
            return SuperSignature(SuperSignatureType.ON_CHAIN, sig);
        } else if (uint8(self[0]) == SIG_TYPE_ERC20_PERMIT) {
            return SuperSignature(SuperSignatureType.ERC20_PERMIT, sig);
        } else if (uint8(self[0]) == SIG_TYPE_USEROP) {
            return SuperSignature(SuperSignatureType.USEROP, sig);
        } else {
            revert(
                "SuperTxEcdsaValidatorLib:: invalid sig type. Expected prefix 0x00 for off-chain, 0x01 for on-chain or 0x02 for erc20 permit itx hash signature or 0xff for normal userOp signature."
            );
        }
    }
}
