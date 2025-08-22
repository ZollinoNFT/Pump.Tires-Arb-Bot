// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "lib/forge-std/src/interfaces/IERC20.sol";

/// @notice Minimal SafeERC20 helpers to avoid extra deps
library SafeTransfer {
	function safeTransfer(IERC20 token, address to, uint256 value) internal {
		(bool s, bytes memory r) = address(token).call(abi.encodeWithSelector(token.transfer.selector, to, value));
		require(s && (r.length == 0 || abi.decode(r, (bool))), "TRANSFER_FAIL");
	}

	function safeApprove(IERC20 token, address to, uint256 value) internal {
		(bool s, bytes memory r) = address(token).call(abi.encodeWithSelector(token.approve.selector, to, value));
		require(s && (r.length == 0 || abi.decode(r, (bool))), "APPROVE_FAIL");
	}

	function safeBalanceOf(IERC20 token, address who) internal view returns (uint256 bal) {
		(bool s, bytes memory r) = address(token).staticcall(abi.encodeWithSelector(token.balanceOf.selector, who));
		require(s && r.length >= 32, "BALANCE_FAIL");
		bal = abi.decode(r, (uint256));
	}
}

/// @notice Minimal Ownable + ReentrancyGuard to reduce bloat
abstract contract Ownable {
	event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
	address public owner;
	modifier onlyOwner() {
		require(msg.sender == owner, "NOT_OWNER");
		_;
	}
	constructor() {
		owner = msg.sender;
		emit OwnershipTransferred(address(0), msg.sender);
	}
	function transferOwnership(address newOwner) external onlyOwner {
		require(newOwner != address(0), "ZERO_ADDR");
		emit OwnershipTransferred(owner, newOwner);
		owner = newOwner;
	}
}

abstract contract ReentrancyGuard {
	uint256 private constant _NOT_ENTERED = 1;
	uint256 private constant _ENTERED = 2;
	uint256 private _status = _NOT_ENTERED;
	modifier nonReentrant() {
		require(_status != _ENTERED, "REENTRANCY");
		_status = _ENTERED;
		_;
		_status = _NOT_ENTERED;
	}
}

