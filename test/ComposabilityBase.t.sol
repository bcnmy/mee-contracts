// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "./Base.t.sol";
import {MockAccountNonComposable} from "./mock/MockAccountNonComposable.sol";
import {MockAccountNonRevert} from "./mock/MockAccountNonRevert.sol";
import {ComposableExecutionModule} from "contracts/composability/ComposableExecutionModule.sol";

contract ComposabilityTestBase is BaseTest {
    ComposableExecutionModule internal composabilityHandler;
    MockAccountNonComposable internal mockAccountNonComposable;
    MockAccount internal mockAccount;
    MockAccountNonRevert internal mockAccountNonRevert;

    function setUp() public virtual override {
        super.setUp();
        composabilityHandler = new ComposableExecutionModule();
        mockAccountNonComposable = new MockAccountNonComposable({
            _validator: address(0),
            _executor: address(composabilityHandler),
            _handler: address(composabilityHandler)
        });

        vm.prank(address(mockAccountNonComposable));
        composabilityHandler.onInstall(abi.encodePacked(ENTRYPOINT_V07_ADDRESS));

        mockAccount = deployMockAccount({validator: address(0), handler: address(0xa11ce)});
        mockAccountNonRevert = new MockAccountNonRevert({_validator: address(0), _handler: address(0xa11ce)});
    }
}
