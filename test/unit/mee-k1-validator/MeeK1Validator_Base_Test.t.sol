// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import { Vm } from "forge-std/Test.sol";
import { PackedUserOperation } from "account-abstraction/core/UserOperationLib.sol";
import { EfficientHashLib } from "solady/utils/EfficientHashLib.sol";
import { BaseTest } from "../../Base.t.sol";
import { MEEUserOpHashLib } from "../../../contracts/lib/util/MEEUserOpHashLib.sol";
import { MockAccount } from "../../mock/MockAccount.sol";
import { CopyUserOpLib } from "../../util/CopyUserOpLib.sol";
import { HashLib, SUPER_TX_MEE_USER_OP_ARRAY_TYPEHASH } from "contracts/lib/util/HashLib.sol";
import "contracts/types/Constants.sol";

contract MeeK1Validator_Base_Test is BaseTest {
    using CopyUserOpLib for PackedUserOperation;
    using EfficientHashLib for *;

    Vm.Wallet wallet;
    MockAccount mockAccount;
    uint256 valueToSet;

    function setUp() public virtual override {
        super.setUp();
        wallet = createAndFundWallet("wallet", 5 ether);
        mockAccount = deployMockAccount({ validator: address(k1MeeValidator), handler: address(0) });
        vm.prank(address(mockAccount));
        k1MeeValidator.transferOwnership(wallet.addr);
        valueToSet = MEE_NODE_HEX;
    }

    // ==== MEE USER OP UTILS ====

    /**
     * @notice Builds a basic MEE user operation with a given calldata
     * @param callData The calldata to execute
     * @param account The account to execute the calldata on
     * @param userOpSigner The signer of the user operation
     * @return userOp The built user operation
     */
    /* solhint-disable foundry-test-functions */
    function buildBasicMEEUserOpWithCalldata(
        bytes memory callData,
        address account,
        Vm.Wallet memory userOpSigner
    )
        public
        view
        returns (PackedUserOperation memory)
    {
        PackedUserOperation memory userOp = buildUserOpWithCalldata({
            account: account,
            callData: callData,
            wallet: userOpSigner,
            preVerificationGasLimit: 3e5,
            verificationGasLimit: 500e3,
            callGasLimit: 3e6
        });

        userOp = _makeMEEUserOp({
            userOp: userOp,
            pmValidationGasLimit: 40_000,
            pmPostOpGasLimit: 50_000,
            _wallet: userOpSigner,
            sigType: bytes4(0)
        });

        return userOp;
    }

    /**
     * @notice Internal function to make a MEE user operation out of a AA user operation
     * adds appropriate paymaster and data to the user operation
     * and adds MEE type prefix to the signature
     *
     * @param userOp The user operation to make MEE
     * @param pmValidationGasLimit The validation gas limit for the PM
     * @param pmPostOpGasLimit The post-op gas limit for the PM
     * @param _wallet The wallet to sign the user operation
     * @param sigType The signature type
     * @return userOp The built user operation
     */
    function _makeMEEUserOp(
        PackedUserOperation memory userOp,
        uint128 pmValidationGasLimit,
        uint128 pmPostOpGasLimit,
        Vm.Wallet memory _wallet,
        bytes4 sigType
    )
        internal
        view
        returns (PackedUserOperation memory)
    {
        // refund mode = user
        // premium mode = percentage premium
        userOp.paymasterAndData = abi.encodePacked(
            address(NODE_PAYMASTER),
            pmValidationGasLimit, // pm validation gas limit
            pmPostOpGasLimit, // pm post-op gas limit
            NODE_PM_MODE_USER,
            NODE_PM_PREMIUM_PERCENT,
            uint192(1_700_000)
        );

        userOp.signature = signUserOp(_wallet, userOp);
        if (sigType != bytes4(0)) {
            userOp.signature = abi.encodePacked(sigType, userOp.signature);
        }
        return userOp;
    }

    /**
     * @notice Creates an array of identical user operations with incremented nonces
     * @param userOp The user operation to clone
     * @param userOpSigner The signer of the user operation
     * @param numOfClones The number of clones to create
     * @return userOps The array of user operations
     */
    function _cloneUserOpToAnArray(
        PackedUserOperation memory userOp,
        Vm.Wallet memory userOpSigner,
        uint256 numOfClones
    )
        internal
        view
        returns (PackedUserOperation[] memory)
    {
        PackedUserOperation[] memory userOps = new PackedUserOperation[](numOfClones + 1);
        userOps[0] = userOp;
        for (uint256 i = 0; i < numOfClones; i++) {
            assertEq(userOps[i].nonce, i);
            userOps[i + 1] = _duplicateUserOpAndIncrementNonce(userOps[i], userOpSigner);
        }
        return userOps;
    }

    /**
     * @notice Helper function to duplicate a user operation and increment the nonce
     * @param userOp The user operation to duplicate
     * @param userOpSigner The signer of the user operation
     * @return userOp The duplicated user operation
     */
    function _duplicateUserOpAndIncrementNonce(
        PackedUserOperation memory userOp,
        Vm.Wallet memory userOpSigner
    )
        internal
        view
        returns (PackedUserOperation memory)
    {
        PackedUserOperation memory newUserOp = userOp.deepCopy();
        newUserOp.nonce = userOp.nonce + 1;
        newUserOp.signature = signUserOp(userOpSigner, newUserOp);
        return newUserOp;
    }

    /**
     * @notice Hashes a super tx with only MeeUserOps as entries
     * @param superTxUserOps The array of user operations to hash
     * @param smartAccount The smart account to hash the super tx for
     * @param lowerBoundTimestamp The lower bound timestamp
     * @param upperBoundTimestamp The upper bound timestamp
     * @return stxStructTypeHash The type hash of the super tx
     * @return stxEip712HashToSign The EIP-712 hash of the SuperTx(MeeUserOp[] meeUserOps) to sign
     */
    function _hashPureMeeUserOpsStx(
        PackedUserOperation[] memory superTxUserOps,
        address smartAccount,
        uint48 lowerBoundTimestamp,
        uint48 upperBoundTimestamp
    )
        internal
        view
        returns (bytes32 stxStructTypeHash, bytes32 stxEip712HashToSign)
    {
        // since in this function stx is built of MeeUserOps only, we treat it as an array of MeeUserOps structs
        // SuperTx(MeeUserOp[] meeUserOps)
        stxStructTypeHash = SUPER_TX_MEE_USER_OP_ARRAY_TYPEHASH;
        // and thus we also have to hash the encoded data as an array of MeeUserOps structs
        // encode data for an array of structs is "keccak256 hash of the concatenated encodeData
        // of their contents" as per eip-712
        bytes memory encodedData;
        bytes32[] memory a = EfficientHashLib.malloc(superTxUserOps.length);
        for (uint256 i; i < superTxUserOps.length; ++i) {
            bytes32 userOpHash = ENTRYPOINT.getUserOpHash(superTxUserOps[i]);
            bytes32 meeUserOpEip712Hash =
                MEEUserOpHashLib.getMeeUserOpEip712Hash(userOpHash, lowerBoundTimestamp, upperBoundTimestamp);
            a.set(i, meeUserOpEip712Hash);
        }
        encodedData = abi.encodePacked(a.hash());
        // now has the struct as per eip-712
        bytes32 structHash = keccak256(abi.encodePacked(stxStructTypeHash, encodedData));
        // and make the final hash to sign with the domain separator
        stxEip712HashToSign = HashLib.hashTypedDataForAccount(smartAccount, structHash);
    }

    /**
     * @notice Hashes every user operation in the array with the given lower and upper bound timestamps
     * @param userOps The array of user operations to hash
     * @param lowerBoundTimestamp The lower bound timestamp
     * @param upperBoundTimestamp The upper bound timestamp
     * @return itemHashes The array of hashed data structs: MEEUserOp(bytes32 userOpHash,uint256
     * lowerBoundTimestamp,uint256 upperBoundTimestamp)
     */
    function _eip712HashMeeUserOps(
        PackedUserOperation[] memory userOps,
        uint48 lowerBoundTimestamp,
        uint48 upperBoundTimestamp
    )
        internal
        view
        returns (bytes32[] memory)
    {
        bytes32[] memory itemHashes = new bytes32[](userOps.length);
        for (uint256 i; i < userOps.length; ++i) {
            bytes32 userOpHash = ENTRYPOINT.getUserOpHash(userOps[i]);
            itemHashes[i] = MEEUserOpHashLib.getMeeUserOpEip712Hash(userOpHash, lowerBoundTimestamp, upperBoundTimestamp);
        }
        return itemHashes;
    }

    // == Merkle tree helpers ==

    function _buildLeavesOutOfUserOps(
        PackedUserOperation[] memory userOps,
        uint48 lowerBoundTimestamp,
        uint48 upperBoundTimestamp
    )
        internal
        view
        returns (bytes32[] memory)
    {
        bytes32[] memory leaves = new bytes32[](userOps.length);
        for (uint256 i = 0; i < userOps.length; i++) {
            bytes32 userOpHash = ENTRYPOINT.getUserOpHash(userOps[i]);
            leaves[i] = MEEUserOpHashLib.getMEEUserOpHash(userOpHash, lowerBoundTimestamp, upperBoundTimestamp);
        }
        return leaves;
    }

    // ==== DYNAMIC STRUCT DEFINITION HELPERS ====

    /**
     * @notice Builds a dynamic SuperTx struct definition string as per EIP-712
     * @dev Format: SuperTx(Type1 entry1,Type2 entry2,...TypeN entryN)‖Type1Definition‖Type2Definition‖...
     * @param entryTypeNames Array of entry type names in order (e.g., ["MeeUserOp", "EntryTypeA", "MeeUserOp"])
     * @param meeUserOpDefinition The MeeUserOp type definition string
     * @param otherTypeDefinitions Array of other type definitions (e.g., EntryTypeA, EntryTypeB, EntryTypeC definitions)
     * @return dynamicStructDefinition The complete EIP-712 struct definition string
     */
    function _buildDynamicStxStructDefinition(
        string[] memory entryTypeNames,
        string memory meeUserOpDefinition,
        string[] memory otherTypeDefinitions
    )
        internal
        pure
        returns (string memory dynamicStructDefinition)
    {
        // Start building: SuperTx(
        dynamicStructDefinition = "SuperTx(";

        // Add each entry with format "Type entryN,"
        for (uint256 i = 0; i < entryTypeNames.length; i++) {
            dynamicStructDefinition =
                string.concat(dynamicStructDefinition, entryTypeNames[i], " entry", _uintToString(i + 1));
            if (i < entryTypeNames.length - 1) {
                dynamicStructDefinition = string.concat(dynamicStructDefinition, ",");
            }
        }

        // Close the SuperTx definition
        dynamicStructDefinition = string.concat(dynamicStructDefinition, ")");

        // ==== SORT AND APPEND TYPE DEFINITIONS ====
        // As per EIP-712: "the set of referenced struct types is collected, sorted by name and appended"
        // Example: Transaction(Person from,Person to,Asset tx)Asset(address token,uint256 amount)Person(address
        // wallet,string name)

        // Check if MeeUserOp is present in the entries
        bool hasMeeUserOp = false;
        for (uint256 i = 0; i < entryTypeNames.length; i++) {
            if (keccak256(bytes(entryTypeNames[i])) == keccak256(bytes("MeeUserOp"))) {
                hasMeeUserOp = true;
                break;
            }
        }

        // Collect all type definitions that need to be appended
        uint256 totalTypeDefs = otherTypeDefinitions.length + (hasMeeUserOp ? 1 : 0);
        string[] memory allTypeDefinitions = new string[](totalTypeDefs);

        uint256 idx = 0;
        if (hasMeeUserOp) {
            allTypeDefinitions[idx++] = meeUserOpDefinition;
        }
        for (uint256 i = 0; i < otherTypeDefinitions.length; i++) {
            allTypeDefinitions[idx++] = otherTypeDefinitions[i];
        }

        string[] memory allTypeDefinitionsSorted = new string[](totalTypeDefs);
        // Sort alphabetically by extracting type names and comparing
        allTypeDefinitionsSorted = _sortTypeDefinitionsAlphabetically(allTypeDefinitions);

        // Append sorted type definitions
        for (uint256 i = 0; i < allTypeDefinitionsSorted.length; i++) {
            dynamicStructDefinition = string.concat(dynamicStructDefinition, allTypeDefinitionsSorted[i]);
        }
    }

    /**
     * @notice Sorts type definitions alphabetically by their type name (before the opening parenthesis)
     * @dev Uses bubble sort for simplicity in test code. Type name is extracted from "TypeName(...)" format
     * @param typeDefinitions Array of type definition strings
     * @return sorted Alphabetically sorted array of type definitions
     */
    function _sortTypeDefinitionsAlphabetically(string[] memory typeDefinitions)
        internal
        pure
        returns (string[] memory sorted)
    {
        sorted = typeDefinitions;
        uint256 n = sorted.length;

        // Bubble sort - sufficient for small arrays in tests
        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = 0; j < n - i - 1; j++) {
                // Extract type names (everything before '(')
                string memory typeName1 = _extractTypeName(sorted[j]);
                string memory typeName2 = _extractTypeName(sorted[j + 1]);

                // Compare alphabetically
                if (_compareStrings(typeName1, typeName2) > 0) {
                    // Swap
                    string memory temp = sorted[j];
                    sorted[j] = sorted[j + 1];
                    sorted[j + 1] = temp;
                }
            }
        }
    }

    /**
     * @notice Extracts the type name from a type definition string (text before '(')
     * @param typeDefinition The type definition string (e.g., "TypeName(field1,field2)")
     * @return typeName The extracted type name (e.g., "TypeName")
     */
    function _extractTypeName(string memory typeDefinition) internal pure returns (string memory typeName) {
        bytes memory defBytes = bytes(typeDefinition);
        uint256 parenIndex = 0;

        // Find the position of '('
        for (uint256 i = 0; i < defBytes.length; i++) {
            if (defBytes[i] == "(") {
                parenIndex = i;
                break;
            }
        }

        // Extract substring before '('
        bytes memory nameBytes = new bytes(parenIndex);
        for (uint256 i = 0; i < parenIndex; i++) {
            nameBytes[i] = defBytes[i];
        }

        typeName = string(nameBytes);
    }

    /**
     * @notice Compares two strings lexicographically
     * @param a First string
     * @param b Second string
     * @return result -1 if a < b, 0 if a == b, 1 if a > b
     */
    function _compareStrings(string memory a, string memory b) internal pure returns (int256 result) {
        bytes memory aBytes = bytes(a);
        bytes memory bBytes = bytes(b);

        uint256 minLength = aBytes.length < bBytes.length ? aBytes.length : bBytes.length;

        for (uint256 i = 0; i < minLength; i++) {
            if (uint8(aBytes[i]) < uint8(bBytes[i])) {
                return -1;
            } else if (uint8(aBytes[i]) > uint8(bBytes[i])) {
                return 1;
            }
        }

        // If all compared characters are equal, shorter string comes first
        if (aBytes.length < bBytes.length) {
            return -1;
        } else if (aBytes.length > bBytes.length) {
            return 1;
        } else {
            return 0;
        }
    }

    /**
     * @notice Helper to convert uint to string
     * @param value The uint value to convert
     * @return The string representation
     */
    function _uintToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
