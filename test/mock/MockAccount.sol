// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IAccount} from "account-abstraction/interfaces/IAccount.sol";
import {PackedUserOperation} from "account-abstraction/core/UserOperationLib.sol";
import {IValidator} from "erc7579/interfaces/IERC7579Module.sol";
import {IStatelessValidator} from "node_modules/@rhinestone/module-bases/src/interfaces/IStatelessValidator.sol";
import {EIP1271_SUCCESS, EIP1271_FAILED} from "contracts/types/Constants.sol";
import {console2} from "forge-std/console2.sol";

contract MockAccount is IAccount {

    event MockAccountValidateUserOp(PackedUserOperation userOp, bytes32 userOpHash, uint256 missingAccountFunds);
    event MockAccountExecute(address to, uint256 value, bytes data);
    event MockAccountReceive(uint256 value);
    event MockAccountFallback(bytes callData, uint256 value);

    IValidator public validator;

    constructor(address _validator) {
        validator = IValidator(_validator);
    }

    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 missingAccountFunds) external returns (uint256 vd) {
        if (address(validator) != address(0)) {
            vd = validator.validateUserOp(userOp, userOpHash);    
        }
        assembly {
            if missingAccountFunds {
                // Ignore failure (it's EntryPoint's job to verify, not the account's).
                pop(call(gas(), caller(), missingAccountFunds, codesize(), 0x00, codesize(), 0x00))
            }
        }
        // if validator is not set, return 0 = success
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        return IValidator(address(validator)).isValidSignatureWithSender({
            sender: msg.sender, 
            hash: hash,
            data: signature
        });
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

    function eip712Domain()
        public
        view
        returns (
            bytes1 fields,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            bytes32 salt,
            uint256[] memory extensions
        )
    {
        return (
            bytes1(0),
            "MockAccount",
            "1.0",
            block.chainid,
            address(this),
            bytes32(0),
            new uint256[](0)
        );
    }
}