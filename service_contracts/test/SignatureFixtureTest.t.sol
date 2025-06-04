// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {SimplePDPServiceWithPayments} from "../src/SimplePDPServiceWithPayments.sol";
import {PDPVerifier} from "@pdp/PDPVerifier.sol";
import {Cids} from "@pdp/Cids.sol";

/**
 * @title Signature Fixture Test
 * @dev Generate and test signatures for SimplePDPServiceWithPayments compatibility
 *
 * This contract serves two purposes:
 * 1. Generate reference signatures from Solidity (for testing external applications)
 * 2. Test external signatures against contract verification
 *
 * Usage:
 * - Run testGenerateFixtures to create reference signatures
 * - Run testExternalSignatures to verify your application's signatures
 */

// Wrapper to expose internal signature verification functions
contract TestableSimplePDPService is SimplePDPServiceWithPayments {
    function testVerifyCreateProofSetSignature(
        address payer,
        uint256 clientDataSetId,
        address payee,
        bool withCDN,
        bytes memory signature
    ) public view returns (bool) {
        return verifyCreateProofSetSignature(payer, clientDataSetId, payee, withCDN, signature);
    }

    function testVerifyAddRootsSignature(
        address payer,
        uint256 clientDataSetId,
        PDPVerifier.RootData[] memory rootDataArray,
        uint256 firstAdded,
        bytes memory signature
    ) public view returns (bool) {
        return verifyAddRootsSignature(payer, clientDataSetId, rootDataArray, firstAdded, signature);
    }

    function testVerifyScheduleRemovalsSignature(
        address payer,
        uint256 clientDataSetId,
        uint256[] memory rootIds,
        bytes memory signature
    ) public view returns (bool) {
        return verifyScheduleRemovalsSignature(payer, clientDataSetId, rootIds, signature);
    }

    function testVerifyDeleteProofSetSignature(
        address payer,
        uint256 clientDataSetId,
        bytes memory signature
    ) public view returns (bool) {
        return verifyDeleteProofSetSignature(payer, clientDataSetId, signature);
    }
}

