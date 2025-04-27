// SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

// NOTE: signature is omitted from the Delegation typehash
bytes32 constant DELEGATION_TYPEHASH = keccak256(
    "Delegation(address delegate,address delegator,bytes32 authority,Caveat[] caveats,uint256 salt)Caveat(address enforcer,bytes terms)"
);

bytes32 constant CAVEAT_TYPEHASH = keccak256("Caveat(address enforcer,bytes terms)");

/**
 * @title Delegation
 * @notice Struct representing a delegation to give a delegate authority to act on behalf of a delegator.
 * @dev `signature` is ignored during delegation hashing so it can be manipulated post signing.
 */
struct Delegation {
    address delegate;
    address delegator;
    bytes32 authority;
    Caveat[] caveats;
    uint256 salt;
    bytes signature;
}

/**
 * @title Caveat
 * @notice Struct representing a caveat to enforce on a delegation.
 * @dev `args` is ignored during caveat hashing so it can be manipulated post signing.
 */
struct Caveat {
    address enforcer;
    bytes terms;
    bytes args;
}

interface IDelegationManager {
    function getDomainHash() external view returns (bytes32);
}

library MMDelegationHelpers {
    /**
     * @notice Encodes and hashes a Delegation struct.
     * @dev The hash is used to verify the integrity of the Delegation.
     * @param _input The Delegation parameters to be hashed.
     * @return The keccak256 hash of the encoded Delegation packet.
     */
    function _getDelegationHash(Delegation memory _input) internal pure returns (bytes32) {
        bytes memory encoded_ = abi.encode(
            DELEGATION_TYPEHASH,
            _input.delegate,
            _input.delegator,
            _input.authority,
            _getCaveatArrayPacketHash(_input.caveats),
            _input.salt
        );
        return keccak256(encoded_);
    }

    /**
     * @notice Calculates the hash of an array of Caveats.
     * @dev The hash is used to verify the integrity of the Caveats.
     * @param _input The array of Caveats.
     * @return The keccak256 hash of the encoded Caveat array packet.
     */
    function _getCaveatArrayPacketHash(Caveat[] memory _input) internal pure returns (bytes32) {
        bytes32[] memory caveatPacketHashes_ = new bytes32[](_input.length);
        for (uint256 i = 0; i < _input.length; ++i) {
            caveatPacketHashes_[i] = _getCaveatPacketHash(_input[i]);
        }
        return keccak256(abi.encodePacked(caveatPacketHashes_));
    }

    /**
     * @notice Calculates the hash of a single Caveat.
     * @dev The hash is used to verify the integrity of the Caveat.
     * @param _input The Caveat data.
     * @return The keccak256 hash of the encoded Caveat packet.
     */
    function _getCaveatPacketHash(Caveat memory _input) internal pure returns (bytes32) {
        bytes memory encoded_ = abi.encode(CAVEAT_TYPEHASH, _input.enforcer, keccak256(_input.terms));
        return keccak256(encoded_);
    }
}