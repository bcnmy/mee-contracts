// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IAccount} from "account-abstraction/interfaces/IAccount.sol";
import {PackedUserOperation} from "account-abstraction/core/UserOperationLib.sol";

import {console2} from "forge-std/console2.sol";

contract MockAccount is IAccount {

    event MockAccountValidateUserOp(PackedUserOperation userOp, bytes32 userOpHash, uint256 missingAccountFunds);
    event MockAccountExecute(address to, uint256 value, bytes data);
    event MockAccountReceive(uint256 value);

    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 missingAccountFunds) external returns (uint256 vd) {
        emit MockAccountValidateUserOp(userOp, userOpHash, missingAccountFunds);
               
        address pm = address(uint160(bytes20(userOp.paymasterAndData[0:20])));
        bytes32 pmCodeHash;
        assembly {
            pmCodeHash := extcodehash(pm)
            if iszero(eq(pmCodeHash, 0x19e712abe2f3a5ec82e6d5b679f3925c981c9ec06b3fce5a777630bb751098af)) {
                vd := 0x01 // validation failed
            }
        }
        // else vd remains 0x00 (validation passed)
       //console2.logBytes32(pmCodeHash);
    }

    function execute(address to, uint256 value, bytes calldata data) external returns (bool success, bytes memory result) {
        emit MockAccountExecute(to, value, data);
        (success, result) = to.call{value: value}(data);
    }

    receive() external payable {
        emit MockAccountReceive(msg.value);
    }

}