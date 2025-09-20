// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title AsterDexMain
 * @dev Main contract for AsterDex perpetual trading platform on BNB Chain
 * @notice This is the entry point contract for the AsterDex protocol on BNB Chain
 */
contract AsterDexMain is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ======== Constants ========
    uint256 public constant BASIS_POINTS = 10000; // 100% in basis points
    uint256 public constant MAX_LEVERAGE = 50; // 50x max leverage
    uint256 public constant LIQUIDATION_THRESHOLD = 8000; // 80% in basis points
    address public constant TEST_CONTRACT = 0x8c56a44e9f2263009665414e443520ba2e84e2bb;
    
    // ======== State Variables ========
    bool public isPaused;
    uint256 public tradingFeeRate; // basis points
    uint256 public liquidationFeeRate; // basis points
    address public feeCollector;
    address public oracle;
    
    // ======== Market Structure ========
    struct Market {
        string symbol;
        address oracle;
        uint256 minCollateral;
        uint256 maxLeverage;
        uint256 maintenanceMargin;
        bool isActive;
        uint256 openInterestLong;
        uint256 openInterestShort;
        uint256 lastFundingTime;
        int256 cumulativeFunding;
    }
    
    // ======== Position Structure ========
    struct Position {
        address trader;
        bytes32 marketId;
        bool isLong;
        uint256 size;
        uint256 margin;
        uint256 entryPrice;
        int256 entryFundingIndex;
        uint256 timestamp;
    }
    
    // ======== Mappings ========
    mapping(bytes32 => Market) public markets;
    mapping(bytes32 => Position) public positions;
    mapping(address => bytes32[]) public userPositions;
    mapping(address => bool) public supportedCollateral;
    
    // ======== Events ========
    event MarketAdded(bytes32 indexed marketId, string symbol, address oracle);
    event MarketUpdated(bytes32 indexed marketId, bool isActive);
    event CollateralAdded(address indexed token, bool isSupported);
    event PositionOpened(
        bytes32 indexed positionId,
        address indexed trader,
        bytes32 indexed marketId,
        bool isLong,
        uint256 size,
        uint256 margin,
        uint256 entryPrice,
        uint256 leverage
    );
    event PositionClosed(
        bytes32 indexed positionId,
        address indexed trader,
        uint256 exitPrice,
        int256 realizedPnl,
        uint256 fee
    );
    event PositionLiquidated(
        bytes32 indexed positionId,
        address indexed trader,
        address liquidator,
        uint256 liquidationPrice,
        uint256 fee
    );
    event FundingUpdated(bytes32 indexed marketId, int256 fundingRate, uint256 timestamp);
    
    // ======== Constructor ========
    constructor(address _feeCollector, address _oracle) {
        require(_feeCollector != address(0), "Invalid fee collector");
        require(_oracle != address(0), "Invalid oracle address");
        
        feeCollector = _feeCollector;
        oracle = _oracle;
        tradingFeeRate = 10; // 0.1% by default
        liquidationFeeRate = 250; // 2.5% by default
        isPaused = false;
    }
    
    // ======== Modifiers ========
    modifier whenNotPaused() {
        require(!isPaused, "Protocol is paused");
        _;
    }
    
    modifier validMarket(bytes32 _marketId) {
        require(markets[_marketId].isActive, "Market not active");
        _;
    }
    
    modifier validCollateral(address _token) {
        require(supportedCollateral[_token], "Unsupported collateral");
        _;
    }
    
    // ======== External Functions ========
    
    /**
     * @dev Add a new market to the protocol
     * @param _marketId Unique ID for the market
     * @param _symbol Market symbol (e.g., "BTC-USD")
     * @param _marketOracle Oracle address for price feeds
     * @param _minCollateral Minimum collateral required
     * @param _maxLeverage Maximum allowed leverage
     * @param _maintenanceMargin Maintenance margin requirement (basis points)
     */
    function addMarket(
        bytes32 _marketId,
        string calldata _symbol,
        address _marketOracle,
        uint256 _minCollateral,
        uint256 _maxLeverage,
        uint256 _maintenanceMargin
    ) external onlyOwner {
        require(markets[_marketId].oracle == address(0), "Market already exists");
        require(_marketOracle != address(0), "Invalid oracle");
        require(_maxLeverage > 0 && _maxLeverage <= MAX_LEVERAGE, "Invalid leverage");
        require(_maintenanceMargin > 0 && _maintenanceMargin < BASIS_POINTS, "Invalid margin requirement");
        
        markets[_marketId] = Market({
            symbol: _symbol,
            oracle: _marketOracle,
            minCollateral: _minCollateral,
            maxLeverage: _maxLeverage,
            maintenanceMargin: _maintenanceMargin,
            isActive: true,
            openInterestLong: 0,
            openInterestShort: 0,
            lastFundingTime: block.timestamp,
            cumulativeFunding: 0
        });
        
        emit MarketAdded(_marketId, _symbol, _marketOracle);
    }
    
    /**
     * @dev Update an existing market
     * @param _marketId Market ID to update
     * @param _isActive New active status
     * @param _minCollateral New minimum collateral
     * @param _maxLeverage New maximum leverage
     * @param _maintenanceMargin New maintenance margin
     */
    function updateMarket(
        bytes32 _marketId,
        bool _isActive,
        uint256 _minCollateral,
        uint256 _maxLeverage,
        uint256 _maintenanceMargin
    ) external onlyOwner validMarket(_marketId) {
        Market storage market = markets[_marketId];
        
        if (_minCollateral > 0) {
            market.minCollateral = _minCollateral;
        }
        
        if (_maxLeverage > 0) {
            require(_maxLeverage <= MAX_LEVERAGE, "Invalid leverage");
            market.maxLeverage = _maxLeverage;
        }
        
        if (_maintenanceMargin > 0) {
            require(_maintenanceMargin < BASIS_POINTS, "Invalid margin requirement");
            market.maintenanceMargin = _maintenanceMargin;
        }
        
        market.isActive = _isActive;
        
        emit MarketUpdated(_marketId, _isActive);
    }
    
    /**
     * @dev Set supported collateral token
     * @param _token Collateral token address
     * @param _isSupported Whether the token is supported
     */
    function setSupportedCollateral(address _token, bool _isSupported) external onlyOwner {
        require(_token != address(0), "Invalid token address");
        supportedCollateral[_token] = _isSupported;
        emit CollateralAdded(_token, _isSupported);
    }
    
    /**
     * @dev Update protocol parameters
     * @param _tradingFeeRate New trading fee rate
     * @param _liquidationFeeRate New liquidation fee rate
     * @param _feeCollector New fee collector address
     * @param _isPaused New paused state
     */
    function updateProtocolParameters(
        uint256 _tradingFeeRate,
        uint256 _liquidationFeeRate,
        address _feeCollector,
        bool _isPaused
    ) external onlyOwner {
        if (_tradingFeeRate > 0) {
            require(_tradingFeeRate <= 500, "Fee too high"); // Max 5%
            tradingFeeRate = _tradingFeeRate;
        }
        
        if (_liquidationFeeRate > 0) {
            require(_liquidationFeeRate <= 1000, "Fee too high"); // Max 10%
            liquidationFeeRate = _liquidationFeeRate;
        }
        
        if (_feeCollector != address(0)) {
            feeCollector = _feeCollector;
        }
        
        isPaused = _isPaused;
    }
    
    /**
     * @dev Open a new trading position
     * @param _marketId Market ID to trade
     * @param _collateralToken Collateral token address
     * @param _isLong Long or short position
     * @param _margin Amount of margin/collateral
     * @param _leverage Desired leverage 
     * @param _maxSlippage Maximum allowed slippage (optional)
     */
    function openPosition(
        bytes32 _marketId,
        address _collateralToken,
        bool _isLong,
        uint256 _margin,
        uint256 _leverage,
        uint256 _maxSlippage
    ) external whenNotPaused nonReentrant validMarket(_marketId) validCollateral(_collateralToken) {
        Market storage market = markets[_marketId];
        
        // Validation
        require(_leverage >= 1 && _leverage <= market.maxLeverage, "Invalid leverage");
        require(_margin >= market.minCollateral, "Insufficient margin");
        
        // Get price from oracle
        uint256 entryPrice = getOraclePrice(market.oracle);
        require(entryPrice > 0, "Invalid price");
        
        // Check slippage if specified
        if (_maxSlippage > 0) {
            // Slippage check implementation would go here
        }
        
        // Calculate position size
        uint256 positionSize = _margin * _leverage;
        
        // Transfer collateral from user
        IERC20(_collateralToken).safeTransferFrom(msg.sender, address(this), _margin);
        
        // Generate unique position ID
        bytes32 positionId = keccak256(abi.encodePacked(
            msg.sender,
            _marketId,
            block.timestamp,
            block.number
        ));
        
        // Create position
        positions[positionId] = Position({
            trader: msg.sender,
            marketId: _marketId,
            isLong: _isLong,
            size: positionSize,
            margin: _margin,
            entryPrice: entryPrice,
            entryFundingIndex: market.cumulativeFunding,
            timestamp: block.timestamp
        });
        
        // Update market open interest
        if (_isLong) {
            market.openInterestLong += positionSize;
        } else {
            market.openInterestShort += positionSize;
        }
        
        // Add to user positions
        userPositions[msg.sender].push(positionId);
        
        emit PositionOpened(
            positionId,
            msg.sender,
            _marketId,
            _isLong,
            positionSize,
            _margin,
            entryPrice,
            _leverage
        );
    }
    
    /**
     * @dev Close an existing position
     * @param _positionId Position ID to close
     */
    function closePosition(bytes32 _positionId) external nonReentrant {
        Position memory position = positions[_positionId];
        require(position.trader == msg.sender, "Not position owner");
        require(position.size > 0, "Position not found");
        
        Market storage market = markets[position.marketId];
        
        // Get exit price
        uint256 exitPrice = getOraclePrice(market.oracle);
        require(exitPrice > 0, "Invalid price");
        
        // Calculate PnL
        int256 pnl = calculatePnL(position, exitPrice);
        
        // Calculate funding payment
        int256 fundingPayment = calculateFundingPayment(position, market.cumulativeFunding);
        
        // Calculate trading fee
        uint256 fee = (position.size * tradingFeeRate) / BASIS_POINTS;
        
        // Calculate final return amount
        int256 returnAmount = int256(position.margin) + pnl - int256(fee) - fundingPayment;
        
        // Update market open interest
        if (position.isLong) {
            market.openInterestLong -= position.size;
        } else {
            market.openInterestShort -= position.size;
        }
        
        // Get collateral token (simplified for demo)
        address collateralToken = getCollateralToken(position.marketId);
        
        // Transfer fee to collector
        if (fee > 0) {
            IERC20(collateralToken).safeTransfer(feeCollector, fee);
        }
        
        // Transfer remaining collateral and profits to trader if any
        if (returnAmount > 0) {
            IERC20(collateralToken).safeTransfer(position.trader, uint256(returnAmount));
        }
        
        // Remove position from user's list
        removeUserPosition(position.trader, _positionId);
        
        // Delete position
        delete positions[_positionId];
        
        emit PositionClosed(
            _positionId,
            position.trader,
            exitPrice,
            pnl,
            fee
        );
    }
    
    /**
     * @dev Liquidate an undercollateralized position
     * @param _positionId Position ID to liquidate
     */
    function liquidatePosition(bytes32 _positionId) external nonReentrant {
        Position memory position = positions[_positionId];
        require(position.size > 0, "Position not found");
        
        Market storage market = markets[position.marketId];
        
        // Get current price
        uint256 currentPrice = getOraclePrice(market.oracle);
        require(currentPrice > 0, "Invalid price");
        
        // Calculate PnL
        int256 pnl = calculatePnL(position, currentPrice);
        
        // Calculate funding payment
        int256 fundingPayment = calculateFundingPayment(position, market.cumulativeFunding);
        
        // Calculate remaining margin ratio
        int256 remainingMargin = int256(position.margin) + pnl - fundingPayment;
        uint256 requiredMargin = (position.size * market.maintenanceMargin) / BASIS_POINTS;
        
        // Check if position is liquidatable
        require(remainingMargin < int256(requiredMargin), "Position not liquidatable");
        
        // Calculate liquidation fee (goes to liquidator)
        uint256 liquidationFee = (position.margin * liquidationFeeRate) / BASIS_POINTS;
        
        // Update market open interest
        if (position.isLong) {
            market.openInterestLong -= position.size;
        } else {
            market.openInterestShort -= position.size;
        }
        
        // Get collateral token (simplified)
        address collateralToken = getCollateralToken(position.marketId);
        
        // Pay liquidation fee to liquidator
        if (remainingMargin > 0 && uint256(remainingMargin) >= liquidationFee) {
            IERC20(collateralToken).safeTransfer(msg.sender, liquidationFee);
        }
        
        // Remove position
        removeUserPosition(position.trader, _positionId);
        delete positions[_positionId];
        
        emit PositionLiquidated(
            _positionId,
            position.trader,
            msg.sender,
            currentPrice,
            liquidationFee
        );
    }
    
    /**
     * @dev Update funding rate for a market
     * @param _marketId Market ID to update
     */
    function updateFunding(bytes32 _marketId) external validMarket(_marketId) {
        Market storage market = markets[_marketId];
        
        // Only update funding if at least 1 hour has passed
        require(block.timestamp >= market.lastFundingTime + 1 hours, "Too early");
        
        // Calculate funding rate based on imbalance between longs and shorts
        int256 fundingRate = calculateFundingRate(
            market.openInterestLong, 
            market.openInterestShort
        );
        
        // Update market funding state
        market.cumulativeFunding += fundingRate;
        market.lastFundingTime = block.timestamp;
        
        emit FundingUpdated(_marketId, fundingRate, block.timestamp);
    }
    
    /**
     * @dev Emergency withdraw collateral (only owner)
     * @param _token Token to withdraw
     * @param _amount Amount to withdraw
     * @param _destination Destination address
     */
    function emergencyWithdraw(address _token, uint256 _amount, address _destination) external onlyOwner {
        require(_destination != address(0), "Invalid destination");
        IERC20(_token).safeTransfer(_destination, _amount);
    }
    
    /**
     * @dev Test function to interact with test contract at 0x8c56a44e9f2263009665414e443520ba2e84e2bb
     * @param _data Data to pass to the test contract
     */
    function testContractInteraction(bytes calldata _data) external onlyOwner returns (bool, bytes memory) {
        (bool success, bytes memory result) = TEST_CONTRACT.call(_data);
        return (success, result);
    }
    
    // ======== Internal Functions ========
    
    function getOraclePrice(address _oracle) internal view returns (uint256) {
        // In a real implementation, this would call the oracle contract
        // Simplified for this example
        return 1000 * 1e18;
    }
    
    function calculatePnL(Position memory _position, uint256 _currentPrice) internal pure returns (int256) {
        if (_position.isLong) {
            return int256((_currentPrice * _position.size) / _position.entryPrice - _position.size);
        } else {
            return int256(_position.size - (_currentPrice * _position.size) / _position.entryPrice);
        }
    }
    
    function calculateFundingPayment(Position memory _position, int256 _currentFundingIndex) internal pure returns (int256) {
        int256 fundingDelta = _currentFundingIndex - _position.entryFundingIndex;
        if (_position.isLong) {
            return (fundingDelta * int256(_position.size)) / 1e18;
        } else {
            return (-fundingDelta * int256(_position.size)) / 1e18;
        }
    }
    
    function calculateFundingRate(uint256 _longInterest, uint256 _shortInterest) internal pure returns (int256) {
        if (_longInterest == 0 || _shortInterest == 0) {
            return 0;
        }
        
        // Calculate imbalance ratio
        if (_longInterest > _shortInterest) {
            uint256 ratio = (_longInterest * 1e18) / _shortInterest;
            return int256((ratio - 1e18) / 100); // Scale down the funding rate
        } else {
            uint256 ratio = (_shortInterest * 1e18) / _longInterest;
            return -int256((ratio - 1e18) / 100); // Negative funding rate when shorts > longs
        }
    }
    
    function getCollateralToken(bytes32) internal pure returns (address) {
        // In a real implementation, this would be stored in the Market struct
        // For this example, we'll use a placeholder BUSD address
        return 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56; // BUSD on BNB Chain
    }
    
    function removeUserPosition(address _trader, bytes32 _positionId) internal {
        bytes32[] storage userPositionsList = userPositions[_trader];
        
        for (uint i = 0; i < userPositionsList.length; i++) {
            if (userPositionsList[i] == _positionId) {
                if (i < userPositionsList.length - 1) {
                    userPositionsList[i] = userPositionsList[userPositionsList.length - 1];
                }
                userPositionsList.pop();
                break;
            }
        }
    }
    
    // ======== View Functions ========
    
    function getUserPositionsCount(address _trader) external view returns (uint256) {
        return userPositions[_trader].length;
    }
    
    function getUserPositions(address _trader) external view returns (bytes32[] memory) {
        return userPositions[_trader];
    }
    
    function getPositionLiquidationPrice(bytes32 _positionId) public view returns (uint256) {
        Position memory position = positions[_positionId];
        require(position.size > 0, "Position not found");
        
        Market memory market = markets[position.marketId];
        
        uint256 liquidationRatio = market.maintenanceMargin;
        uint256 entryPrice = position.entryPrice;
        
        if (position.isLong) {
            // For long positions, price needs to go down to get liquidated
            return (entryPrice * (BASIS_POINTS - liquidationRatio)) / BASIS_POINTS;
        } else {
            // For short positions, price needs to go up to get liquidated
            return (entryPrice * (BASIS_POINTS + liquidationRatio)) / BASIS_POINTS;
        }
    }
    
    function getPositionHealth(bytes32 _positionId) external view returns (uint256) {
        Position memory position = positions[_positionId];
        require(position.size > 0, "Position not found");
        
        Market memory market = markets[position.marketId];
        
        // Get current price
        uint256 currentPrice = getOraclePrice(market.oracle);
        
        // Calculate PnL
        int256 pnl = calculatePnL(position, currentPrice);
        
        // Calculate funding payment
        int256 fundingPayment = calculateFundingPayment(position, market.cumulativeFunding);
        
        // Calculate remaining margin
        int256 remainingMargin = int256(position.margin) + pnl - fundingPayment;
        if (remainingMargin <= 0) {
            return 0;
        }
        
        // Calculate health ratio (remaining margin / initial margin) * 100%
        return (uint256(remainingMargin) * BASIS_POINTS) / position.margin;
    }
}
