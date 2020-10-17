pragma solidity ^0.5.16;

import "../Tokens/CToken.sol";
import "../ErrorReporter.sol";
import "../Math/Exponential.sol";
import "../PriceOracle.sol";
// import "../Governance/GSigh.sol";
import "./SightrollerInterface.sol";
import "./SightrollerStorage.sol";
import "./Unitroller.sol";
import "../Sigh.sol";
import "../SpeedController/SighSpeedController.sol";

/**
 * @title SighFinance's Sightroller Contract
 * @author SighFinance
 */
contract Sightroller is SightrollerV4Storage, SightrollerInterface, SightrollerErrorReporter, Exponential {
    
    /// @notice Emitted when an admin supports a market
    event MarketListed(CToken cToken);

    /// @notice Emitted when an account enters a market
    event MarketEntered(CToken cToken, address account);

    /// @notice Emitted when an account exits a market
    event MarketExited(CToken cToken, address account);

    /// @notice Emitted when close factor is changed by admin
    event NewCloseFactor(uint oldCloseFactorMantissa, uint newCloseFactorMantissa);

    /// @notice Emitted when a collateral factor is changed by admin
    event NewCollateralFactor(CToken cToken, uint oldCollateralFactorMantissa, uint newCollateralFactorMantissa);

    /// @notice Emitted when liquidation incentive is changed by admin
    event NewLiquidationIncentive(uint oldLiquidationIncentiveMantissa, uint newLiquidationIncentiveMantissa);

    /// @notice Emitted when maxAssets is changed by admin
    event NewMaxAssets(uint oldMaxAssets, uint newMaxAssets);

    /// @notice Emitted when price oracle is changed
    event NewPriceOracle(PriceOracle oldPriceOracle, PriceOracle newPriceOracle);

    /// @notice Emitted when pause guardian is changed
    event NewPauseGuardian(address oldPauseGuardian, address newPauseGuardian);

    /// @notice Emitted when an action is paused globally
    event ActionPaused(string action, bool pauseState);

    /// @notice Emitted when an action is paused on a market
    event ActionPaused(CToken cToken, string action, bool pauseState);

    // closeFactorMantissa must be strictly greater than this value
    uint internal constant closeFactorMinMantissa = 0.05e18; // 0.05

    // closeFactorMantissa must not exceed this value
    uint internal constant closeFactorMaxMantissa = 0.9e18; // 0.9

    // No collateralFactorMantissa may exceed this value
    uint internal constant collateralFactorMaxMantissa = 0.9e18; // 0.9

    // liquidationIncentiveMantissa must be no less than this value
    uint internal constant liquidationIncentiveMinMantissa = 1.0e18; // 1.0

    // liquidationIncentiveMantissa must be no greater than this value
    uint internal constant liquidationIncentiveMaxMantissa = 1.5e18; // 1.5

    constructor() public {
        admin = msg.sender;
    }

    /*** Assets You Are In ***/

    /**
     * @notice Returns the assets an account has entered
     * @param account The address of the account to pull assets for
     * @return A dynamic list with the assets the account has entered
     */
    function getAssetsIn(address account) external view returns (CToken[] memory) {
        CToken[] memory assetsIn = accountAssets[account];

        return assetsIn;
    }

    /**
     * @notice Returns whether the given account is entered in the given asset
     * @param account The address of the account to check
     * @param cToken The cToken to check
     * @return True if the account is in the asset, otherwise false.
     */
    function checkMembership(address account, CToken cToken) external view returns (bool) {
        return markets[address(cToken)].accountMembership[account];
    }

    /**
     * @notice Add assets to be included in account liquidity calculation
     * @param cTokens The list of addresses of the cToken markets to be enabled
     * @return Success indicator for whether each corresponding market was entered
     */
    function enterMarkets(address[] memory cTokens) public returns (uint[] memory) {
        uint len = cTokens.length;

        uint[] memory results = new uint[](len);
        for (uint i = 0; i < len; i++) {
            CToken cToken = CToken(cTokens[i]);
            results[i] = uint(addToMarketInternal(cToken, msg.sender));
        }

        return results;
    }

    /**
     * @notice Add the market to the borrower's "assets in" for liquidity calculations
     * @param cToken The market to enter
     * @param borrower The address of the account to modify
     * @return Success indicator for whether the market was entered
     */
    function addToMarketInternal(CToken cToken, address borrower) internal returns (Error) {
        Market storage marketToJoin = markets[address(cToken)];

        if (!marketToJoin.isListed) {   // market is not listed, cannot join
            return Error.MARKET_NOT_LISTED;
        }

        if (marketToJoin.accountMembership[borrower] == true) {     // already joined
            return Error.NO_ERROR;
        }

        if (accountAssets[borrower].length >= maxAssets)  {      // no space, cannot join
            return Error.TOO_MANY_ASSETS;
        }

        // survived the gauntlet, add to list
        // NOTE: we store these somewhat redundantly as a significant optimization
        //  this avoids having to iterate through the list for the most common use cases
        //  that is, only when we need to perform liquidity checks
        //  and not whenever we want to check if an account is in a particular market
        marketToJoin.accountMembership[borrower] = true;
        accountAssets[borrower].push(cToken);

        emit MarketEntered(cToken, borrower);

        return Error.NO_ERROR;
    }

    /**
     * @notice Removes asset from sender's account liquidity calculation
     * @dev Sender must not have an outstanding borrow balance in the asset,
     *  or be providing necessary collateral for an outstanding borrow.
     * @param cTokenAddress The address of the asset to be removed
     * @return Whether or not the account successfully exited the market
     */
    function exitMarket(address cTokenAddress) external returns (uint) {
        CToken cToken = CToken(cTokenAddress);
        /* Get sender tokensHeld and amountOwed underlying from the cToken */
        (uint oErr, uint tokensHeld, uint amountOwed, ) = cToken.getAccountSnapshot(msg.sender);
        require(oErr == 0, "exitMarket: getAccountSnapshot failed"); // semi-opaque error code

        /* Fail if the sender has a borrow balance */
        if (amountOwed != 0) {
            return fail(Error.NONZERO_BORROW_BALANCE, FailureInfo.EXIT_MARKET_BALANCE_OWED);
        }

        /* Fail if the sender is not permitted to redeem all of their tokens */
        uint allowed = redeemAllowedInternal(cTokenAddress, msg.sender, tokensHeld);
        if (allowed != 0) {
            return failOpaque(Error.REJECTION, FailureInfo.EXIT_MARKET_REJECTION, allowed);
        }

        Market storage marketToExit = markets[address(cToken)];

        /* Return true if the sender is not already ‘in’ the market */
        if (!marketToExit.accountMembership[msg.sender]) {
            return uint(Error.NO_ERROR);
        }

        /* Set cToken account membership to false */
        delete marketToExit.accountMembership[msg.sender];

        /* Delete cToken from the account’s list of assets */
        // load into memory for faster iteration
        CToken[] memory userAssetList = accountAssets[msg.sender];
        uint len = userAssetList.length;
        uint assetIndex = len;
        for (uint i = 0; i < len; i++) {
            if (userAssetList[i] == cToken) {
                assetIndex = i;
                break;
            }
        }

        // We *must* have found the asset in the list or our redundant data structure is broken
        assert(assetIndex < len);

        // copy last item in list to location of item to be removed, reduce length by 1
        CToken[] storage storedList = accountAssets[msg.sender];
        storedList[assetIndex] = storedList[storedList.length - 1];
        storedList.length--;

        emit MarketExited(cToken, msg.sender);

        return uint(Error.NO_ERROR);
    }

    /*** Policy Hooks ***/

    /**
     * @notice Checks if the account should be allowed to mint tokens in the given market
     * @param cToken The market to verify the mint against
     * @param minter The account which would get the minted tokens
     * @param mintAmount The amount of underlying being supplied to the market in exchange for tokens
     * @return 0 if the mint is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function mintAllowed(address cToken, address minter, uint mintAmount) external returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!mintGuardianPaused[cToken], "mint is paused");

        // Shh - currently unused
        minter;
        mintAmount;

        if (!markets[cToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        // Flywheel for SIGH TOkens
        updateSIGHSupplyIndex(cToken);
        distributeSupplier_SIGH(cToken, minter, false);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates mint and reverts on rejection. May emit logs.
     * @param cToken Asset being minted
     * @param minter The address minting the tokens
     * @param actualMintAmount The amount of the underlying asset being minted
     * @param mintTokens The number of tokens being minted
     */
    function mintVerify(address cToken, address minter, uint actualMintAmount, uint mintTokens) external {
        // Shh - currently unused
        cToken;
        minter;
        actualMintAmount;
        mintTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to redeem tokens in the given market
     * @param cToken The market to verify the redeem against
     * @param redeemer The account which would redeem the tokens
     * @param redeemTokens The number of cTokens to exchange for the underlying asset in the market
     * @return 0 if the redeem is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function redeemAllowed(address cToken, address redeemer, uint redeemTokens) external returns (uint) {
        uint allowed = redeemAllowedInternal(cToken, redeemer, redeemTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }

        // Flywheel for SIGH TOkens
        updateSIGHSupplyIndex(cToken);
        distributeSupplier_SIGH(cToken, redeemer, false);

        return uint(Error.NO_ERROR);
    }

    function redeemAllowedInternal(address cToken, address redeemer, uint redeemTokens) internal view returns (uint) {
        if (!markets[cToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        /* If the redeemer is not 'in' the market, then we can bypass the liquidity check */
        if (!markets[cToken].accountMembership[redeemer]) {
            return uint(Error.NO_ERROR);
        }

        /* Otherwise, perform a hypothetical liquidity check to guard against shortfall */
        (Error err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(redeemer, CToken(cToken), redeemTokens, 0);
        if (err != Error.NO_ERROR) {
            return uint(err);
        }
        if (shortfall > 0) {
            return uint(Error.INSUFFICIENT_LIQUIDITY);
        }

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates redeem and reverts on rejection. May emit logs.
     * @param cToken Asset being redeemed
     * @param redeemer The address redeeming the tokens
     * @param redeemAmount The amount of the underlying asset being redeemed
     * @param redeemTokens The number of tokens being redeemed
     */
    function redeemVerify(address cToken, address redeemer, uint redeemAmount, uint redeemTokens) external {
        // Shh - currently unused
        cToken;
        redeemer;

        // Require tokens is zero or amount is also zero
        if (redeemTokens == 0 && redeemAmount > 0) {
            revert("redeemTokens zero");
        }
    }

    /**
     * @notice Checks if the account should be allowed to borrow the underlying asset of the given market
     * @param cToken The market to verify the borrow against
     * @param borrower The account which would borrow the asset
     * @param borrowAmount The amount of underlying the account would borrow
     * @return 0 if the borrow is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function borrowAllowed(address cToken, address borrower, uint borrowAmount) external returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!borrowGuardianPaused[cToken], "borrow is paused");

        if (!markets[cToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (!markets[cToken].accountMembership[borrower]) {
            // only cTokens may call borrowAllowed if borrower not in market
            require(msg.sender == cToken, "sender must be cToken");

            // attempt to add borrower to the market
            Error err = addToMarketInternal(CToken(msg.sender), borrower);
            if (err != Error.NO_ERROR) {
                return uint(err);
            }

            // it should be impossible to break the important invariant
            assert(markets[cToken].accountMembership[borrower]);
        }

        if (oracle.getUnderlyingPrice(CToken(cToken)) == 0) {
            return uint(Error.PRICE_ERROR);
        }

        (Error err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(borrower, CToken(cToken), 0, borrowAmount);
        if (err != Error.NO_ERROR) {
            return uint(err);
        }
        if (shortfall > 0) {
            return uint(Error.INSUFFICIENT_LIQUIDITY);
        }

        // // Keep the flywheel moving
        // Exp memory borrowIndex = Exp({mantissa: CToken(cToken).borrowIndex()});
        // updateGsighBorrowIndex(cToken, borrowIndex);
        // distributeBorrowerGsigh(cToken, borrower, borrowIndex, false);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates borrow and reverts on rejection. May emit logs.
     * @param cToken Asset whose underlying is being borrowed
     * @param borrower The address borrowing the underlying
     * @param borrowAmount The amount of the underlying asset requested to borrow
     */
    function borrowVerify(address cToken, address borrower, uint borrowAmount) external {
        // Shh - currently unused
        cToken;
        borrower;
        borrowAmount;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to repay a borrow in the given market
     * @param cToken The market to verify the repay against
     * @param payer The account which would repay the asset
     * @param borrower The account which borrowed the asset
     * @param repayAmount The amount of the underlying asset the account would repay
     * @return 0 if the repay is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function repayBorrowAllowed( address cToken, address payer, address borrower, uint repayAmount) external returns (uint) {
        // Shh - currently unused
        payer;
        borrower;
        repayAmount;

        if (!markets[cToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        // // Keep the flywheel moving
        // Exp memory borrowIndex = Exp({mantissa: CToken(cToken).borrowIndex()});
        // updateGsighBorrowIndex(cToken, borrowIndex);
        // distributeBorrowerGsigh(cToken, borrower, borrowIndex, false);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates repayBorrow and reverts on rejection. May emit logs.
     * @param cToken Asset being repaid
     * @param payer The address repaying the borrow
     * @param borrower The address of the borrower
     * @param actualRepayAmount The amount of underlying being repaid
     */
    function repayBorrowVerify( address cToken, address payer, address borrower, uint actualRepayAmount, uint borrowerIndex) external {
        // Shh - currently unused
        cToken;
        payer;
        borrower;
        actualRepayAmount;
        borrowerIndex;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the liquidation should be allowed to occur
     * @param cTokenBorrowed Asset which was borrowed by the borrower
     * @param cTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param repayAmount The amount of underlying being repaid
     */
    function liquidateBorrowAllowed( address cTokenBorrowed, address cTokenCollateral, address liquidator, address borrower, uint repayAmount) external returns (uint) {
        // Shh - currently unused
        liquidator;

        if (!markets[cTokenBorrowed].isListed || !markets[cTokenCollateral].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        /* The borrower must have shortfall in order to be liquidatable */
        (Error err, , uint shortfall) = getAccountLiquidityInternal(borrower);
        if (err != Error.NO_ERROR) {
            return uint(err);
        }
        if (shortfall == 0) {
            return uint(Error.INSUFFICIENT_SHORTFALL);
        }

        /* The liquidator may not repay more than what is allowed by the closeFactor */
        uint borrowBalance = CToken(cTokenBorrowed).borrowBalanceStored(borrower);
        (MathError mathErr, uint maxClose) = mulScalarTruncate(Exp({mantissa: closeFactorMantissa}), borrowBalance);
        if (mathErr != MathError.NO_ERROR) {
            return uint(Error.MATH_ERROR);
        }
        if (repayAmount > maxClose) {
            return uint(Error.TOO_MUCH_REPAY);
        }

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates liquidateBorrow and reverts on rejection. May emit logs.
     * @param cTokenBorrowed Asset which was borrowed by the borrower
     * @param cTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param actualRepayAmount The amount of underlying being repaid
     */
    function liquidateBorrowVerify( address cTokenBorrowed, address cTokenCollateral, address liquidator, address borrower, uint actualRepayAmount, uint seizeTokens) external {
        // Shh - currently unused
        cTokenBorrowed;
        cTokenCollateral;
        liquidator;
        borrower;
        actualRepayAmount;
        seizeTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the seizing of assets should be allowed to occur
     * @param cTokenCollateral Asset which was used as collateral and will be seized
     * @param cTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    function seizeAllowed(  address cTokenCollateral, address cTokenBorrowed, address liquidator, address borrower, uint seizeTokens) external returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!seizeGuardianPaused, "seize is paused");

        // Shh - currently unused
        seizeTokens;

        if (!markets[cTokenCollateral].isListed || !markets[cTokenBorrowed].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (CToken(cTokenCollateral).sightroller() != CToken(cTokenBorrowed).sightroller()) {
            return uint(Error.SIGHTROLLER_MISMATCH);
        }

        // Flywheel for SIGH TOkens
        updateSIGHSupplyIndex(cTokenCollateral);
        distributeSupplier_SIGH(cTokenCollateral, borrower, false);
        distributeSupplier_SIGH(cTokenCollateral, liquidator, false);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates seize and reverts on rejection. May emit logs.
     * @param cTokenCollateral Asset which was used as collateral and will be seized
     * @param cTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    function seizeVerify( address cTokenCollateral, address cTokenBorrowed, address liquidator, address borrower, uint seizeTokens) external {
        // Shh - currently unused
        cTokenCollateral;
        cTokenBorrowed;
        liquidator;
        borrower;
        seizeTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to transfer tokens in the given market
     * @param cToken The market to verify the transfer against
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of cTokens to transfer
     * @return 0 if the transfer is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function transferAllowed(address cToken, address src, address dst, uint transferTokens) external returns (uint) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!transferGuardianPaused, "transfer is paused");

        // Currently the only consideration is whether or not the src is allowed to redeem this many tokens
        uint allowed = redeemAllowedInternal(cToken, src, transferTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }

        // Flywheel for SIGH TOkens
        updateSIGHSupplyIndex(cToken);
        distributeSupplier_SIGH(cToken, src, false);
        distributeSupplier_SIGH(cToken, dst, false);

        return uint(Error.NO_ERROR);
    }

    /**
     * @notice Validates transfer and reverts on rejection. May emit logs.
     * @param cToken Asset being transferred
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of cTokens to transfer
     */
    function transferVerify(address cToken, address src, address dst, uint transferTokens) external {
        // Shh - currently unused
        cToken;
        src;
        dst;
        transferTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /*** Liquidity/Liquidation Calculations ***/

    /**
     * @dev Local vars for avoiding stack-depth limits in calculating account liquidity.
     *  Note that `cTokenBalance` is the number of cTokens the account owns in the market,
     *  whereas `borrowBalance` is the amount of underlying that the account has borrowed.
     */
    struct AccountLiquidityLocalVars {
        uint sumCollateral;
        uint sumBorrowPlusEffects;
        uint cTokenBalance;
        uint borrowBalance;
        uint exchangeRateMantissa;
        uint oraclePriceMantissa;
        Exp collateralFactor;
        Exp exchangeRate;
        Exp oraclePrice;
        Exp tokensToDenom;
    }

    /**
     * @notice Determine the current account liquidity wrt collateral requirements
     * @return (possible error code (semi-opaque),
                account liquidity in excess of collateral requirements,
     *          account shortfall below collateral requirements)
     */
    function getAccountLiquidity(address account) public view returns (uint, uint, uint) {
        (Error err, uint liquidity, uint shortfall) = getHypotheticalAccountLiquidityInternal(account, CToken(0), 0, 0);

        return (uint(err), liquidity, shortfall);
    }

    /**
     * @notice Determine the current account liquidity wrt collateral requirements
     * @return (possible error code,
                account liquidity in excess of collateral requirements,
     *          account shortfall below collateral requirements)
     */
    function getAccountLiquidityInternal(address account) internal view returns (Error, uint, uint) {
        return getHypotheticalAccountLiquidityInternal(account, CToken(0), 0, 0);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param cTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @return (possible error code (semi-opaque),
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidity( address account, address cTokenModify, uint redeemTokens, uint borrowAmount) public view returns (uint, uint, uint) {
        (Error err, uint liquidity, uint shortfall) = getHypotheticalAccountLiquidityInternal(account, CToken(cTokenModify), redeemTokens, borrowAmount);
        return (uint(err), liquidity, shortfall);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param cTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @dev Note that we calculate the exchangeRateStored for each collateral cToken using stored data, without calculating accumulated interest.
     * @return (possible error code, hypothetical account liquidity in excess of collateral requirements, hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidityInternal( address account, CToken cTokenModify, uint redeemTokens, uint borrowAmount) internal view returns (Error, uint, uint) {

        AccountLiquidityLocalVars memory vars; // Holds all our calculation results
        uint oErr;
        MathError mErr;

        // For each asset the account is in
        CToken[] memory assets = accountAssets[account];
        for (uint i = 0; i < assets.length; i++) {
            CToken asset = assets[i];

            // Read the balances and exchange rate from the cToken
            (oErr, vars.cTokenBalance, vars.borrowBalance, vars.exchangeRateMantissa) = asset.getAccountSnapshot(account);
            if (oErr != 0) { // semi-opaque error code, we assume NO_ERROR == 0 is invariant between upgrades
                return (Error.SNAPSHOT_ERROR, 0, 0);
            }
            vars.collateralFactor = Exp({mantissa: markets[address(asset)].collateralFactorMantissa});
            vars.exchangeRate = Exp({mantissa: vars.exchangeRateMantissa});

            // Get the normalized price of the asset
            vars.oraclePriceMantissa = oracle.getUnderlyingPrice(asset);
            if (vars.oraclePriceMantissa == 0) {
                return (Error.PRICE_ERROR, 0, 0);
            }
            vars.oraclePrice = Exp({mantissa: vars.oraclePriceMantissa});

            // Pre-compute a conversion factor from tokens -> ether (normalized price value)
            (mErr, vars.tokensToDenom) = mulExp3(vars.collateralFactor, vars.exchangeRate, vars.oraclePrice);
            if (mErr != MathError.NO_ERROR) {
                return (Error.MATH_ERROR, 0, 0);
            }

            // sumCollateral += tokensToDenom * cTokenBalance
            (mErr, vars.sumCollateral) = mulScalarTruncateAddUInt(vars.tokensToDenom, vars.cTokenBalance, vars.sumCollateral);
            if (mErr != MathError.NO_ERROR) {
                return (Error.MATH_ERROR, 0, 0);
            }

            // sumBorrowPlusEffects += oraclePrice * borrowBalance
            (mErr, vars.sumBorrowPlusEffects) = mulScalarTruncateAddUInt(vars.oraclePrice, vars.borrowBalance, vars.sumBorrowPlusEffects);
            if (mErr != MathError.NO_ERROR) {
                return (Error.MATH_ERROR, 0, 0);
            }

            // Calculate effects of interacting with cTokenModify
            if (asset == cTokenModify) {
                // redeem effect
                // sumBorrowPlusEffects += tokensToDenom * redeemTokens
                (mErr, vars.sumBorrowPlusEffects) = mulScalarTruncateAddUInt(vars.tokensToDenom, redeemTokens, vars.sumBorrowPlusEffects);
                if (mErr != MathError.NO_ERROR) {
                    return (Error.MATH_ERROR, 0, 0);
                }

                // borrow effect
                // sumBorrowPlusEffects += oraclePrice * borrowAmount
                (mErr, vars.sumBorrowPlusEffects) = mulScalarTruncateAddUInt(vars.oraclePrice, borrowAmount, vars.sumBorrowPlusEffects);
                if (mErr != MathError.NO_ERROR) {
                    return (Error.MATH_ERROR, 0, 0);
                }
            }
        }

        // These are safe, as the underflow condition is checked first
        if (vars.sumCollateral > vars.sumBorrowPlusEffects) {
            return (Error.NO_ERROR, vars.sumCollateral - vars.sumBorrowPlusEffects, 0);
        } else {
            return (Error.NO_ERROR, 0, vars.sumBorrowPlusEffects - vars.sumCollateral);
        }
    }

    /**
     * @notice Calculate number of tokens of collateral asset to seize given an underlying amount
     * @dev Used in liquidation (called in cToken.liquidateBorrowFresh)
     * @param cTokenBorrowed The address of the borrowed cToken
     * @param cTokenCollateral The address of the collateral cToken
     * @param actualRepayAmount The amount of cTokenBorrowed underlying to convert into cTokenCollateral tokens
     * @return (errorCode, number of cTokenCollateral tokens to be seized in a liquidation)
     */
    function liquidateCalculateSeizeTokens(address cTokenBorrowed, address cTokenCollateral, uint actualRepayAmount) external view returns (uint, uint) {
        /* Read oracle prices for borrowed and collateral markets */
        uint priceBorrowedMantissa = oracle.getUnderlyingPrice(CToken(cTokenBorrowed));
        uint priceCollateralMantissa = oracle.getUnderlyingPrice(CToken(cTokenCollateral));
        if (priceBorrowedMantissa == 0 || priceCollateralMantissa == 0) {
            return (uint(Error.PRICE_ERROR), 0);
        }

        /*
         * Get the exchange rate and calculate the number of collateral tokens to seize:
         *  seizeAmount = actualRepayAmount * liquidationIncentive * priceBorrowed / priceCollateral
         *  seizeTokens = seizeAmount / exchangeRate
         *   = actualRepayAmount * (liquidationIncentive * priceBorrowed) / (priceCollateral * exchangeRate)
         */
        uint exchangeRateMantissa = CToken(cTokenCollateral).exchangeRateStored(); // Note: reverts on error
        uint seizeTokens;
        Exp memory numerator;
        Exp memory denominator;
        Exp memory ratio;
        MathError mathErr;

        (mathErr, numerator) = mulExp(liquidationIncentiveMantissa, priceBorrowedMantissa);
        if (mathErr != MathError.NO_ERROR) {
            return (uint(Error.MATH_ERROR), 0);
        }

        (mathErr, denominator) = mulExp(priceCollateralMantissa, exchangeRateMantissa);
        if (mathErr != MathError.NO_ERROR) {
            return (uint(Error.MATH_ERROR), 0);
        }

        (mathErr, ratio) = divExp(numerator, denominator);
        if (mathErr != MathError.NO_ERROR) {
            return (uint(Error.MATH_ERROR), 0);
        }

        (mathErr, seizeTokens) = mulScalarTruncate(ratio, actualRepayAmount);
        if (mathErr != MathError.NO_ERROR) {
            return (uint(Error.MATH_ERROR), 0);
        }

        return (uint(Error.NO_ERROR), seizeTokens);
    }

    /*** Admin Functions ***/

    /**
      * @notice Sets a new price oracle for the sightroller
      * @dev Admin function to set a new price oracle
      * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
      */
    function _setPriceOracle(PriceOracle newOracle) public returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PRICE_ORACLE_OWNER_CHECK);
        }

        // Track the old oracle for the sightroller
        PriceOracle oldOracle = oracle;

        // Set sightroller's oracle to newOracle
        oracle = newOracle;

        // Emit NewPriceOracle(oldOracle, newOracle)
        emit NewPriceOracle(oldOracle, newOracle);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets the closeFactor used when liquidating borrows
      * @dev Admin function to set closeFactor
      * @param newCloseFactorMantissa New close factor, scaled by 1e18
      * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
      */
    function _setCloseFactor(uint newCloseFactorMantissa) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_CLOSE_FACTOR_OWNER_CHECK);
        }

        Exp memory newCloseFactorExp = Exp({mantissa: newCloseFactorMantissa});
        Exp memory lowLimit = Exp({mantissa: closeFactorMinMantissa});
        if (lessThanOrEqualExp(newCloseFactorExp, lowLimit)) {
            return fail(Error.INVALID_CLOSE_FACTOR, FailureInfo.SET_CLOSE_FACTOR_VALIDATION);
        }

        Exp memory highLimit = Exp({mantissa: closeFactorMaxMantissa});
        if (lessThanExp(highLimit, newCloseFactorExp)) {
            return fail(Error.INVALID_CLOSE_FACTOR, FailureInfo.SET_CLOSE_FACTOR_VALIDATION);
        }

        uint oldCloseFactorMantissa = closeFactorMantissa;
        closeFactorMantissa = newCloseFactorMantissa;
        emit NewCloseFactor(oldCloseFactorMantissa, closeFactorMantissa);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets the collateralFactor for a market
      * @dev Admin function to set per-market collateralFactor
      * @param cToken The market to set the factor on
      * @param newCollateralFactorMantissa The new collateral factor, scaled by 1e18
      * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
      */
    function _setCollateralFactor(CToken cToken, uint newCollateralFactorMantissa) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_COLLATERAL_FACTOR_OWNER_CHECK);
        }

        // Verify market is listed
        Market storage market = markets[address(cToken)];
        if (!market.isListed) {
            return fail(Error.MARKET_NOT_LISTED, FailureInfo.SET_COLLATERAL_FACTOR_NO_EXISTS);
        }

        Exp memory newCollateralFactorExp = Exp({mantissa: newCollateralFactorMantissa});

        // Check collateral factor <= 0.9
        Exp memory highLimit = Exp({mantissa: collateralFactorMaxMantissa});
        if (lessThanExp(highLimit, newCollateralFactorExp)) {
            return fail(Error.INVALID_COLLATERAL_FACTOR, FailureInfo.SET_COLLATERAL_FACTOR_VALIDATION);
        }

        // If collateral factor != 0, fail if price == 0
        if (newCollateralFactorMantissa != 0 && oracle.getUnderlyingPrice(cToken) == 0) {
            return fail(Error.PRICE_ERROR, FailureInfo.SET_COLLATERAL_FACTOR_WITHOUT_PRICE);
        }

        // Set market's collateral factor to new collateral factor, remember old value
        uint oldCollateralFactorMantissa = market.collateralFactorMantissa;
        market.collateralFactorMantissa = newCollateralFactorMantissa;

        // Emit event with asset, old collateral factor, and new collateral factor
        emit NewCollateralFactor(cToken, oldCollateralFactorMantissa, newCollateralFactorMantissa);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets maxAssets which controls how many markets can be entered
      * @dev Admin function to set maxAssets
      * @param newMaxAssets New max assets
      * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
      */
    function _setMaxAssets(uint newMaxAssets) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_MAX_ASSETS_OWNER_CHECK);
        }

        uint oldMaxAssets = maxAssets;
        maxAssets = newMaxAssets;
        emit NewMaxAssets(oldMaxAssets, newMaxAssets);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Sets liquidationIncentive
      * @dev Admin function to set liquidationIncentive
      * @param newLiquidationIncentiveMantissa New liquidationIncentive scaled by 1e18
      * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
      */
    function _setLiquidationIncentive(uint newLiquidationIncentiveMantissa) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_LIQUIDATION_INCENTIVE_OWNER_CHECK);
        }

        // Check de-scaled min <= newLiquidationIncentive <= max
        Exp memory newLiquidationIncentive = Exp({mantissa: newLiquidationIncentiveMantissa});
        Exp memory minLiquidationIncentive = Exp({mantissa: liquidationIncentiveMinMantissa});
        if (lessThanExp(newLiquidationIncentive, minLiquidationIncentive)) {
            return fail(Error.INVALID_LIQUIDATION_INCENTIVE, FailureInfo.SET_LIQUIDATION_INCENTIVE_VALIDATION);
        }

        Exp memory maxLiquidationIncentive = Exp({mantissa: liquidationIncentiveMaxMantissa});
        if (lessThanExp(maxLiquidationIncentive, newLiquidationIncentive)) {
            return fail(Error.INVALID_LIQUIDATION_INCENTIVE, FailureInfo.SET_LIQUIDATION_INCENTIVE_VALIDATION);
        }

        // Save current value for use in log
        uint oldLiquidationIncentiveMantissa = liquidationIncentiveMantissa;

        // Set liquidation incentive to new incentive
        liquidationIncentiveMantissa = newLiquidationIncentiveMantissa;

        // Emit event with old incentive, new incentive
        emit NewLiquidationIncentive(oldLiquidationIncentiveMantissa, newLiquidationIncentiveMantissa);

        return uint(Error.NO_ERROR);
    }

    /**
      * @notice Add the market to the markets mapping and set it as listed
      * @dev Admin function to set isListed and add support for the market
      * @param cToken The address of the market (token) to list
      * @return uint 0=success, otherwise a failure. (See enum Error for details)
      */
    function _supportMarket(CToken cToken) external returns (uint) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SUPPORT_MARKET_OWNER_CHECK);
        }

        if (markets[address(cToken)].isListed) {
            return fail(Error.MARKET_ALREADY_LISTED, FailureInfo.SUPPORT_MARKET_EXISTS);
        }

        cToken.isCToken(); // Sanity check to make sure its really a CToken

        markets[address(cToken)] = Market({isListed: true,  isSIGHed: false, collateralFactorMantissa: 0});

        _addMarketInternal(address(cToken));

        emit MarketListed(cToken);

        return uint(Error.NO_ERROR);
    }

    function _addMarketInternal(address cToken) internal {
        for (uint i = 0; i < allMarkets.length; i ++) {
            require(allMarkets[i] != CToken(cToken), "market already added");
        }
        allMarkets.push(CToken(cToken));
    }

    /**
     * @notice Admin function to change the Pause Guardian
     * @param newPauseGuardian The address of the new Pause Guardian
     * @return uint 0=success, otherwise a failure. (See enum Error for details)
     */
    function _setPauseGuardian(address newPauseGuardian) public returns (uint) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PAUSE_GUARDIAN_OWNER_CHECK);
        }

        // Save current value for inclusion in log
        address oldPauseGuardian = pauseGuardian;

        // Store pauseGuardian with value newPauseGuardian
        pauseGuardian = newPauseGuardian;

        // Emit NewPauseGuardian(OldPauseGuardian, NewPauseGuardian)
        emit NewPauseGuardian(oldPauseGuardian, pauseGuardian);

        return uint(Error.NO_ERROR);
    }

    function _setMintPaused(CToken cToken, bool state) public returns (bool) {
        require(markets[address(cToken)].isListed, "cannot pause a market that is not listed");
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        mintGuardianPaused[address(cToken)] = state;
        emit ActionPaused(cToken, "Mint", state);
        return state;
    }

    function _setBorrowPaused(CToken cToken, bool state) public returns (bool) {
        require(markets[address(cToken)].isListed, "cannot pause a market that is not listed");
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        borrowGuardianPaused[address(cToken)] = state;
        emit ActionPaused(cToken, "Borrow", state);
        return state;
    }

    function _setTransferPaused(bool state) public returns (bool) {
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        transferGuardianPaused = state;
        emit ActionPaused("Transfer", state);
        return state;
    }

    function _setSeizePaused(bool state) public returns (bool) {
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        seizeGuardianPaused = state;
        emit ActionPaused("Seize", state);
        return state;
    }

    // Differnces with sightrollerG3.sol start here

  // Unitroller is the storage Implementation (Function calls get redirected here from there)
  // When new Functionality contract is being initiated (Sightroller Contract needs to be updated), we use this function
  // It is used to make the new implementation to be accepted by calling a function from Unitroller.
    function _become(Unitroller unitroller) public {
        require(msg.sender == unitroller.admin(), "only unitroller admin can change brains");
        require(unitroller._acceptImplementation() == 0, "change not authorized");
    }

    // Differnces with sightroller.sol till here

    /**
     * @notice Checks caller is admin, or this contract is becoming the new implementation
     */
    function adminOrInitializing() internal view returns (bool) {
        return msg.sender == admin || msg.sender == sightrollerImplementation;
    }


    /*** SIGH ***/
    /*** SIGH ***/
    /*** SIGH ***/
    /*** SIGH ***/
    /*** SIGH ***/
    /*** SIGH ***/
    /*** SIGH ***/
    /*** SIGH ***/
    /*** SIGH ***/
    /*** SIGH ***/
    /*** SIGH ***/
    /*** SIGH ***/
    /*** SIGH ***/
    /*** SIGH ***/






    /// @notice The threshold above which the flywheel transfers Gsigh, in wei
    uint public constant SIGH_ClaimThreshold = 0.001e18;

    /// @notice The initial SIGH index for a market
    uint224 public constant sighInitialIndex = 1e36;

    /// @notice Emitted when SIGH rate is changed
    event NewSIGHSpeed(uint oldSIGHSpeed, uint newSIGHSpeed);

    /// @notice Emitted when a new SIGH speed is calculated for a market
    event SuppliersSIGHSpeedUpdated(CToken cToken, uint prevSpeed, uint newSpeed);

    /// @notice Emitted when a new SIGH speed is calculated for a market
    event BorrowersSIGHSpeedUpdated(CToken cToken, uint prevSpeed, uint newSpeed);

    /// @notice Emitted when market isSIGHed status is changed
    event MarketSIGHed(CToken cToken, bool isSIGHed);

    /// @notice Emitted when SIGH is distributed to a supplier
    event DistributedSupplier_SIGH(CToken cToken, address supplier, uint sighDelta, uint sighSupplyIndex);

    /// @notice Emitted when SIGH is distributed to a borrower
    event DistributedBorrower_SIGH(CToken cToken, address borrower, uint sighDelta, uint sighBorrowIndex);

    /// @notice Emitted when SIGH is transferred to a User
    event SIGH_Transferred(address userAddress, uint amountTransferred );

    /// @notice Emitted when Gelato Address is changed
    event GelatoAddressChanged(address prevGelatoAddress, address gelatoAddress , uint amountTransferred );

    /// @notice Emitted when Price snapshot is taken
    event PriceSnapped(address cToken, uint prevPrice, uint currentPrice, uint blockNumber);

    event PriceSnappedCheck(address cToken, uint prevPrice, uint currentPrice, uint blockNumber);

    event SIGH_Speeds_Supplier_Ratio_Mantissa_Updated(address cToken, uint prevRatio, uint newRatio);

    event ClockUpdated( uint224 prevClock, uint224 curClock, uint timestamp );
        
    /*** SIGH Distribution Admin ***/
    /*** SIGH Distribution Admin ***/
    /*** SIGH Distribution Admin ***/
    /*** SIGH Distribution Admin ***/

    // ##############################################################################
    // ################ ADMIN FUNCTIONS RELATED TO SIGH DISTRIBUTION ################
    // ##############################################################################

    /**
     * @notice Add market to SIGHMarkets, allowing them to earn SIGH in the flywheel
     * @param cToken The addresses of the markets to add
     */
    function _addSIGHMarket(address cToken) public {
        require(adminOrInitializing(), "only admin can add SIGH market");

        Market storage market = markets[cToken];        
        require(market.isListed == true, "SIGH market is not listed");
        require(market.isSIGHed == false, "SIGH market already added");

        market.isSIGHed = true;
        
        SIGHMarketState storage getCurrentMarketState = sigh_Market_State[cToken]; 

        if ( getCurrentMarketState.index == 0 && getCurrentMarketState.block_ == 0 ) {
            uint curPrice = oracle.getUnderlyingPrice(CToken(cToken));
            require(curPrice != 0,'The oracle gave an invalid Price'); 
            uint224[24] memory getinitalSnapshot = getinitalSnapshots();
    
            getinitalSnapshot[curClock] = uint224(curPrice);
            
            getCurrentMarketState = SIGHMarketState({ index: sighInitialIndex, recordedPriceSnapshot: getinitalSnapshot,  block_: safe32(getBlockNumber(), "block number exceeds 32 bits") });
        }

        SIGH_Speeds_Supplier_Ratio_Mantissa[cToken] = 1e18;

        refreshSIGHSpeeds(); // TO BE IMPLEMENTED

        emit MarketSIGHed(CToken(cToken), true);
    }

    function getinitalSnapshots() internal returns(uint224[24] memory) {
        uint224[24] memory currentSnap;
        currentSnap[0] = 0;
        currentSnap[1] = 800000;
        currentSnap[2] = 700000;
        currentSnap[3] = 650000;
        currentSnap[4] = 900000;
        currentSnap[5] = 800000;
        currentSnap[6] = 500000;
        currentSnap[7] = 1000000;
        currentSnap[8] = 1100000;
        currentSnap[9] = 1150000;
        currentSnap[10] = 900000;
        currentSnap[11] = 850000;
        currentSnap[12] = 750000;
        currentSnap[13] = 720000;
        currentSnap[14] = 700000;
        currentSnap[15] = 620000;
        currentSnap[16] = 1000000;
        currentSnap[17] = 1500000;
        currentSnap[18] = 1400000;
        currentSnap[19] = 1200000;
        currentSnap[20] = 1100000;
        currentSnap[22] = 1400000;
        currentSnap[23] = 900000;
        return currentSnap;
    }

    /**
     * @notice Remove a market from sighMarkets, preventing it from earning SIGH in the flywheel
     * @param cToken The address of the market to drop
     */
    function _dropSIGHMarket(address cToken) public {
        require(msg.sender == admin, "only admin can drop SIGH market");

        Market storage market = markets[cToken];
        require(market.isSIGHed == true, "market is not a SIGH market");

        market.isSIGHed = false;

        refreshSIGHSpeeds();

        emit MarketSIGHed(CToken(cToken), false);

    }

    function setSIGHSpeedRatioForAMarket(address cToken, uint supplierRatio) public returns (bool) {
        require(msg.sender == admin, 'Only Admin can change the SIGH Speed Distribution Ratio for a Market');
        require( supplierRatio > 0.5e18, 'The new Supplier Ratio must be greater than 0.5e18');
        require( supplierRatio <= 1e18, 'The new Supplier Ratio must be less than 1e18');
        
        Market storage market = markets[cToken];
        require(market.isSIGHed == true, "market is not a SIGH market");

        uint prevRatio = SIGH_Speeds_Supplier_Ratio_Mantissa[cToken];
        SIGH_Speeds_Supplier_Ratio_Mantissa[cToken] = supplierRatio;
        emit SIGH_Speeds_Supplier_Ratio_Mantissa_Updated( cToken, prevRatio , SIGH_Speeds_Supplier_Ratio_Mantissa[cToken] );
        refreshSIGHSpeeds();
        return true;
    }

    /**
     * @notice Set the amount of SIGH distributed per block
     * @param SIGHSpeed_ The amount of SIGH wei per block to distribute
     */
    function setSIGHSpeed(uint SIGHSpeed_) public {
        require(msg.sender == admin, "only admin can change SIGH rate"); 

        uint oldSpeed = SIGHSpeed;
        SIGHSpeed = SIGHSpeed_;
        emit NewSIGHSpeed(oldSpeed, SIGHSpeed_);

        refreshSIGHSpeeds();  // TO BE IMPLEMENTED
    }

    // ###############################################################################
    // ################ REFRESH SIGH DISTRIBUTION SPEEDS (EVERY HOUR) ################
    // ###############################################################################

    /**
     * @notice Recalculate and update SIGH speeds for all SIGH markets
     */
    function refreshSIGHSpeeds() public {
        uint256 timeElapsedSinceLastRefresh = sub_(now , prevSpeedRefreshTime, "RefreshSIGHSpeeds : Subtraction underflow"); 

        if ( timeElapsedSinceLastRefresh >= deltaTimeforSpeed) {
            refreshSIGHSpeedsInternal();
            prevSpeedRefreshTime = now;
        }
    }

    event refreshingSighSpeeds_1( address market ,  uint previousPrice , uint currentPrice , uint marketLosses , uint totalSupply, uint totalLosses   );
    event refreshingSighSpeeds_2( address market, uint marketLosses , uint totalLosses, uint newSpeed   );

    function refreshSIGHSpeedsInternal() internal {
        CToken[] memory allMarkets_ = allMarkets;

        // ###### accure the indexes ######
        for (uint i = 0; i < allMarkets_.length; i++) {
            CToken cToken = allMarkets_[i];
            updateSIGHSupplyIndex(address(cToken));
            Exp memory borrowIndex = Exp({mantissa: cToken.borrowIndex()});            
            updateSIGHBorrowIndex(address(cToken),borrowIndex);
        }

        // ###### Updates the Clock ######
        uint224 prevClock = curClock;  

        if (curClock == 23) {
            curClock = 0;               // Global clock Updated
        }
        else {
            uint224 newClock = uint224(add_(curClock,1,"curClock : Addition Failed"));
            curClock = newClock;        // Global clock Updated
        }
        
        emit ClockUpdated(prevClock,curClock,now);
        

        // ###### Calculate the total Loss made by the protocol over the 24 hrs ######
        Exp memory totalLosses = Exp({mantissa: 0});
        Exp[] memory marketLosses = new Exp[](allMarkets_.length); 

        for (uint i = 0; i < allMarkets_.length; i++) {
            CToken cToken = allMarkets_[i];

            // ######    Calculates the marketLosses[i] by subtracting the current          ######
            // ###### price from the stored price for the current clock (24 hr old price)   ######
            SIGHMarketState storage marketState = sigh_Market_State[address(cToken)];
            Exp memory previousPrice = Exp({ mantissa: marketState.recordedPriceSnapshot[curClock] });
            Exp memory currentPrice = Exp({ mantissa: oracle.getUnderlyingPrice( cToken ) });
            require ( currentPrice.mantissa > 0, "refreshSIGHSpeedsInternal : Oracle returned Invalid Price" );
            
            if ( greaterThanExp( previousPrice , currentPrice ) && markets[address(cToken)].isSIGHed ) {  // i.e the price has decreased
                (MathError error, Exp memory lossPerUnderlying) = subExp( previousPrice , currentPrice );
                uint totalSupply = cToken.totalSupply();
                ( error, marketLosses[i] ) = mulScalar( lossPerUnderlying, totalSupply );
            }
            else {
                 marketLosses[i] = Exp({mantissa: 0});
            }

            //  ###### It updates the stored Price for the current CLock ######
            uint blockNumber = getBlockNumber();        
            uint224[24] storage priceSnapshots = marketState.recordedPriceSnapshot;
            priceSnapshots[curClock] = uint224(currentPrice.mantissa);
            marketState = SIGHMarketState({ index: safe224(marketState.index,"new index exceeds 224 bits"), recordedPriceSnapshot : priceSnapshots,   block_: safe32(blockNumber, "block number exceeds 32 bits")});            
            emit PriceSnapped(address(cToken), previousPrice.mantissa, currentPrice.mantissa , blockNumber );
            SIGHMarketState storage marketState_new = sigh_Market_State[address(cToken)];            
            emit PriceSnappedCheck(address(cToken), previousPrice.mantissa, marketState_new.recordedPriceSnapshot[curClock] , blockNumber );

            //  ###### Adds the loss of the current Market to total loss ######
            Exp memory prevTotalLosses = Exp({ mantissa : totalLosses.mantissa });
            MathError error;
            (error, totalLosses) = addExp(prevTotalLosses, marketLosses[i]);  // Total loss made by the platform
            uint curMarketLoss = marketLosses[i].mantissa;
            // emit refreshingSighSpeeds_1( address(cToken) , previousPrice.mantissa , currentPrice.mantissa ,curMarketLoss , totalSupply,  totalLosses.mantissa );
        }

        // ###### Drips the SIGH from the SIGH Speed Controller ######
        SighSpeedController sigh_SpeedController = SighSpeedController(getSighSpeedController());
        uint256 dripped_amount = sigh_SpeedController.drip();

        // ###### Updates the Speed for the Supported Markets ######
        for (uint i=0 ; i < allMarkets_.length ; i++) {
            CToken cToken = allMarkets[i];
            uint prevSpeedSupplier =  SIGH_Speeds_Suppliers[address(cToken)];
            uint prevSpeedBorrower =  SIGH_Speeds_Borrowers[address(cToken)];

            Exp memory lossRatio;
            if (totalLosses.mantissa > 0) {
                MathError error;
                (error, lossRatio) = divExp(marketLosses[i], totalLosses);
            } 
            else {
                lossRatio = Exp({mantissa: 0});
            }
            uint newSpeed = totalLosses.mantissa > 0 ? mul_(SIGHSpeed, lossRatio) : 0;

            Exp memory supplierSpeedRatio = Exp({ mantissa : SIGH_Speeds_Supplier_Ratio_Mantissa[address(cToken)] });
            uint supplierNewSpeed = mul_(newSpeed, supplierSpeedRatio );
            uint borrowerNewSpeed = sub_(newSpeed, supplierNewSpeed, 'Borrower New Speed: Underflow' );

            SIGH_Speeds_Suppliers[address(cToken)] = supplierNewSpeed;  
            SIGH_Speeds_Borrowers[address(cToken)] = borrowerNewSpeed;  

            emit refreshingSighSpeeds_2( address(cToken) ,  marketLosses[i].mantissa , totalLosses.mantissa , newSpeed );
            emit SuppliersSIGHSpeedUpdated(cToken, prevSpeedSupplier, supplierNewSpeed);
            emit BorrowersSIGHSpeedUpdated(cToken, prevSpeedBorrower, borrowerNewSpeed);
        }
    }

    // ################################################################## 
    // ################ UPDATE SIGH DISTRIBUTION INDEXES ################
    // ##################################################################

    event updateSIGHSupplyIndex_test1(address market,uint speed, uint prevBlock, uint curBlock, uint deltaBlocks );
    event updateSIGHSupplyIndex_test2(address market,uint supplyTokens, uint sigh_Accrued, uint ratio, uint index );
    event updateSIGHSupplyIndex_test3(address market,uint previndex, uint newIndex, uint blockNum );
    event updateSIGHSupplyIndex_test4(address market,uint previndex, uint newIndex, uint blockNum );

    /**
     * @notice Accrue SIGH to the market by updating the supply index
     * @param cToken The market whose supply index to update
     */
    function updateSIGHSupplyIndex(address cToken) internal {
        SIGHMarketState storage supplyState = sigh_Market_State[cToken];
        uint supplySpeed = SIGH_Speeds_Suppliers[cToken];
        uint blockNumber = getBlockNumber();
        uint prevIndex = supplyState.index;
        uint deltaBlocks = sub_(blockNumber, uint( supplyState.block_ ), 'updateSIGHSupplyIndex : Block Subtraction Underflow');
        emit updateSIGHSupplyIndex_test1(cToken, supplySpeed, supplyState.block_, blockNumber, deltaBlocks );
        if (deltaBlocks > 0 && supplySpeed > 0) {
            uint sigh_Accrued = mul_(deltaBlocks, supplySpeed);
            uint supplyTokens = CToken(cToken).totalSupply();
            Double memory ratio = supplyTokens > 0 ? fraction(sigh_Accrued, supplyTokens) : Double({mantissa: 0});
            Double memory index = add_(Double({mantissa: supplyState.index}), ratio);
            emit updateSIGHSupplyIndex_test2( cToken, supplyTokens, sigh_Accrued, ratio.mantissa , index.mantissa );
            supplyState = SIGHMarketState({ index: safe224(index.mantissa, "new index exceeds 224 bits"),  recordedPriceSnapshot: safe224(supplyState.recordedPriceSnapshot, "new recordedPriceSnapshot exceeds 256 bits"),   block_: safe32(blockNumber, "block number exceeds 32 bits")});
        } 
        else if (deltaBlocks > 0) {
            supplyState.block_ = safe32(blockNumber, "block number exceeds 32 bits");
        }
        emit updateSIGHSupplyIndex_test3( cToken, prevIndex, supplyState.index, supplyState.block_  );
        SIGHMarketState storage supplyState_new = sigh_Market_State[cToken];
        emit updateSIGHSupplyIndex_test4(cToken, prevIndex, supplyState_new.index, supplyState_new.block_ );
    }

    event updateSIGHBorrowIndex_test1(address market,uint speed, uint prevBlock, uint curBlock, uint deltaBlocks );
    event updateSIGHBorrowIndex_test2(address market,uint borrowAmount, uint sigh_Accrued, uint ratio, uint index );
    event updateSIGHBorrowIndex_test3(address market,uint previndex, uint newIndex, uint blockNum );
    event updateSIGHBorrowIndex_test4(address market,uint previndex, uint newIndex, uint blockNum );

    /**
     * @notice Accrue SIGH to the market by updating the borrow index
     * @param cToken The market whose borrow index to update
     */
    function updateSIGHBorrowIndex(address cToken, Exp memory marketBorrowIndex) internal {
        SIGHMarketState storage borrowState = sighMarketBorrowState[cToken];
        uint borrowSpeed = SIGH_Speeds_Borrowers[cToken];
        uint blockNumber = getBlockNumber();
        uint prevIndex = borrowState.index;
        uint deltaBlocks = sub_(blockNumber, uint(borrowState.block_));
        emit updateSIGHBorrowIndex_test1(cToken, borrowSpeed, borrowState.block_, blockNumber, deltaBlocks );
        if (deltaBlocks > 0 && borrowSpeed > 0) {
            uint sigh_Accrued = mul_(deltaBlocks, borrowSpeed);
            uint totalBorrows = CToken(cToken).totalBorrows();
            uint borrowAmount = div_(totalBorrows, marketBorrowIndex);
            Double memory ratio = borrowAmount > 0 ? fraction(sigh_Accrued, borrowAmount) : Double({mantissa: 0});
            Double memory index = add_(Double({mantissa: borrowState.index}), ratio);
            emit updateSIGHBorrowIndex_test2( cToken, borrowAmount, sigh_Accrued, ratio.mantissa , index.mantissa );
            uint224[24] memory pricesnapshots = borrowState.recordedPriceSnapshot;
            borrowState = SIGHMarketState({ index: safe224(index.mantissa, "new index exceeds 224 bits"),  recordedPriceSnapshot: safe224(pricesnapshots, "new recordedPriceSnapshot exceeds 256 bits"),   block_: safe32(blockNumber, "block number exceeds 32 bits")});
        } 
        else if (deltaBlocks > 0) {
            borrowState.block_ = safe32(blockNumber, "block number exceeds 32 bits");
        }
        emit updateSIGHBorrowIndex_test3( cToken, prevIndex, borrowState.index, borrowState.block_  );
        SIGHMarketState storage borrowState_new = sighMarketBorrowState[cToken];
        emit updateSIGHBorrowIndex_test4(cToken, prevIndex, borrowState_new.index, borrowState_new.block_ );
    }

    // #########################################################################################
    // ################ DISTRIBUTE ACCURED SIGH AMONG THE NETWORK PARTICIPANTS  ################
    // #########################################################################################

    event distributeSupplier_SIGH_test3(address market,uint supplyIndex, uint supplierIndex );
    event distributeSupplier_SIGH_test4(address market, uint deltaIndex ,uint supplierTokens, uint supplierDelta , uint supplierAccrued);

    /**
     * @notice Calculate SIGH accrued by a supplier and possibly transfer it to them
     * @param cToken The market in which the supplier is interacting
     * @param supplier The address of the supplier to distribute SIGH to
     */
    function distributeSupplier_SIGH(address cToken, address supplier, bool distributeAll) internal {
        SIGHMarketState storage supplyState = sigh_Market_State[cToken];
        Double memory supplyIndex = Double({mantissa: supplyState.index});
        Double memory supplierIndex = Double({mantissa: SIGHSupplierIndex[cToken][supplier]});
        SIGHSupplierIndex[cToken][supplier] = supplyIndex.mantissa;     // UPDATED

        if (supplierIndex.mantissa == 0 && supplyIndex.mantissa > 0) {
            supplierIndex.mantissa = sighInitialIndex;
        }

        emit distributeSupplier_SIGH_test3(cToken, supplyIndex.mantissa, supplierIndex.mantissa );

        Double memory deltaIndex = sub_(supplyIndex, supplierIndex);    // , 'Distribute Supplier SIGH : supplyIndex Subtraction Underflow'
        uint supplierTokens = CToken(cToken).balanceOf(supplier);
        uint supplierDelta = mul_(supplierTokens, deltaIndex);
        uint supplierAccrued = add_(SIGH_Accrued[supplier], supplierDelta);
        emit distributeSupplier_SIGH_test4(cToken, deltaIndex.mantissa , supplierTokens, supplierDelta , supplierAccrued);
        SIGH_Accrued[supplier] = transfer_Sigh(supplier, supplierAccrued, distributeAll ? 0 : SIGH_ClaimThreshold);
        emit DistributedSupplier_SIGH(CToken(cToken), supplier, supplierDelta, supplyIndex.mantissa);
    }

    event distributeBorrower_SIGH_test3(address market,uint borrowIndex, uint borrowerIndex );
    event distributeBorrower_SIGH_test4(address market, uint deltaIndex ,uint borrowBalance, uint borrowerDelta , uint borrowerAccrued);

    /**
     * @notice Calculate SIGH accrued by a borrower and possibly transfer it to them
     * @dev Borrowers will not begin to accrue until after the first interaction with the protocol.
     * @param cToken The market in which the borrower is interacting
     * @param borrower The address of the borrower to distribute Gsigh to
     */
    function distributeBorrower_SIGH(address cToken, address borrower, Exp memory marketBorrowIndex, bool distributeAll) internal {
        SIGHMarketState storage borrowState = sighMarketBorrowState[cToken];
        Double memory borrowIndex = Double({mantissa: borrowState.index});
        Double memory borrowerIndex = Double({mantissa: SIGHBorrowerIndex[cToken][borrower]});
        SIGHBorrowerIndex[cToken][borrower] = borrowIndex.mantissa; // Updated

        if (borrowerIndex.mantissa == 0 && borrowIndex.mantissa > 0) {
            borrowerIndex.mantissa = sighInitialIndex;
        }

        emit distributeBorrower_SIGH_test3(cToken, borrowIndex.mantissa, borrowerIndex.mantissa );

        if (borrowerIndex.mantissa > 0) {
            Double memory deltaIndex = sub_(borrowIndex, borrowerIndex);   // , 'Distribute Borrower SIGH : borrowIndex Subtraction Underflow'
            uint borrowBalance = CToken(cToken).borrowBalanceStored(borrower);
            uint borrowerAmount = div_(borrowBalance, marketBorrowIndex);
            uint borrowerDelta = mul_(borrowerAmount, deltaIndex);
            uint borrowerAccrued = add_(SIGH_Accrued[borrower], borrowerDelta);
            emit distributeBorrower_SIGH_test4(cToken, deltaIndex.mantissa , borrowerAmount, borrowerDelta , borrowerAccrued);
            SIGH_Accrued[borrower] = transfer_Sigh(borrower, borrowerAccrued, distributeAll ? 0 : SIGH_ClaimThreshold);
            emit distributeBorrower_SIGH_test4(cToken, deltaIndex.mantissa, borrowBalance, borrowerDelta, borrowerAccrued);
        }
    }

    // #########################################################################################
    // ################### MARKET PARTICIPANTS CAN CLAIM THEIR ACCURED SIGH  ###################
    // #########################################################################################

    /**
     * @notice Claim all the SIGH accrued by the msg sender
     */
    function claimSIGH() public {
        address[] memory holders = new address[](1);
        holders[0] = msg.sender;
        return claimSIGH(holders, true, true);        
    }

    /**
     * @notice Claim all SIGH accrued by the holders
     * @param holders The addresses to claim SIGH for
     */
    function claimSIGH(address[] memory holders, bool borrowers, bool suppliers ) public {
        
        for (uint i = 0; i < allMarkets.length; i++) {  
            CToken cToken = allMarkets[i];
            require(markets[address(cToken)].isListed, "market must be listed");
            
            if (borrowers == true) {
                Exp memory borrowIndex = Exp({mantissa: cToken.borrowIndex()});
                updateSIGHBorrowIndex(address(cToken), borrowIndex);
                for (uint j = 0; j < holders.length; j++) {
                    distributeBorrower_SIGH(address(cToken), holders[j], borrowIndex, true);
                }
            }

            if (suppliers == true) {
                updateSIGHSupplyIndex(address(cToken));
                for (uint j = 0; j < holders.length; j++) {
                    distributeSupplier_SIGH(address(cToken), holders[j], true);
                }
            }
        }
    }

    // #########################################################################################
    // ################### TRANSFERS THE SIGH TO THE MARKET PARTICIPANT  ###################
    // #########################################################################################

    /**
     * @notice Transfer SIGH to the user, if they are above the threshold
     * @dev Note: If there is not enough SIGH, we do not perform the transfer all.
     * @param user The address of the user to transfer SIGH to
     * @param userAccrued The amount of SIGH to (possibly) transfer
     * @param threshold The minimum amount of SIGH to (possibly) transfer
     * @return The amount of SIGH which was NOT transferred to the user
     */
    function transfer_Sigh(address user, uint userAccrued, uint threshold) internal returns (uint) {
        if (userAccrued >= threshold && userAccrued > 0) {
            SIGH sigh = SIGH(getSighAddress());
            uint sigh_Remaining = sigh.balanceOf(address(this));
            if (userAccrued <= sigh_Remaining) {
                sigh.transfer(user, userAccrued);
                emit SIGH_Transferred(user, userAccrued);
                return 0;
            }
        }
        return userAccrued;
    }

    // #########################################################
    // ################### GENERAL FUNCTIONS ###################
    // #########################################################


    function setSighAddress(address Sigh_Address__) public view returns (address) {
        Sigh_Address = Sigh_Address__;
        return Sigh_Address;
    }
    
    function getSighAddress() public view returns (address) {
        return Sigh_Address;
    }    

    function getSighSpeedController() public view returns (address) {
        return SighSpeedControllerAddress;
    }
    
    function setSighSpeedController(address SighSpeedController__) public returns (address) {
        SighSpeedControllerAddress = SighSpeedController__;
        return SighSpeedControllerAddress;
    }    

    /**
     * @notice Return all of the markets
     * @dev The automatic getter may be used to access an individual market.
     * @return The list of market addresses
     */
    function getAllMarkets() public view returns (CToken[] memory) {
        return allMarkets;
    }

    function getBlockNumber() public view returns (uint) {
        return block.number;
    }

    function getUnderlyingPriceFromoracle(address cToken) public view returns (uint) {
        return  oracle.getUnderlyingPrice(CToken(cToken)) ; 
    }

}
