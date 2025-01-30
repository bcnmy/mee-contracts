// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IAccount} from "account-abstraction/interfaces/IAccount.sol";
import {PackedUserOperation} from "account-abstraction/core/UserOperationLib.sol";
import {IValidator} from "erc7579/interfaces/IERC7579Module.sol";
import {IStatelessValidator} from "node_modules/@rhinestone/module-bases/src/interfaces/IStatelessValidator.sol";
import {console2} from "forge-std/console2.sol";

contract MockAccount is IAccount {

    event MockAccountValidateUserOp(PackedUserOperation userOp, bytes32 userOpHash, uint256 missingAccountFunds);
    event MockAccountExecute(address to, uint256 value, bytes data);
    event MockAccountReceive(uint256 value);
    event MockAccountFallback(bytes callData, uint256 value);

    bytes4 internal constant EIP1271_SUCCESS = 0x1626ba7e;
    bytes4 internal constant EIP1271_FAILED = 0xFFFFFFFF;

    IValidator public validator;

    constructor(address _validator) {
        validator = IValidator(_validator);
    }

    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 missingAccountFunds) external returns (uint256 vd) {
        if (address(validator) != address(0)) {
            vd = validator.validateUserOp(userOp, userOpHash);    
        }
    }

    function isValidSignature_test(bytes32 hash, bytes calldata signature) external view returns (bool) {
        bytes4 res1271 = IValidator(address(validator)).isValidSignatureWithSender({
            sender: address(this), 
            hash: hash,
            data: signature
        });
        return res1271 == EIP1271_SUCCESS ? true : false;
    }

    function validateSignatureWithData(bytes32 signedHash, bytes calldata signature, bytes calldata signerData) external view returns (bool) {
        return IStatelessValidator(address(validator)).validateSignatureWithData({
                hash: signedHash,
                signature: signature,
                data: signerData
            });
    }

    function execute(address to, uint256 value, bytes calldata data) external returns (bool success, bytes memory result) {
        emit MockAccountExecute(to, value, data);
        (success, result) = to.call{value: value}(data);
    }

    receive() external payable {
        emit MockAccountReceive(msg.value);
    }

    fallback(bytes calldata callData) external payable returns (bytes memory) {
        emit MockAccountFallback(callData, msg.value);
    }

}