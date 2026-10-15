// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MockPriceFeed} from "../MockPriceFeed.sol";
import {AproxPerpV2} from "../AproxPerpV2.sol";

contract DeployMainnet is Script {
    // Arc Mainnet USDC
    address constant USDC = 0x3600000000000000000000000000000000000000;
    // Initial BTC/USD price: $65,000 with 8 decimals
    int256 constant INITIAL_PRICE = 6_500_000_000_000;

    function run() external {
        address operator = vm.envAddress("OPERATOR_ADDRESS");
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);

        // 1. Deploy MockPriceFeed
        MockPriceFeed feed = new MockPriceFeed(operator, INITIAL_PRICE);
        console.log("MockPriceFeed deployed:", address(feed));

        // 2. Deploy AproxPerpV2
        AproxPerpV2 perp = new AproxPerpV2(
            USDC,
            address(feed),
            operator,  // owner
            operator   // feeRecipient
        );
        console.log("AproxPerpV2 deployed:", address(perp));

        vm.stopBroadcast();
    }
}
