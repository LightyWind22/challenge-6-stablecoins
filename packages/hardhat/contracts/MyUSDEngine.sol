// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./MyUSD.sol";
import "./Oracle.sol";
import "./MyUSDStaking.sol";

error Engine__InvalidAmount();
error Engine__UnsafePositionRatio();
error Engine__NotLiquidatable();
error Engine__InvalidBorrowRate();
error Engine__NotRateController();
error Engine__InsufficientCollateral();
error Engine__TransferFailed();

contract MyUSDEngine is Ownable {
    uint256 private constant COLLATERAL_RATIO = 150; // 150% collateralization required
    uint256 private constant LIQUIDATOR_REWARD = 10; // 10% reward for liquidators
    uint256 private constant SECONDS_PER_YEAR = 365 days;
    uint256 private constant PRECISION = 1e18;

    MyUSD private i_myUSD;
    Oracle private i_oracle;
    MyUSDStaking private i_staking;
    address private i_rateController;

    uint256 public borrowRate; // Annual interest rate for borrowers in basis points (1% = 100)

    // Total debt shares in the pool
    uint256 public totalDebtShares;

    // Exchange rate between debt shares and MyUSD (1e18 precision)
    uint256 public debtExchangeRate;
    uint256 public lastUpdateTime;

    mapping(address => uint256) public s_userCollateral;
    mapping(address => uint256) public s_userDebtShares;

    event CollateralAdded(address indexed user, uint256 indexed amount, uint256 price);
    event CollateralWithdrawn(address indexed withdrawer, uint256 indexed amount, uint256 price);
    event BorrowRateUpdated(uint256 newRate);
    event DebtSharesMinted(address indexed user, uint256 amount, uint256 shares);
    event DebtSharesBurned(address indexed user, uint256 amount, uint256 shares);
    event Liquidation(
        address indexed user,
        address indexed liquidator,
        uint256 amountForLiquidator,
        uint256 liquidatedUserDebt,
        uint256 price
    );

    modifier onlyRateController() {
        if (msg.sender != i_rateController) revert Engine__NotRateController();
        _;
    }

    constructor(
        address _oracle,
        address _myUSDAddress,
        address _stakingAddress,
        address _rateController
    ) Ownable(msg.sender) {
        i_oracle = Oracle(_oracle);
        i_myUSD = MyUSD(_myUSDAddress);
        i_staking = MyUSDStaking(_stakingAddress);
        i_rateController = _rateController;
        lastUpdateTime = block.timestamp;
        debtExchangeRate = PRECISION; // 1:1 initially
    }

    // Checkpoint 2: Depositing Collateral & Understanding Value
    function addCollateral() public payable {
        // revert if invalid value
        if (msg.value == 0) {
            revert Engine__InvalidAmount();
        }
        
        // update the s_userCollateral mapping for msg.sender to reflect how much ETH they sent the contract.
        s_userCollateral[msg.sender] += msg.value;

        // emit event to frontend
        emit CollateralAdded(msg.sender, msg.value, i_oracle.getETHMyUSDPrice());
    }

    function calculateCollateralValue(address user) public view returns (uint256) {
        // get the current price of ETH in MyUSD
        uint256 priceETHToMyUSD = i_oracle.getETHMyUSDPrice();

        // get the user's collateral value
        uint256 userCollateral = s_userCollateral[user];

        // return the collateral in MyUSD
        return (userCollateral * priceETHToMyUSD) / PRECISION;
    }

    // Checkpoint 3: Interest Calculation System
    function _getCurrentExchangeRate() internal view returns (uint256) {
        // if there no debt share, debtExchangeRate do not change
        if (totalDebtShares == 0) {
            return debtExchangeRate;
        }

        // calculate elapsed time
        uint256 elapsedTime = block.timestamp - lastUpdateTime;

        // no change since now
        if (elapsedTime == 0 || borrowRate == 0) {
            return debtExchangeRate;
        }

        // calculate total Debt Value
        uint256 totalDebtValue = (totalDebtShares * debtExchangeRate) / PRECISION;

        // calculate total accrued interest. Formular: Interest =  Price * rate * time;
        uint256 interest = (totalDebtValue * borrowRate * elapsedTime) / (SECONDS_PER_YEAR * 10000);

        // calculate interest per Share
        uint256 interestPerShare = (interest * PRECISION) / totalDebtShares;

        // return new debtExchangeRate
        return debtExchangeRate + interestPerShare;
    }

    function _accrueInterest() internal {
        if (totalDebtShares == 0 ) {
            lastUpdateTime = block.timestamp;
            return;
        }
        // update debt exchange rate and last update time
        debtExchangeRate = _getCurrentExchangeRate();
        lastUpdateTime = block.timestamp;
    }

    function _getMyUSDToShares(uint256 amount) internal view returns (uint256) {
        // get current exchange rate (Share/MyUSD)
        uint256 currentExchangeRate = _getCurrentExchangeRate();

        // calculate MyUSD amount equivalent number of Shares and return
        return (amount * PRECISION) / currentExchangeRate; 
    }

    // Checkpoint 4: Minting MyUSD & Position Health
    function getCurrentDebtValue(address user) public view returns (uint256) {
        // get user's debt shares
        uint256 userDebtShares = s_userDebtShares[user];

        // if user has no debt, return 0
        if (userDebtShares == 0) {
            return 0;
        }

        // get current exchange rate (Share/MyUSD)
        uint256 currentExchangeRate = _getCurrentExchangeRate();

        // calculate total debt value in MyUSD that user owe and return
        return (userDebtShares * currentExchangeRate) / PRECISION;
    }

    function calculatePositionRatio(address user) public view returns (uint256) {
        // Get the user's current debt value
        uint256 userDebtValue = getCurrentDebtValue(user);

        // Get the user's collateral value
        uint256 userCollateral = calculateCollateralValue(user);

        // check if debt value is 0, return max
        if (userDebtValue == 0) {
            return type(uint256).max;
        }

        // calculate user's position ratio and return
        return (userCollateral * PRECISION) / userDebtValue;
    }

    function _validatePosition(address user) internal view {
        // get user's position ratio
        uint256 userPositionRatio = calculatePositionRatio(user);

        // revert if unsafe 
        if ((userPositionRatio * 100) < (COLLATERAL_RATIO * PRECISION)) {
            revert Engine__UnsafePositionRatio();
        }
    }

    function mintMyUSD(uint256 mintAmount) public {
        // revert if invalid amount
        if (mintAmount == 0) {
            revert Engine__InvalidAmount();
        }

        // calculate how many shares this mint amount represents
        uint256 sharesAmount = _getMyUSDToShares(mintAmount);

        // update user's debt shares
        s_userDebtShares[msg.sender] += sharesAmount;

        // update total debt shares
        totalDebtShares += sharesAmount;

        // validate position is safe
        _validatePosition(msg.sender);

        // mint the MyUSD tokens to the user
        i_myUSD.mintTo(msg.sender, mintAmount);

        // emit event to frontend
        emit DebtSharesMinted(msg.sender, mintAmount, sharesAmount);
    }

    // Checkpoint 5: Accruing Interest & Managing Borrow Rates
    function setBorrowRate(uint256 newRate) external onlyRateController {
        // Run _accrueInterest() to update the debtExchangeRate and lastUpdateTime
        _accrueInterest();

        // prevent setting borow rate below savings rate
        if (newRate < i_staking.savingsRate()) {
            revert Engine__InvalidBorrowRate();
        }

        // update borrowRate
        borrowRate = newRate;

        // emit event to frontend
        emit BorrowRateUpdated(newRate);
    }

    // Checkpoint 6: Repaying Debt & Withdrawing Collateral
    function repayUpTo(uint256 amount) public {
        // convert the MyUSD amount into Shares
        uint256 amountInShares = _getMyUSDToShares(amount);

        // get user's debt shares
        uint256 userDebtShares = s_userDebtShares[msg.sender];

        // handle repay amount > their actual owe
        if (amountInShares > userDebtShares) {
            amountInShares = userDebtShares;
            amount = getCurrentDebtValue(msg.sender);
        }

        // check if user has enough MyUSD balance to repay
        if (i_myUSD.balanceOf(msg.sender) < amount) {
            revert MyUSD__InsufficientBalance();
        }

        // check if MyUSD Engine has enough allowance to spend the user's MyUSD
        if (i_myUSD.allowance(msg.sender, address(this)) < amount) {
            revert MyUSD__InsufficientAllowance();
        }

        // update s_userDebtShares[msg.sender] and totalDebtShares
        s_userDebtShares[msg.sender] -= amountInShares;
        totalDebtShares -= amountInShares;

        // burn the MyUSD from the user
        i_myUSD.burnFrom(msg.sender, amount);

        // emit event to frontend
        emit DebtSharesBurned(msg.sender, amount, amountInShares);
    }

    function withdrawCollateral(uint256 amount) external {
        // revert if amount = 0
        if (amount == 0) {
            revert Engine__InvalidAmount();
        }

        // revert if withdraw amount > user's current collateral
        if (amount > s_userCollateral[msg.sender]) {
            revert Engine__InsufficientCollateral();
        }

        // update state: decrease user's collateral
        s_userCollateral[msg.sender] -= amount;

        // if user has debt, check position safety
        if (s_userDebtShares[msg.sender] > 0) {
            _validatePosition(msg.sender);
        }

        // transfer ETH to user
        (bool success,) = payable(msg.sender).call{value: amount}("");
        if (!success) {
            revert Engine__TransferFailed();
        }

        // emit event to frontend
        emit CollateralWithdrawn(msg.sender, amount, i_oracle.getETHMyUSDPrice());
    }

    // Checkpoint 7: Liquidation - Enforcing System Stability
    function isLiquidatable(address user) public view returns (bool) {
        // calculate user's current position ratio
        uint256 userPositionRatio = calculatePositionRatio(user);

        // return true if unsafe, false if safe
        return (userPositionRatio * 100) < (COLLATERAL_RATIO * PRECISION);
    }

    function liquidate(address user) external {
        if (!isLiquidatable(user)) {
            revert Engine__NotLiquidatable();
        }

        // get user debt value
        uint256 userDebtValue = getCurrentDebtValue(user);

        // get user collateral
        uint256 userCollateral = s_userCollateral[user];

        // get collateral value
        uint256 collateralValue = calculateCollateralValue(user);

        // check if liquidator has enough MyUSD to repay for user
        if (i_myUSD.balanceOf(msg.sender) < userDebtValue) {
            revert MyUSD__InsufficientBalance();
        }

        // check allowance for the engine to burn's liquidator MyUSD
        if (i_myUSD.allowance(msg.sender, address(this)) < userDebtValue) {
            revert MyUSD__InsufficientAllowance();
        }

        // burn user debt value of MyUSD from msg.sender
        i_myUSD.burnFrom(msg.sender, userDebtValue);

        // clear user's debt
        totalDebtShares -= s_userDebtShares[user];
        s_userDebtShares[user] = 0;

        // calculate how much of the user's collateral the liquidator receives
        // calculate ETH collateral equivant to MyUSD value as the debt
        uint256 collateralToCoverDebt = (userDebtValue * userCollateral) / collateralValue;

        // calculate reward amount
        uint256 rewardAmount = (collateralToCoverDebt * LIQUIDATOR_REWARD) / 100;

        // calculate total amount for liquidator
        uint256 amountForLiquidator = collateralToCoverDebt + rewardAmount;

        // ensure amount for liquidator does not exceed userCollateral
        if (amountForLiquidator > userCollateral) {
            amountForLiquidator = userCollateral;
        }

        // reduce user's collateral
        s_userCollateral[user] -= amountForLiquidator;

        // transfer ETH to liquidator
        (bool success,) = payable(msg.sender).call{value: amountForLiquidator}("");
        if (!success) {
            revert Engine__TransferFailed();
        }

        // emit event to frontend
        emit Liquidation(user, msg.sender, amountForLiquidator, collateralToCoverDebt, i_oracle.getETHMyUSDPrice());
    }
}
