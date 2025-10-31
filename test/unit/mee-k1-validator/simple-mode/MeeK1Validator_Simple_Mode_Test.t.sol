// SPDX-License-Identifier: MIT

pragma solidity ^0.8.27;

import { Vm, console2 } from "forge-std/Test.sol";
import { PackedUserOperation } from "account-abstraction/core/UserOperationLib.sol";
import { MeeK1Validator_Base_Test } from "../MeeK1Validator_Base_Test.t.sol";
import { MockTarget } from "../../../mock/MockTarget.sol";
import { CopyUserOpLib } from "../../../util/CopyUserOpLib.sol";
import { HashLib } from "contracts/lib/util/HashLib.sol";
import { MEEUserOpHashLib } from "contracts/lib/util/MEEUserOpHashLib.sol";
import "contracts/types/Constants.sol";

contract MeeK1Validator_Simple_Mode_Test is MeeK1Validator_Base_Test {
    using CopyUserOpLib for PackedUserOperation;

    function setUp() public virtual override {
        super.setUp();
    }

    // tests simple mode, validateUserOp, where the super tx entries are MEE user operations only
    // SuperTx
    function test_simple_mode_ValidateUserOp_with_MeeUserOps_only_as_entries_success(uint256 numOfClones)
        public
        returns (PackedUserOperation[] memory)
    {
        numOfClones = bound(numOfClones, 1, 25);
        uint256 counterBefore = mockTarget.counter();
        bytes memory innerCallData = abi.encodeWithSelector(MockTarget.incrementCounter.selector);
        PackedUserOperation memory userOp = buildBasicMEEUserOpWithCalldata({
            callData: abi.encodeWithSelector(mockAccount.execute.selector, address(mockTarget), uint256(0), innerCallData),
            account: address(mockAccount),
            userOpSigner: wallet
        });

        PackedUserOperation[] memory userOps = _cloneUserOpToAnArray(userOp, wallet, numOfClones);

        userOps = _makeSimpleSuperTxWithMeeUserOpsOnlyAsEntries(userOps, wallet, address(mockAccount));

        vm.startPrank(MEE_NODE_EXECUTOR_EOA, MEE_NODE_EXECUTOR_EOA);
        ENTRYPOINT.handleOps(userOps, payable(MEE_NODE_ADDRESS));
        vm.stopPrank();

        assertEq(mockTarget.counter(), counterBefore + userOps.length);
        return userOps;
    }

    // test simple mode, validateUserOp, where the super tx entries are of mixed types
    function test_simple_mode_ValidateUserOp_with_MixedTypes_success(uint256 numOfClones) public {
        numOfClones = bound(numOfClones, 1, 9);

        uint256 counterBefore = mockTarget.counter();

        // prepare user ops
        bytes memory innerCallData = abi.encodeWithSelector(MockTarget.incrementCounter.selector);
        PackedUserOperation memory userOp = buildBasicMEEUserOpWithCalldata({
            callData: abi.encodeWithSelector(mockAccount.execute.selector, address(mockTarget), uint256(0), innerCallData),
            account: address(mockAccount),
            userOpSigner: wallet
        });
        PackedUserOperation[] memory userOps = _cloneUserOpToAnArray(userOp, wallet, numOfClones);

        (PackedUserOperation[] memory superTxUserOps, NonUserOpEntryData[] memory nonUserOpEntryDatas) =
            _makeSimpleSuperTxWithMixedTypes(userOps, wallet, address(mockAccount));

        // make sure userOps are handled correctly
        // sending them one by one to emulate the real world scenario
        // where most handleOps calls are made with just one userOp in the array
        vm.startPrank(MEE_NODE_EXECUTOR_EOA, MEE_NODE_EXECUTOR_EOA);
        for (uint256 i = 0; i < superTxUserOps.length; i++) {
            PackedUserOperation[] memory userOpToHandleAsArray = new PackedUserOperation[](1);
            userOpToHandleAsArray[0] = superTxUserOps[i];
            ENTRYPOINT.handleOps(userOpToHandleAsArray, payable(MEE_NODE_ADDRESS));
        }
        vm.stopPrank();
        assertEq(mockTarget.counter(), counterBefore + userOps.length);

        // Now validate the rest of the entries via
        // - validateSignatureWithData
        // - isValidSignature (no 7739 flow needed for simple mode)
        for (uint256 i; i < nonUserOpEntryDatas.length; i++) {
            assertTrue(
                mockAccount.validateSignatureWithData(
                    nonUserOpEntryDatas[i].entryHash,
                    nonUserOpEntryDatas[i].packedSignatureForEntry,
                    abi.encodePacked(wallet.addr)
                )
            );

            assertTrue(
                mockAccount.isValidSignature(
                    nonUserOpEntryDatas[i].entryHash, nonUserOpEntryDatas[i].packedSignatureForEntry
                ) == EIP1271_SUCCESS
            );
        }
    }

    // ==== SIMPLE SUPER TX UTILS ====

    /**
     * @notice Makes a simple superTx with MeeUserOps only as entries
     * @param userOps The user operations to include in the superTx
     * @param superTxSigner The signer of the superTx
     * @param smartAccount The smart account address
     * @return superTxUserOps The superTx user operations
     */
    function _makeSimpleSuperTxWithMeeUserOpsOnlyAsEntries(
        PackedUserOperation[] memory userOps,
        Vm.Wallet memory superTxSigner,
        address smartAccount
    )
        internal
        view
        returns (PackedUserOperation[] memory)
    {
        uint48 lowerBoundTimestamp = uint48(block.timestamp);
        uint48 upperBoundTimestamp = uint48(block.timestamp + 1000);
        bytes32[] memory stxItemHashes = _eip712HashMeeUserOps(userOps, lowerBoundTimestamp, upperBoundTimestamp);

        (bytes32 stxStructTypeHash, bytes32 stxEip712HashToSign) =
            _hashPureMeeUserOpsStx(userOps, smartAccount, lowerBoundTimestamp, upperBoundTimestamp);

        // eip-712 sign the stx struct
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(superTxSigner.privateKey, stxEip712HashToSign);
        bytes memory superTxHashSignature = abi.encodePacked(r, s, v);

        PackedUserOperation[] memory superTxUserOps = new PackedUserOperation[](userOps.length);
        for (uint256 i; i < userOps.length; ++i) {
            superTxUserOps[i] = userOps[i].deepCopy();

            bytes memory signature = abi.encodePacked(
                SIG_TYPE_SIMPLE,
                abi.encode(
                    stxStructTypeHash,
                    i,
                    stxItemHashes,
                    superTxHashSignature,
                    uint256((uint256(lowerBoundTimestamp) << 128) | uint256(upperBoundTimestamp))
                )
            );
            superTxUserOps[i].signature = signature;
        }
        return superTxUserOps;
    }

    struct NonUserOpEntryData {
        bytes32 entryHash;
        uint256 entryIndex;
        bytes packedSignatureForEntry;
    }

    enum EntryType {
        MEE_USER_OP,
        ENTRY_TYPE_A,
        ENTRY_TYPE_B,
        ENTRY_TYPE_C
    }

    struct StxEntryData {
        uint256 entryIndex;
        EntryType entryType;
    }

    /**
     * @notice Makes a simple superTx with mixed types
     * Dynamically creates the superTx struct and according typehash
     * @param userOps The user operations to include in the superTx
     * @param superTxSigner The signer of the superTx
     * @param smartAccount The smart account address
     * @return superTxUserOps The superTx user operations
     * @return nonUserOpEntryDatas The non-userOp entry data
     */
    function _makeSimpleSuperTxWithMixedTypes(
        PackedUserOperation[] memory userOps,
        Vm.Wallet memory superTxSigner,
        address smartAccount
    )
        internal
        view
        returns (PackedUserOperation[] memory, NonUserOpEntryData[] memory)
    {
        uint48 lowerBoundTimestamp = uint48(block.timestamp);
        uint48 upperBoundTimestamp = uint48(block.timestamp + 1000);

        uint256 userOpsLength = userOps.length;
        uint256 everyNonUserOpEntryTypeEntriesCount = userOpsLength;
        uint256 otherEntriesLength = userOpsLength * 3;
        StxEntryData[] memory stxLayout;
        NonUserOpEntryData[] memory nonUserOpEntryDatas = new NonUserOpEntryData[](otherEntriesLength);
        string memory dynamicStxStructDefinition;

        //create other entries
        string memory entryTypeADefinition = "EntryTypeA(uint256 foo,bytes32 bar, address baz)";
        string memory entryTypeBDefinition = "EntryTypeB(string qux,address corge)";
        string memory entryTypeCDefinition = "EntryTypeC(uint128[] waldo,bytes16 grault)";
        bytes32 entryTypeATypeHash = keccak256(bytes(entryTypeADefinition));
        bytes32 entryTypeBTypeHash = keccak256(bytes(entryTypeBDefinition));
        bytes32 entryTypeCTypeHash = keccak256(bytes(entryTypeCDefinition));

        // ==== STEP 1: Fill stxLayout array with mixed entry types ====
        // Strategy: Distribute entries evenly - interleave UserOps with other entry types
        // Pattern: UserOp, EntryTypeA, UserOp, EntryTypeB, UserOp, EntryTypeC, etc.

        uint256 totalEntries = userOpsLength + otherEntriesLength;
        stxLayout = new StxEntryData[](totalEntries);

        uint256 userOpIndex = 0;
        uint256 entryAIndex = 0;
        uint256 entryBIndex = 0;
        uint256 entryCIndex = 0;

        // Fill layout: interleave UserOps with other entry types in round-robin fashion
        // Pattern: UserOp, EntryTypeA, UserOp, EntryTypeB, UserOp, EntryTypeC, etc.
        for (uint256 i = 0; i < totalEntries; i++) {
            if (i % 2 == 0) {
                // Even positions: UserOp (if available)
                if (userOpIndex < userOpsLength) {
                    stxLayout[i] = StxEntryData({ entryIndex: i, entryType: EntryType.MEE_USER_OP });
                    userOpIndex++;
                } else {
                    // No more UserOps, fill with remaining entry types
                    if (entryAIndex < everyNonUserOpEntryTypeEntriesCount) {
                        stxLayout[i] = StxEntryData({ entryIndex: i, entryType: EntryType.ENTRY_TYPE_A });
                        entryAIndex++;
                    } else if (entryBIndex < everyNonUserOpEntryTypeEntriesCount) {
                        stxLayout[i] = StxEntryData({ entryIndex: i, entryType: EntryType.ENTRY_TYPE_B });
                        entryBIndex++;
                    } else if (entryCIndex < everyNonUserOpEntryTypeEntriesCount) {
                        stxLayout[i] = StxEntryData({ entryIndex: i, entryType: EntryType.ENTRY_TYPE_C });
                        entryCIndex++;
                    }
                }
            } else {
                // Odd positions: Cycle through EntryTypeA, B, C
                uint256 cycleIndex = (i - 1) / 2; // Convert to 0-based cycle index
                if (cycleIndex % 3 == 0 && entryAIndex < everyNonUserOpEntryTypeEntriesCount) {
                    stxLayout[i] = StxEntryData({ entryIndex: i, entryType: EntryType.ENTRY_TYPE_A });
                    entryAIndex++;
                } else if (cycleIndex % 3 == 1 && entryBIndex < everyNonUserOpEntryTypeEntriesCount) {
                    stxLayout[i] = StxEntryData({ entryIndex: i, entryType: EntryType.ENTRY_TYPE_B });
                    entryBIndex++;
                } else if (entryCIndex < everyNonUserOpEntryTypeEntriesCount) {
                    stxLayout[i] = StxEntryData({ entryIndex: i, entryType: EntryType.ENTRY_TYPE_C });
                    entryCIndex++;
                } else if (entryAIndex < everyNonUserOpEntryTypeEntriesCount) {
                    stxLayout[i] = StxEntryData({ entryIndex: i, entryType: EntryType.ENTRY_TYPE_A });
                    entryAIndex++;
                } else if (entryBIndex < everyNonUserOpEntryTypeEntriesCount) {
                    stxLayout[i] = StxEntryData({ entryIndex: i, entryType: EntryType.ENTRY_TYPE_B });
                    entryBIndex++;
                } else if (userOpIndex < userOpsLength) {
                    stxLayout[i] = StxEntryData({ entryIndex: i, entryType: EntryType.MEE_USER_OP });
                    userOpIndex++;
                }
            }
        }

        // ==== STEP 2: Create all item hashes (both UserOps and other entry types) ====
        // Allocate array for all entry hashes in the order they appear in stxLayout
        bytes32[] memory stxItemHashes = new bytes32[](totalEntries);

        // Storage for non-UserOp entry items (needed for EIP-712 hashing)
        bytes[] memory entryAItems = new bytes[](everyNonUserOpEntryTypeEntriesCount);
        bytes[] memory entryBItems = new bytes[](everyNonUserOpEntryTypeEntriesCount);
        bytes[] memory entryCItems = new bytes[](everyNonUserOpEntryTypeEntriesCount);

        uint256 entryACounter = 0;
        uint256 entryBCounter = 0;
        uint256 entryCCounter = 0;
        uint256 userOpCounter = 0;
        uint256 nonUserOpDataCounter = 0;

        // Process each entry in stxLayout and generate its hash
        for (uint256 i = 0; i < totalEntries; i++) {
            if (stxLayout[i].entryType == EntryType.MEE_USER_OP) {
                // Hash MeeUserOp as: hashStruct(MeeUserOp) = keccak256(MEE_USER_OP_TYPEHASH ‖ userOpHash ‖ lowerBound
                // ‖ upperBound)
                bytes32 userOpHash = ENTRYPOINT.getUserOpHash(userOps[userOpCounter]);
                stxItemHashes[i] =
                    MEEUserOpHashLib.getMeeUserOpEip712Hash(userOpHash, lowerBoundTimestamp, upperBoundTimestamp);
                userOpCounter++;
            } else if (stxLayout[i].entryType == EntryType.ENTRY_TYPE_A) {
                // Create unique EntryTypeA: EntryTypeA(uint256 foo, bytes32 bar, address baz)
                uint256 foo = uint256(keccak256(abi.encode("entryA", entryACounter)));
                bytes32 bar = keccak256(abi.encode("bar", entryACounter));
                address baz = address(uint160(uint256(keccak256(abi.encode("baz", entryACounter)))));

                // Store the encoded item for later reference
                entryAItems[entryACounter] = abi.encode(foo, bar, baz);

                // Hash as per EIP-712: hashStruct(s) = keccak256(typeHash ‖ encodeData(s))
                // encodeData for EntryTypeA = encode(foo, bar, baz)
                stxItemHashes[i] = keccak256(abi.encodePacked(entryTypeATypeHash, abi.encode(foo, bar, baz)));
                entryACounter++;
            } else if (stxLayout[i].entryType == EntryType.ENTRY_TYPE_B) {
                // Create unique EntryTypeB: EntryTypeB(string qux, address corge)
                string memory qux = string(abi.encodePacked("qux_", _uintToString(entryBCounter)));
                address corge = address(uint160(uint256(keccak256(abi.encode("corge", entryBCounter)))));

                // Store the encoded item
                entryBItems[entryBCounter] = abi.encode(keccak256(bytes(qux)), corge);

                // Hash as per EIP-712: for string types, we hash them first
                // encodeData for EntryTypeB = encode(keccak256(qux), corge)
                stxItemHashes[i] =
                    keccak256(abi.encodePacked(entryTypeBTypeHash, abi.encode(keccak256(bytes(qux)), corge)));
                entryBCounter++;
            } else if (stxLayout[i].entryType == EntryType.ENTRY_TYPE_C) {
                // Create unique EntryTypeC: EntryTypeC(uint128[] waldo, bytes16 grault)
                uint128[] memory waldo = new uint128[](3);
                waldo[0] = uint128(entryCCounter + 1);
                waldo[1] = uint128(entryCCounter + 2);
                waldo[2] = uint128(entryCCounter + 3);
                bytes16 grault = bytes16(keccak256(abi.encode("grault", entryCCounter)));

                // Store the encoded item
                entryCItems[entryCCounter] = abi.encode(keccak256(abi.encodePacked(waldo)), grault);

                // Hash as per EIP-712: for array types, we hash the array first
                // encodeData for EntryTypeC = encode(keccak256(encodeData(waldo)), grault)
                stxItemHashes[i] =
                    keccak256(abi.encodePacked(entryTypeCTypeHash, abi.encode(keccak256(abi.encodePacked(waldo)), grault)));
                entryCCounter++;
            }
        }

        // ==== STEP 3: Build dynamic SuperTx struct definition ====
        // Format: SuperTx(Type1 entry1,Type2 entry2,...)‖MeeUserOpDef‖EntryTypeADef‖EntryTypeBDef‖EntryTypeCDef

        // Build array of entry type names in the order they appear in stxLayout
        string[] memory entryTypeNames = new string[](totalEntries);
        for (uint256 i = 0; i < totalEntries; i++) {
            if (stxLayout[i].entryType == EntryType.MEE_USER_OP) {
                entryTypeNames[i] = "MeeUserOp";
            } else if (stxLayout[i].entryType == EntryType.ENTRY_TYPE_A) {
                entryTypeNames[i] = "EntryTypeA";
            } else if (stxLayout[i].entryType == EntryType.ENTRY_TYPE_B) {
                entryTypeNames[i] = "EntryTypeB";
            } else if (stxLayout[i].entryType == EntryType.ENTRY_TYPE_C) {
                entryTypeNames[i] = "EntryTypeC";
            }
        }

        // Prepare type definitions
        string memory meeUserOpDefinition =
            "MeeUserOp(bytes32 userOpHash,uint256 lowerBoundTimestamp,uint256 upperBoundTimestamp)";
        string[] memory otherTypeDefinitions = new string[](3);
        otherTypeDefinitions[0] = entryTypeADefinition;
        otherTypeDefinitions[1] = entryTypeBDefinition;
        otherTypeDefinitions[2] = entryTypeCDefinition;

        // Build the complete dynamic struct definition using the helper function
        dynamicStxStructDefinition =
            _buildDynamicStxStructDefinition(entryTypeNames, meeUserOpDefinition, otherTypeDefinitions);

        // ==== STEP 4: Calculate stxStructTypeHash ====
        // As per EIP-712: typeHash = keccak256(dynamicStxStructDefinition)
        bytes32 stxStructTypeHash = keccak256(bytes(dynamicStxStructDefinition));

        // ==== STEP 5: Calculate superTxEip712Hash ====
        // As per EIP-712: hashStruct(s) = keccak256(typeHash ‖ encodeData(s))
        // For a struct with multiple entries: encodeData(s) = encode(value1, value2, ..., valueN)
        // Since all our values are bytes32 hashes, we concatenate them
        bytes32 structHash = keccak256(abi.encodePacked(stxStructTypeHash, stxItemHashes));

        // Now wrap with domain separator as per EIP-712: "\x19\x01" ‖ domainSeparator ‖ hashStruct(message)
        bytes32 superTxEip712Hash = HashLib.hashTypedDataForAccount(smartAccount, structHash);

        // ==== STEP 6: Sign the superTxEip712Hash ====
        // Use the superTxSigner's private key to sign the EIP-712 hash
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(superTxSigner.privateKey, superTxEip712Hash);
        bytes memory superTxHashSignature = abi.encodePacked(r, s, v);

        // ==== STEP 7: Build individual signatures for each entry ====
        // Each entry's signature contains: SIG_TYPE_SIMPLE ‖ encode(stxStructTypeHash, index, stxItemHashes,
        // superTxHashSignature)

        // Reset counters for processing
        userOpCounter = 0;
        nonUserOpDataCounter = 0;
        entryACounter = 0;
        entryBCounter = 0;
        entryCCounter = 0;

        PackedUserOperation[] memory superTxUserOps = new PackedUserOperation[](userOpsLength);

        for (uint256 i = 0; i < totalEntries; i++) {
            bytes memory signature;

            if (stxLayout[i].entryType == EntryType.MEE_USER_OP) {
                // For MeeUserOps: signature includes timestamps
                signature = abi.encodePacked(
                    SIG_TYPE_SIMPLE,
                    abi.encode(
                        stxStructTypeHash,
                        i, // index in the SuperTx
                        stxItemHashes,
                        superTxHashSignature,
                        uint256((uint256(lowerBoundTimestamp) << 128) | uint256(upperBoundTimestamp))
                    )
                );

                // Copy the userOp and replace its signature
                superTxUserOps[userOpCounter] = userOps[userOpCounter].deepCopy();
                superTxUserOps[userOpCounter].signature = signature;
                userOpCounter++;
            } else {
                // For non-UserOp entries: signature does NOT include timestamps
                signature = abi.encodePacked(
                    SIG_TYPE_SIMPLE,
                    abi.encode(
                        stxStructTypeHash,
                        i, // index in the SuperTx
                        stxItemHashes,
                        superTxHashSignature
                    )
                );

                // Store in NonUserOpEntryData array
                nonUserOpEntryDatas[nonUserOpDataCounter] =
                    NonUserOpEntryData({ entryHash: stxItemHashes[i], entryIndex: i, packedSignatureForEntry: signature });
                nonUserOpDataCounter++;
            }
        }

        // ==== STEP 8: Return all results ====
        return (superTxUserOps, nonUserOpEntryDatas);
    }
}
