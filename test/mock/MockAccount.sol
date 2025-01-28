// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IAccount} from "account-abstraction/interfaces/IAccount.sol";
import {PackedUserOperation} from "account-abstraction/core/UserOperationLib.sol";
import {IValidator} from "erc7579/interfaces/IERC7579Module.sol";
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
        emit MockAccountValidateUserOp(userOp, userOpHash, missingAccountFunds);
        
        if (address(validator) != address(0)) {
            vd = validator.validateUserOp(userOp, userOpHash);    
        }
       
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