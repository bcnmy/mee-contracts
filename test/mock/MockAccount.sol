// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IAccount} from "account-abstraction/interfaces/IAccount.sol";
import {PackedUserOperation} from "account-abstraction/core/UserOperationLib.sol";

contract MockAccount is IAccount {

    event MockAccountValidateUserOp(PackedUserOperation userOp, bytes32 userOpHash, uint256 missingAccountFunds);
    event MockAccountExecute(address to, uint256 value, bytes data);
    event MockAccountReceive(uint256 value);

    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 missingAccountFunds) external returns (uint256 vd) {
        emit MockAccountValidateUserOp(userOp, userOpHash, missingAccountFunds);
        
        
/*       
        // this approach requires making node premium non immutable to ensure same bytecode for all pm's 
        // not dependent on the node premium size
        address pm = address(uint160(bytes20(userOp.paymasterAndData[0:20])));
         assembly {
            if eq(extcodehash(pm), 0x01) {
                vd := 0x01 // validation failed
            }
            // otherwise vd is 0x00 (validation passed)
        } */


        // another way

        // vd = 0x00 (validation passed)
    }

    function execute(address to, uint256 value, bytes calldata data) external returns (bool success, bytes memory result) {
        emit MockAccountExecute(to, value, data);
        (success, result) = to.call{value: value}(data);
    }

    receive() external payable {
        emit MockAccountReceive(msg.value);
    }

}