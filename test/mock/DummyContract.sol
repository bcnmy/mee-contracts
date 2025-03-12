// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.27;

event Uint256Emitted(uint256 value);
event Uint256Emitted2(uint256 value1, uint256 value2);
event AddressEmitted(address addr);
event Bytes32Emitted(bytes32 slot);
event BoolEmitted(bool flag);
event BytesEmitted(bytes data);
contract DummyContract {
    uint256 internal foo;

    function A() external pure returns (uint256) {
        return 42;
    }

    function B(uint256 value) external pure returns (uint256) {
        // Return the input value multiplied by 2
        return value * 2;
    }

    function getFoo() external view returns (uint256) {
        return foo;
    }

    function setFoo(uint256 value) external {
        foo = value;
    }

    function emitUint256(uint256 value) external {
        emit Uint256Emitted(value);
    }

    function swap(uint256 exactInput, uint256 minOutput) external returns (uint256 output1) {
        emit Uint256Emitted2(exactInput, minOutput);
        output1 = exactInput + 1;
        emit Uint256Emitted(output1);
    }

    function stake(uint256 toStake, uint256 param2) external {
        emit Uint256Emitted2(toStake, param2);
    }

    function getAddress() external view returns (address) {
        return address(this);
    }

    function getBool() external view returns (bool) {
        return true;
    }

    function returnMultipleValues() external view returns (uint256, address, bytes32, bool) {
        return (2517, address(this), keccak256("DUMMY"), true);
    }

    function acceptMultipleValues(uint256 value1, address addr, bytes32 slot, bool flag) external {
        emit Uint256Emitted(value1);
        emit AddressEmitted(addr);
        emit Bytes32Emitted(slot);
        emit BoolEmitted(flag);
    }

    function acceptStaticAndDynamicValues(uint256 staticValue, bytes calldata dynamicValue, address addr) external {
        emit Uint256Emitted(staticValue);
        emit AddressEmitted(addr);
        emit BytesEmitted(dynamicValue);
    }
}