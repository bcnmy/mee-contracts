// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "../interfaces/ILayerZeroEndpoint.sol";

/**
 * @title Storage
 * @dev Contract to handle generic storage operations with cross-chain support
 */
contract Storage {
    error ReadFailed();
    error WriteFailed();
    error SlotNotInitialized();
    error InvalidDataLength();
    error InvalidCrossChainCall();
    error MessageFailed();

    // LayerZero endpoint interface
    ILayerZeroEndpoint public immutable endpoint;

    // Mapping of trusted remote Storage contracts on other chains
    mapping(uint16 => bytes) public trustedRemoteLookup;

    // Mapping to track initialized slots
    mapping(bytes32 => bool) private initializedSlots;

    // Mapping to track length of dynamic data
    mapping(bytes32 => uint256) private dynamicDataLength;

    event CrossChainStorageSet(uint16 srcChainId, bytes32 slot, bytes32 value);
    event RemoteStorageSet(uint16 dstChainId, bytes32 slot, bytes32 value);

    constructor(address _endpoint) {
        endpoint = ILayerZeroEndpoint(_endpoint);
    }

    /**
     * @dev Set trusted remote address for a chain
     */
    function setTrustedRemote(uint16 _chainId, bytes calldata _path) external {
        trustedRemoteLookup[_chainId] = _path;
    }

    /**
     * @dev Internal function to write a value to a specific storage slot
     */
    function _writeStorage(bytes32 slot, bytes32 value, bytes32 namespace) private {
        bytes32 namespacedSlot = getNamespacedSlot(namespace, slot);
        initializedSlots[namespacedSlot] = true;
        assembly {
            sstore(namespacedSlot, value)
        }
    }

    /**
     * @dev Write a value to a specific storage slot
     * @param slot The storage slot to write to
     * @param value The value to write
     */
    function writeStorage(bytes32 slot, bytes32 value, address account) external {
        bytes32 namespace = getNamespace(account, msg.sender);
        _writeStorage(slot, value, namespace);
    }

    /**
     * @dev Write value to storage on this and specified destination chains
     */
    function writeCrossChainStorage(
        uint16[] calldata dstChainIds,
        bytes32 slot,
        bytes32 value,
        bytes calldata adapterParams
    ) external payable {
        uint256 msgValuePerChain = dstChainIds.length > 0 ? msg.value / dstChainIds.length : 0;
        bool sourceChainIncluded = false;

        // Check if source chain is in the list and store locally if needed
        for (uint16 i = 0; i < dstChainIds.length; i++) {
            // if (dstChainIds[i] == endpoint.getChainId()) {
            //     sourceChainIncluded = true;
            //     _writeStorage(msg.sender, slot, value);
            //     break;
            // }
        }

        // Send to all other chains
        for (uint16 i = 0; i < dstChainIds.length; i++) {
            // Skip if it's the source chain
            // if (dstChainIds[i] == endpoint.getChainId()) {
            //     continue;
            // }

            bytes memory trustedRemote = trustedRemoteLookup[dstChainIds[i]];
            if (trustedRemote.length == 0) revert InvalidCrossChainCall();

            bytes memory payload = abi.encode(msg.sender, slot, value);

            endpoint.send{value: msgValuePerChain}(
                dstChainIds[i], trustedRemote, payload, payable(msg.sender), address(0), adapterParams
            );

            emit RemoteStorageSet(dstChainIds[i], slot, value);
        }
    }

    /**
     * @dev LayerZero receive function
     */
    function lzReceive(uint16 _srcChainId, bytes memory _srcAddress, uint64 _nonce, bytes memory _payload) external {
        // TODO: remove this. not needed because of msg.sender mixin
        // require(msg.sender == address(endpoint), "Invalid endpoint caller");

        // Verify source is trusted remote
        require(_srcAddress.length == trustedRemoteLookup[_srcChainId].length, "Invalid source length");
        require(keccak256(_srcAddress) == keccak256(trustedRemoteLookup[_srcChainId]), "Invalid source address");

        // Decode and store the value
        (address originalSender, bytes32 slot, bytes32 value) = abi.decode(_payload, (address, bytes32, bytes32));

        bytes32 namespace = getNamespace(originalSender, msg.sender);
        _writeStorage(slot, value, namespace);
        emit CrossChainStorageSet(_srcChainId, slot, value);
    }

    /**
     * @dev Read a value from a specific namespace and slot
     * @param namespace The namespace (typically a contract address)
     * @param slot The storage slot to read from
     * @return The value stored at the specified namespaced slot
     */
    function readStorage(bytes32 namespace, bytes32 slot) external view returns (bytes32) {
        bytes32 namespacedSlot = getNamespacedSlot(namespace, slot);
        if (!initializedSlots[namespacedSlot]) {
            revert SlotNotInitialized();
        }
        bytes32 value;
        assembly {
            value := sload(namespacedSlot)
        }
        return value;
    }

    /**
     * @dev Read dynamic data (arrays, strings) from storage
     * @param namespace The namespace
     * @param slot The base storage slot
     * @return The complete bytes array
     */
    function readDynamicStorage(bytes32 namespace, bytes32 slot) external view returns (bytes memory) {
        bytes32 namespacedSlot = getNamespacedSlot(namespace, slot);
        if (!initializedSlots[namespacedSlot]) {
            revert SlotNotInitialized();
        }

        uint256 length = dynamicDataLength[namespacedSlot];
        bytes memory result = new bytes(length);

        for (uint256 i = 0; i < (length + 31) / 32; i++) {
            bytes32 dataSlot = keccak256(abi.encodePacked(namespacedSlot, i));
            bytes32 value;
            assembly {
                value := sload(dataSlot)
            }

            // Copy the data to the result array
            assembly {
                // Calculate where to write in the result array
                let writeOffset := add(result, 32) // skip length prefix
                writeOffset := add(writeOffset, mul(i, 32))
                mstore(writeOffset, value)
            }
        }

        return result;
    }

    /**
     * @dev Write dynamic data (arrays, strings) to storage
     * @param slot The base storage slot
     * @param data The data to write
     */
    function writeDynamicStorage(bytes32 slot, bytes calldata data, address account) external {
        if (data.length == 0) revert InvalidDataLength();

        bytes32 namespace = getNamespace(account, msg.sender);
        bytes32 namespacedSlot = getNamespacedSlot(namespace, slot);
        initializedSlots[namespacedSlot] = true;
        dynamicDataLength[namespacedSlot] = data.length;

        // Write data in 32-byte chunks
        for (uint256 i = 0; i < (data.length + 31) / 32; i++) {
            bytes32 dataSlot = keccak256(abi.encodePacked(namespacedSlot, i));
            bytes32 value;

            // Copy the chunk of data to value
            assembly {
                // Calculate the position in calldata
                let dataOffset := add(data.offset, mul(i, 32))
                // Load 32 bytes or whatever is left
                value := calldataload(dataOffset)
            }

            assembly {
                sstore(dataSlot, value)
            }
        }
    }

    /**
     * @dev Generates a namespaced slot
     */
    function getNamespacedSlot(bytes32 namespace, bytes32 slot) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(namespace, slot));
    }

    function getNamespace(address account, address caller) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(account, caller));
    }

    /**
     * @dev Check if a slot has been initialized
     */
    function isSlotInitialized(bytes32 namespace, bytes32 slot) external view returns (bool) {
        bytes32 namespacedSlot = getNamespacedSlot(namespace, slot);
        return initializedSlots[namespacedSlot];
    }

    /**
     * @dev Get the length of dynamic data
     */
    function getDynamicDataLength(bytes32 namespace, bytes32 slot) external view returns (uint256) {
        bytes32 namespacedSlot = getNamespacedSlot(namespace, slot);
        return dynamicDataLength[namespacedSlot];
    }
}
