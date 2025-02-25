// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "./Base.t.sol";
import {MockAccountNonComposable} from "./mock/MockAccountNonComposable.sol";

import {ComposableExecutionModule} from "contracts/composability/ComposableExecutionModule.sol";

contract ComposabilityTestBase is BaseTest {

    ComposableExecutionModule internal composabilityHandler;    
    MockAccountNonComposable internal mockAccountNonComposable;
    MockAccount internal mockAccount;

    function setUp() public virtual override {        
        super.setUp();
        composabilityHandler = new ComposableExecutionModule(ENTRYPOINT_V07_ADDRESS);
        mockAccountNonComposable = new MockAccountNonComposable(
            {
                _validator: address(0),
                _executor: address(composabilityHandler),
                _handler: address(composabilityHandler)
            }
        );

        mockAccount = deployMockAccount({
            validator: address(0),
            handler: address(composabilityHandler)
        });
    }

}