contract SignatureFixtureTest is Test {
    TestableSimplePDPService public testContract;

    // Test private key (well-known test key, never use in production)
    uint256 constant TEST_PRIVATE_KEY = 0x1234567890123456789012345678901234567890123456789012345678901234;
    address constant TEST_SIGNER = 0x2e988A386a799F506693793c6A5AF6B54dfAaBfB;

    // Test data
    uint256 constant CLIENT_DATASET_ID = 12345;
    address constant PAYEE = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    bool constant WITH_CDN = true;
    uint256 constant FIRST_ADDED = 1;

    function setUp() public {
        testContract = new TestableSimplePDPService();
    }

    /**
     * @dev Generate reference signatures and output JSON fixture
     *
     * This creates signatures using Solidity that external applications
     * can use as reference for testing their signature generation.
     */
    function testGenerateFixtures() public view {
        console.log("=== SIGNATURE FIXTURE GENERATION ===");
        console.log("Contract Address:", address(testContract));
        console.log("Test Signer:", TEST_SIGNER);
        console.log("");

        // Generate all signatures
        bytes memory createProofSetSig = generateCreateProofSetSignature();
        bytes memory addRootsSig = generateAddRootsSignature();
        bytes memory scheduleRemovalsSig = generateScheduleRemovalsSignature();
        bytes memory deleteProofSetSig = generateDeleteProofSetSignature();

        // Output JSON format for copying
        console.log("Copy this JSON to ./test/external_signatures.json:");
        console.log("{");
        console.log('  "signer": "%s",', TEST_SIGNER);
        console.log('  "createProofSet": {');
        console.log('    "signature": "%s",', vm.toString(createProofSetSig));
        console.log('    "clientDataSetId": %d,', CLIENT_DATASET_ID);
        console.log('    "payee": "%s",', PAYEE);
        console.log('    "withCDN": %s', WITH_CDN ? "true" : "false");
        console.log('  },');
        console.log('  "addRoots": {');
        console.log('    "signature": "%s",', vm.toString(addRootsSig));
        console.log('    "clientDataSetId": %d,', CLIENT_DATASET_ID);
        console.log('    "firstAdded": %d,', FIRST_ADDED);
        console.log('    "rootDigests": ["0xfc7e928296e516faade986b28f92d44a4f24b935485223376a799027bc18f833", "0xa9eb89e9825d609ab500be99bf0770bd4e01eeaba92b8dad23c08f1f59bfe10f"],');
        console.log('    "rootSizes": [1024, 2048]');
        console.log('  },');
        console.log('  "scheduleRemovals": {');
        console.log('    "signature": "%s",', vm.toString(scheduleRemovalsSig));
        console.log('    "clientDataSetId": %d,', CLIENT_DATASET_ID);
        console.log('    "rootIds": [1, 3, 5]');
        console.log('  },');
        console.log('  "deleteProofSet": {');
        console.log('    "signature": "%s",', vm.toString(deleteProofSetSig));
        console.log('    "clientDataSetId": %d', CLIENT_DATASET_ID);
        console.log('  }');
        console.log('}');
    }

    /**
     * @dev Test external signatures against contract verification
     *
     * Reads ./test/external_signatures.json and verifies all signatures
     * pass contract verification.
     */
    function testExternalSignatures() public {
        string memory json = vm.readFile("./test/external_signatures.json");
        address signer = vm.parseJsonAddress(json, ".signer");

        console.log("Testing external signatures for signer:", signer);

        // Test all signature types
        testCreateProofSetSignature(json, signer);
        testAddRootsSignature(json, signer);
        testScheduleRemovalsSignature(json, signer);
        testDeleteProofSetSignature(json, signer);

        console.log("All external signature tests PASSED!");
    }

    /**
     * @dev Show signature encoding formats for external developers
     */
    function testSignatureFormats() public view {
        console.log("=== SIGNATURE ENCODING FORMATS ===");
        console.log("Contract Address:", address(testContract));
        console.log("");
        console.log("CreateProofSet:");
        console.log("  abi.encode(contractAddr, uint8(0), clientDataSetId, withCDN, payee)");
        console.log("");
        console.log("AddRoots:");
        console.log("  abi.encode(contractAddr, uint8(1), clientDataSetId, firstAdded, rootDataArray)");
        console.log("  where rootDataArray is tuple(bytes32,uint256)[]");
        console.log("  bytes32 = 32-byte digest from CommP multihash");
        console.log("  uint256 = raw size in bytes");
        console.log("");
        console.log("ScheduleRemovals:");
        console.log("  abi.encode(contractAddr, uint8(2), clientDataSetId, rootIds)");
        console.log("  where rootIds is uint256[]");
        console.log("");
        console.log("DeleteProofSet:");
        console.log("  abi.encode(contractAddr, uint8(3), clientDataSetId)");
    }

    // ============= SIGNATURE GENERATION FUNCTIONS =============

    function generateCreateProofSetSignature() internal view returns (bytes memory) {
        bytes memory data = abi.encode(
            address(testContract),
            uint8(0), // Operation.CreateProofSet
            CLIENT_DATASET_ID,
            WITH_CDN,
            PAYEE
        );
        bytes32 messageHash = keccak256(data);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TEST_PRIVATE_KEY, messageHash);
        return abi.encodePacked(r, s, v);
    }

    function generateAddRootsSignature() internal view returns (bytes memory) {
        // Create RootData array just like the contract expects
        PDPVerifier.RootData[] memory rootDataArray = new PDPVerifier.RootData[](2);
        rootDataArray[0] = PDPVerifier.RootData({
            root: Cids.cidFromDigest("", 0xfc7e928296e516faade986b28f92d44a4f24b935485223376a799027bc18f833),
            rawSize: 1024
        });
        rootDataArray[1] = PDPVerifier.RootData({
            root: Cids.cidFromDigest("", 0xa9eb89e9825d609ab500be99bf0770bd4e01eeaba92b8dad23c08f1f59bfe10f),
            rawSize: 2048
        });

        // Generate message hash exactly like the contract does
        bytes32 messageHash = keccak256(
            abi.encode(
                address(testContract),
                uint8(1), // Operation.AddRoots
                CLIENT_DATASET_ID,
                FIRST_ADDED,
                rootDataArray
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TEST_PRIVATE_KEY, messageHash);
        return abi.encodePacked(r, s, v);
    }

    function generateScheduleRemovalsSignature() internal view returns (bytes memory) {
        uint256[] memory testRootIds = new uint256[](3);
        testRootIds[0] = 1;
        testRootIds[1] = 3;
        testRootIds[2] = 5;

        bytes memory data = abi.encode(
            address(testContract),
            uint8(2), // Operation.ScheduleRemovals
            CLIENT_DATASET_ID,
            testRootIds
        );
        bytes32 messageHash = keccak256(data);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TEST_PRIVATE_KEY, messageHash);
        return abi.encodePacked(r, s, v);
    }

    function generateDeleteProofSetSignature() internal view returns (bytes memory) {
        bytes memory data = abi.encode(
            address(testContract),
            uint8(3), // Operation.DeleteProofSet
            CLIENT_DATASET_ID
        );
        bytes32 messageHash = keccak256(data);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TEST_PRIVATE_KEY, messageHash);
        return abi.encodePacked(r, s, v);
    }

    // ============= SIGNATURE VERIFICATION FUNCTIONS =============

    function testCreateProofSetSignature(string memory json, address signer) internal {
        string memory signature = vm.parseJsonString(json, ".createProofSet.signature");
        uint256 clientDataSetId = vm.parseJsonUint(json, ".createProofSet.clientDataSetId");
        address payee = vm.parseJsonAddress(json, ".createProofSet.payee");
        bool withCDN = vm.parseJsonBool(json, ".createProofSet.withCDN");

        bool isValid = testContract.testVerifyCreateProofSetSignature(
            signer,
            clientDataSetId,
            payee,
            withCDN,
            vm.parseBytes(signature)
        );

        assertTrue(isValid, "CreateProofSet signature verification failed");
        console.log("  CreateProofSet: PASSED");
    }

    function testAddRootsSignature(string memory json, address signer) internal {
        string memory signature = vm.parseJsonString(json, ".addRoots.signature");
        uint256 clientDataSetId = vm.parseJsonUint(json, ".addRoots.clientDataSetId");
        uint256 firstAdded = vm.parseJsonUint(json, ".addRoots.firstAdded");

        // Parse root data arrays
        bytes32[] memory digests = vm.parseJsonBytes32Array(json, ".addRoots.rootDigests");
        uint256[] memory sizes = vm.parseJsonUintArray(json, ".addRoots.rootSizes");

        require(digests.length == sizes.length, "Digest and size arrays must be same length");

        // Create RootData array
        PDPVerifier.RootData[] memory rootData = new PDPVerifier.RootData[](digests.length);
        for (uint256 i = 0; i < digests.length; i++) {
            rootData[i] = PDPVerifier.RootData({
                root: Cids.cidFromDigest("", digests[i]),
                rawSize: sizes[i]
            });
        }

        bool isValid = testContract.testVerifyAddRootsSignature(
            signer,
            clientDataSetId,
            rootData,
            firstAdded,
            vm.parseBytes(signature)
        );

        assertTrue(isValid, "AddRoots signature verification failed");
        console.log("  AddRoots: PASSED");
    }

    function testScheduleRemovalsSignature(string memory json, address signer) internal {
        string memory signature = vm.parseJsonString(json, ".scheduleRemovals.signature");
        uint256 clientDataSetId = vm.parseJsonUint(json, ".scheduleRemovals.clientDataSetId");
        uint256[] memory testRootIds = vm.parseJsonUintArray(json, ".scheduleRemovals.rootIds");

        bool isValid = testContract.testVerifyScheduleRemovalsSignature(
            signer,
            clientDataSetId,
            testRootIds,
            vm.parseBytes(signature)
        );

        assertTrue(isValid, "ScheduleRemovals signature verification failed");
        console.log("  ScheduleRemovals: PASSED");
    }

    function testDeleteProofSetSignature(string memory json, address signer) internal {
        string memory signature = vm.parseJsonString(json, ".deleteProofSet.signature");
        uint256 clientDataSetId = vm.parseJsonUint(json, ".deleteProofSet.clientDataSetId");

        bool isValid = testContract.testVerifyDeleteProofSetSignature(
            signer,
            clientDataSetId,
            vm.parseBytes(signature)
        );

        assertTrue(isValid, "DeleteProofSet signature verification failed");
        console.log("  DeleteProofSet: PASSED");
    }
}