/// @title PumpTiresArbitrage
/// @notice Fast minimal trading helper for Pump.Tires on PulseChain
contract PumpTiresArbitrage is Ownable, ReentrancyGuard {
	using SafeTransfer for IERC20;

	// --- Immutable config
	address public immutable PUMP;

	// --- Access control
	mapping(address => bool) public isWhitelisted;

	// --- Per-token metadata storage (lightweight)
	mapping(address => bool) public tokenApprovedOnce; // avoid repeated approvals
	mapping(address => address) public tokenCreator;   // optional: set via bot

	// --- Slippage config
	uint256 public buyMinOut;      // defaults to 1 (extreme slippage)
	uint256 public sellMinEthOut;  // defaults to 1

	// --- Events
	event WhitelistAdded(address indexed account);
	event WhitelistRemoved(address indexed account);
	event DevEOARecorded(address indexed token, address indexed dev);
	event Approved(address indexed token);
	event Bought(address indexed token, uint256 amountPls, uint256 newTokenBalance);
	event Sold(address indexed token, uint256 amountTokens, uint256 amountPls);
	event PLSRetrieved(address indexed to, uint256 amount);
	event TokensRescued(address indexed token, address indexed to, uint256 amount);
	event CallFailure(string context, bytes data);
	/// Slippage updates
	event SlippageUpdated(uint256 buyMinOut, uint256 sellMinEthOut);

	// --- Selectors (precomputed)
	bytes4 private constant SELECTOR_TOKENS = 0xe4860339; // tokens(address) -> bool
	bytes4 private constant SELECTOR_GET_SELL_OUT = 0xbbf1fed1; // getSellAmountOut(address,uint256)
	bytes4 private constant SELECTOR_SELL_TOKEN = 0x3e11741f; // sellToken(address,uint256,uint256)
	bytes4 private constant SELECTOR_BUY_RAW = 0x58bbe38e;    // assumed: buyToken(address,uint256,uint256)

	modifier onlyWhitelisted() {
		require(isWhitelisted[msg.sender] || msg.sender == owner, "NOT_ALLOWED");
		_;
	}

	constructor(address pump) {
		require(pump != address(0), "PUMP_ZERO");
		PUMP = pump;
		isWhitelisted[msg.sender] = true; // deployer auto-whitelisted
		buyMinOut = 1;
		sellMinEthOut = 1;
		emit WhitelistAdded(msg.sender);
	}

	receive() external payable {}

	// --- Admin
	function addToWhitelist(address account) external onlyOwner {
		require(account != address(0), "ZERO");
		isWhitelisted[account] = true;
		emit WhitelistAdded(account);
	}

	function removeFromWhitelist(address account) external onlyOwner {
		isWhitelisted[account] = false;
		emit WhitelistRemoved(account);
	}

	function setSlippage(uint256 newBuyMinOut, uint256 newSellMinEthOut) external onlyOwner {
		// allow 0 if desired, but keep <= type(uint256).max
		buyMinOut = newBuyMinOut;
		sellMinEthOut = newSellMinEthOut;
		emit SlippageUpdated(newBuyMinOut, newSellMinEthOut);
	}

	function recordTokenCreator(address token, address dev) external onlyWhitelisted {
		require(token != address(0) && dev != address(0), "ZERO");
		tokenCreator[token] = dev;
		emit DevEOARecorded(token, dev);
	}

	// --- Views
	function getSellAmountOut(address currencyOut, uint256 amountIn) external view returns (uint256 out) {
		(bool s, bytes memory r) = PUMP.staticcall(abi.encodeWithSelector(SELECTOR_GET_SELL_OUT, currencyOut, amountIn));
		if (!s || r.length < 32) return 0;
		out = abi.decode(r, (uint256));
	}

	function tokenListed(address token) public view returns (bool listed) {
		(bool s, bytes memory r) = PUMP.staticcall(abi.encodeWithSelector(SELECTOR_TOKENS, token));
		if (!s || r.length < 32) return false;
		listed = abi.decode(r, (bool));
	}

	// --- Trading
	/// @notice Buys a token via the Pump.Tires contract using raw selector 0x58bbe38e.
	/// Expects `msg.value == buyAmountPls`. Sets extreme slippage (minOut=1).
	function buyToken(address token, uint256 buyAmountPls) external payable onlyWhitelisted nonReentrant {
		require(token != address(0), "TOKEN_ZERO");
		require(msg.value == buyAmountPls && buyAmountPls > 0, "BAD_VALUE");

		// Optionally verify token is listed
		require(tokenListed(token), "NOT_LISTED");

		// Execute buy: assume signature buyToken(address token, uint256 amountIn, uint256 minOut)
		(bool ok, bytes memory ret) = PUMP.call{value: buyAmountPls}(abi.encodeWithSelector(SELECTOR_BUY_RAW, token, buyAmountPls, buyMinOut));
		if (!ok) {
			emit CallFailure("buy", ret);
			revert("BUY_FAIL");
		}

		uint256 bal = SafeTransfer.safeBalanceOf(IERC20(token), address(this));
		if (!tokenApprovedOnce[token]) {
			SafeTransfer.safeApprove(IERC20(token), PUMP, type(uint256).max);
			tokenApprovedOnce[token] = true;
			emit Approved(token);
		}
		emit Bought(token, buyAmountPls, bal);
	}

	/// @notice Sells entire token balance via Pump.Tires with minEthReceived=1.
	function sellTokens(address token) external onlyWhitelisted nonReentrant {
		require(token != address(0), "TOKEN_ZERO");
		uint256 bal = SafeTransfer.safeBalanceOf(IERC20(token), address(this));
		require(bal > 0, "NO_BAL");
		(bytes memory callData) = abi.encodeWithSelector(SELECTOR_SELL_TOKEN, token, bal, sellMinEthOut);
		(bool ok, bytes memory ret) = PUMP.call(callData);
		if (!ok) {
			emit CallFailure("sell", ret);
			revert("SELL_FAIL");
		}
		// Query how much PLS we now have - not perfectly accurate intra-tx, but ok post-call
		emit Sold(token, bal, address(this).balance);
	}

	// --- Funds management
	function retrievePLS(address to, uint256 amount) external onlyWhitelisted nonReentrant {
		require(to != address(0), "ZERO");
		require(amount <= address(this).balance, "INSUFFICIENT");
		(bool s, ) = to.call{value: amount}(new bytes(0));
		require(s, "PLS_SEND_FAIL");
		emit PLSRetrieved(to, amount);
	}

	function rescueTokens(address token, address to) external onlyWhitelisted nonReentrant {
		require(token != address(0) && to != address(0), "ZERO");
		uint256 bal = SafeTransfer.safeBalanceOf(IERC20(token), address(this));
		IERC20(token).safeTransfer(to, bal);
		emit TokensRescued(token, to, bal);
	}
}