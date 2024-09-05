//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.7;

import "forge-std/console.sol";

// ----------------------INTERFACE------------------------------

// Aave
// https://docs.aave.com/developers/the-core-protocol/lendingpool/ilendingpool

interface ILendingPool {
    /**
     * Function to liquidate a non-healthy position collateral-wise, with Health Factor below 1
     * - The caller (liquidator) covers `debtToCover` amount of debt of the user getting liquidated, and receives
     *   a proportionally amount of the `collateralAsset` plus a bonus to cover market risk
     * @param collateralAsset The address of the underlying asset used as collateral, to receive as result of theliquidation
     * @param debtAsset The address of the underlying borrowed asset to be repaid with the liquidation
     * @param user The address of the borrower getting liquidated
     * @param debtToCover The debt amount of borrowed `asset` the liquidator wants to cover
     * @param receiveAToken `true` if the liquidators wants to receive the collateral aTokens, `false` if he wants
     * to receive the underlying collateral asset directly
     **/
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external;

    /**
     * Returns the user account data across all the reserves
     * @param user The address of the user
     * @return totalCollateralETH the total collateral in ETH of the user
     * @return totalDebtETH the total debt in ETH of the user
     * @return availableBorrowsETH the borrowing power left of the user
     * @return currentLiquidationThreshold the liquidation threshold of the user
     * @return ltv the loan to value of the user
     * @return healthFactor the current health factor of the user
     **/
    function getUserAccountData(
        address user
    )
        external
        view
        returns (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            uint256 availableBorrowsETH,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}

// UniswapV2

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IERC20.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/Pair-ERC-20
interface IERC20 {
    // Returns the account balance of another account with address _owner.
    function balanceOf(address owner) external view returns (uint256);

    /**
     * Allows _spender to withdraw from your account multiple times, up to the _value amount.
     * If this function is called again it overwrites the current allowance with _value.
     * Lets msg.sender set their allowance for a spender.
     **/
    function approve(address spender, uint256 value) external; // return type is deleted to be compatible with USDT

