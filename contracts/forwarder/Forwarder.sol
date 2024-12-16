// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/**
 * @title EtherForwarder
 * @dev A contract that forwards received Ether to a specified address
 */
contract EtherForwarder {
    error ZeroAddress();
    error ForwardFailed();
    error UseForwardFunction();

    /**
     * @dev Forwards the received Ether to the specified destination address
     * @param destination The address to forward the Ether to
     */
    function forward(address destination) external payable {
        if (destination == address(0)) revert ZeroAddress();

        // Forward the Ether using assembly
        bool success;
        assembly {
            // Gas-efficient way to forward ETH
            success :=
                call(
                    gas(), // Forward all available gas
                    destination, // Destination address
                    callvalue(), // Amount of ETH to send
                    0, // No data to send
                    0, // No data size
                    0, // No data to receive
                    0 // No data size to receive
                )
        }

        if (!success) revert ForwardFailed();
    }

    /**
     * @dev Prevents accidental Ether transfers without a destination
     */
    receive() external payable {
        revert("Use forward() function to send Ether");
    }

    /**
     * @dev Prevents accidental Ether transfers without a destination
     */
    fallback() external payable {
        revert("Use forward() function to send Ether");
    }
}
