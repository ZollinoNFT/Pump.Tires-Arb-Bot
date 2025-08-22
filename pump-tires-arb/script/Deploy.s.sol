// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {PumpTiresArbitrage} from "src/PumpTiresArbitrage.sol";

contract Deploy is Script {
	function run() external {
		address pump = vm.envAddress("PUMP_ADDRESS");
		address initialWhitelist = vm.envOr("WHITELIST_ADDRESS", address(0));

		vm.startBroadcast();
		PumpTiresArbitrage arb = new PumpTiresArbitrage(pump);
		if (initialWhitelist != address(0)) {
			arb.addToWhitelist(initialWhitelist);
		}
		vm.stopBroadcast();
	}
}