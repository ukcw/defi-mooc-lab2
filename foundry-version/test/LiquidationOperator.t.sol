// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/LiquidationOperator.sol";

contract LiquidationTest is Test {
    LiquidationOperator public liquidationOperator;
    address public liquidator;
    uint256 public constant FORK_BLOCK_NUMBER = 12489619;

    function setUp() public {
        // Fork mainnet at the specific block
        vm.createSelectFork(vm.rpcUrl("mainnet"), FORK_BLOCK_NUMBER);

        // Set up liquidator
        liquidator = makeAddr("liquidator");
        vm.deal(liquidator, 100 ether);

        // Deploy LiquidationOperator
        vm.prank(liquidator);
        liquidationOperator = new LiquidationOperator();
    }

    function testLiquidation() public {
        // Record initial balance
        uint256 beforeLiquidationBalance = liquidator.balance;

        // Start recording logs
        vm.recordLogs();

        // Perform liquidation
        liquidationOperator.operate();

        // Get the recorded logs
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Filter liquidation events
        uint256 liquidationEventCount = 0;
        uint256 expectedLiquidationEventCount = 0;
        for (uint i = 0; i < logs.length; i++) {
            if (
                logs[i].emitter ==
                address(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9) &&
                logs[i].topics.length > 3 &&
                logs[i].topics[0] ==
                keccak256(
                    "LiquidationCall(address,address,address,uint256,uint256,address,bool)"
                )
            ) {
                liquidationEventCount++;
                if (
                    logs[i].topics[3] ==
                    bytes32(
                        uint256(
                            uint160(0x59CE4a2AC5bC3f5F225439B2993b86B42f6d3e9F)
                        )
                    )
                ) {
                    expectedLiquidationEventCount++;
                }
            }
        }

        // Assert liquidation events
        assertTrue(
            expectedLiquidationEventCount > 0,
            "no expected liquidation"
        );
        assertEq(
            liquidationEventCount,
            expectedLiquidationEventCount,
            "unexpected liquidation"
        );

        // Calculate profit
        uint256 afterLiquidationBalance = liquidator.balance;
        int256 profit = int256(afterLiquidationBalance) -
            int256(beforeLiquidationBalance);

        assertTrue(profit > 0, "not profitable");

        // Write profit to file (this will need to be done outside of the test in Foundry)
        // You might want to use Foundry's cheatcodes to write to a file if needed
    }
}