    /**
     * Transfers _value amount of tokens to address _to, and MUST fire the Transfer event.
     * The function SHOULD throw if the message caller's account balance does not have enough tokens to spend.
     * Lets msg.sender send pool tokens to an address.
     **/
    function transfer(address to, uint256 value) external returns (bool);
}

// https://github.com/Uniswap/v2-periphery/blob/master/contracts/interfaces/IWETH.sol
interface IWETH is IERC20 {
    // Convert the wrapped token back to Ether.
    function withdraw(uint256) external;
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Callee.sol
// The flash loan liquidator we plan to implement this time should be a UniswapV2 Callee
interface IUniswapV2Callee {
    function uniswapV2Call(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external;
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Factory.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/factory
interface IUniswapV2Factory {
    // Returns the address of the pair for tokenA and tokenB, if it has been created, else address(0).
    function getPair(
        address tokenA,
        address tokenB
    ) external view returns (address pair);
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Pair.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/pair
interface IUniswapV2Pair {
    /**
     * Swaps tokens. For regular swaps, data.length must be 0.
     * Also see [Flash Swaps](https://docs.uniswap.org/protocol/V2/concepts/core-concepts/flash-swaps).
     **/
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;

    /**
     * Returns the reserves of token0 and token1 used to price trades and distribute liquidity.
     * See Pricing[https://docs.uniswap.org/protocol/V2/concepts/advanced-topics/pricing].
     * Also returns the block.timestamp (mod 2**32) of the last block during which an interaction occured for the pair.
     **/
    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    function token0() external view returns (address);

    function token1() external view returns (address);
}

interface IUniswapV2Router02 {
    function WETH() external pure returns (address);

    function swapExactTokensForETH(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);

    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts);
}

// ----------------------IMPLEMENTATION------------------------------

contract LiquidationOperator is IUniswapV2Callee {
    uint8 public constant health_factor_decimals = 18;

    // Constants
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address private constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address private constant UNISWAP_FACTORY =
        0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    address private constant AAVE_LENDING_POOL =
        0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9;
    IUniswapV2Router02 private constant UNISWAP_ROUTER =
        IUniswapV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);

    IUniswapV2Factory private constant factory =
        IUniswapV2Factory(UNISWAP_FACTORY);
    ILendingPool private constant lendingPool = ILendingPool(AAVE_LENDING_POOL);

    address private immutable owner;

    constructor() {
        owner = msg.sender;
    }

    receive() external payable {}

    function operate() external {
        // Get the target user account data
        address targetUser = 0x59CE4a2AC5bC3f5F225439B2993b86B42f6d3e9F;
        (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            ,
            uint256 currentLiquidationThreshold,
            ,
            uint256 healthFactor
        ) = lendingPool.getUserAccountData(targetUser);

        // Make sure it is liquidatable
        require(healthFactor < 1e18, "User is not liquidatable");

        address usdtWethPair = factory.getPair(USDT, WETH);
        (uint112 reserveWeth, uint112 reserveUsdt, ) = IUniswapV2Pair(
            usdtWethPair
        ).getReserves();

        console.log("WETH reserve:", reserveWeth);
        console.log("USDT reserve:", reserveUsdt);

        // Calculate the maximum debt that can be liquidated (50% of the total debt)
        uint256 maxLiquidatableDebtETH = totalDebtETH / 2;

        // Calculate max profitability

        // Calculate the payment we need to return for the borrow including fee

        // Convert ETH debt to USDT
        // ethUsdtPrice is assumed to be scaled to 1e6 (USDT decimals)
        uint256 maxLiquidatableDebtUSDT = ((maxLiquidatableDebtETH *
            reserveUsdt) / reserveWeth);

        console.log("Max Liquidatable Debt (ETH):", maxLiquidatableDebtETH);
        console.log("Max Liquidatable Debt (USDT):", maxLiquidatableDebtUSDT);

        // not using WBTC/USDT
        // address pair = factory.getPair(USDT, WBTC);
        // require(pair != address(0), "Pair does not exist");

        // (uint112 reserveWBTC, uint112 reserveUSDT, ) = IUniswapV2Pair(pair)
        //     .getReserves();

        // console.log("WBTC reserve:", reserveWBTC);
        // console.log("USDT reserve:", reserveUSDT);

        // Calculate the maximum amount we can borrow (95% of USDT reserve to account for slippage)
        uint256 maxBorrowableUSDT = reserveUsdt;

        // Determine the amount to borrow (smaller of maxLiquidatableDebtUSDT or maxBorrowableUSDT)
        uint256 usdtToBorrow = maxLiquidatableDebtUSDT < maxBorrowableUSDT
            ? maxLiquidatableDebtUSDT
            : maxBorrowableUSDT;

        // usdtToBorrow = usdtToBorrow / 15;
        // usdtToBorrow = 2916358033112;
        // console.log("usdtToBorrow", usdtToBorrow);

        bytes memory data = abi.encode(targetUser);

        // Perform flash swap
        console.log("Initiating flash swap for %s USDT", usdtToBorrow);
        IUniswapV2Pair(usdtWethPair).swap(0, usdtToBorrow, address(this), data);

        // Transfer profit to liquidator
        console.log("owner", owner);
        (bool success, ) = owner.call{value: address(this).balance}("");
        require(success, "ETH transfer failed");
    }

    function uniswapV2Call(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external override {
        require(
            msg.sender == factory.getPair(WETH, USDT),
            "Unauthorized caller"
        );
        console.log("uniswapV2Call triggered");
        // recommended checks from Aave V2
        address token0 = IUniswapV2Pair(msg.sender).token0(); // fetch the address of token0
        address token1 = IUniswapV2Pair(msg.sender).token1(); // fetch the address of token1
        console.log("token0 addr", token0);
        console.log("token1 addr", token1);
        assert(
            msg.sender == IUniswapV2Factory(factory).getPair(token0, token1)
        ); // ensure that msg.sender is a V2 pair
        uint256 usdtBorrowed = amount1;
        address targetUser = abi.decode(data, (address));

        // Approve USDT spending
        console.log("Approving USDT spending");
        try IERC20(USDT).approve(AAVE_LENDING_POOL, type(uint256).max) {
            // Approval succeeded
            console.log("Approval succeeded");
        } catch {
            revert("USDT approval failed");
        }

        // Before the liquidation call
        console.log("Liquidation parameters:");
        console.log("Collateral asset (WETH):", WETH);
        console.log("Debt asset (USDT):", USDT);
        console.log("Target user:", targetUser);
        console.log("Debt to cover:", amount1);

        // Check USDT balance
        uint256 usdtBalance = IERC20(USDT).balanceOf(address(this));
        console.log("USDT balance before liquidation:", usdtBalance);

        (uint112 reserveWETH, uint112 reserveUSDT, ) = IUniswapV2Pair(
            msg.sender
        ).getReserves();
        uint256 wethToRepay = getAmountIn(
            usdtBorrowed,
            reserveWETH,
            reserveUSDT
        );
        console.log("WETH-USDT reserves", reserveWETH, reserveUSDT);

        (, , , , , uint256 healthFactor) = lendingPool.getUserAccountData(
            targetUser
        );
        console.log("User health factor before liquidation:", healthFactor);
        require(healthFactor < 1e18, "User is not liquidatable");
        // Perform liquidation
        console.log(
            "WBTC balance before liquidation",
            IERC20(WBTC).balanceOf(address(this))
        );
        console.log(
            "USDT balance before liquidation",
            IERC20(USDT).balanceOf(address(this))
        );
        console.log("Performing liquidation");
        lendingPool.liquidationCall(
            WBTC,
            USDT,
            targetUser,
            usdtBorrowed,
            false
        );
        console.log("Liquidation completed");
        console.log(
            "WBTC balance after liquidation:",
            IERC20(WBTC).balanceOf(address(this))
        );
        console.log(
            "USDT balance after liquidation",
            IERC20(USDT).balanceOf(address(this))
        );
        (, , , , , uint256 healthFactorAfter) = lendingPool.getUserAccountData(
            targetUser
        );
        console.log(
            "User health factor before liquidation:",
            healthFactorAfter
        );

        // Check WBTC balance after liquidation
        uint256 wbtcBalance = IERC20(WBTC).balanceOf(address(this));
        console.log("USDT Borrowed:", usdtBorrowed);
        console.log("WETH to Repay:", wethToRepay);
        console.log("WBTC Received from Liquidation:", wbtcBalance);

        // Convert WBTC to WETH
        IERC20(WBTC).approve(address(UNISWAP_ROUTER), wbtcBalance);

        address[] memory path = new address[](2);
        path[0] = WBTC;
        path[1] = WETH;

        UNISWAP_ROUTER.swapExactTokensForTokens(
            wbtcBalance,
            0,
            path,
            address(this),
            block.timestamp
        );

        uint256 wethBalance = IERC20(WETH).balanceOf(address(this));
        console.log("WETH balance after swap:", wethBalance);

        // Repay flash loan
        IERC20(WETH).transfer(msg.sender, wethToRepay);

        // Calculate and log profit
        uint256 profit = wethBalance - wethToRepay;
        console.log("Profit in WETH:", profit);

        IWETH(WETH).withdraw(IWETH(WETH).balanceOf(address(this)));
    }

    // some helper function, it is totally fine if you can finish the lab without using these function
    // https://github.com/Uniswap/v2-periphery/blob/master/contracts/libraries/UniswapV2Library.sol
    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    // safe mul is not necessary since https://docs.soliditylang.org/en/v0.8.9/080-breaking-changes.html
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, "UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT");
        console.log("reserveInOutOUT", reserveIn, reserveOut);
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    // some helper function, it is totally fine if you can finish the lab without using these function
    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    // safe mul is not necessary since https://docs.soliditylang.org/en/v0.8.9/080-breaking-changes.html
    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountIn) {
        require(amountOut > 0, "UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT");
        console.log("reserveInOutIN", reserveIn, reserveOut);
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 numerator = reserveIn * amountOut * 1000;
        uint256 denominator = (reserveOut - amountOut) * 997;
        amountIn = (numerator / denominator) + 1;
    }
}
