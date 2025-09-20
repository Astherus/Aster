// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title AsterDexArbitrum
 * @dev Main contract for AsterDex on Arbitrum with optimized gas usage
 */
contract AsterDexArbitrum is Ownable, ReentrancyGuard {
    // Constants
    string public constant name = "AsterDex Protocol";
    string public constant version = "1.0.0";
    
    // State variables
    bool public isPaused;
    uint256 public tradingFeeRate; // basis points (1/10000)
    address public feeCollector;
    
    struct Market {
        address oracle;
        uint256 minCollateral;
        uint256 maxLeverage;
        uint256 maintenanceMargin; // basis points
        bool isActive;
    }
    
    struct Position {
        address trader;
        bytes32 marketId;
        bool isLong;
        uint256 size;
        uint256 margin;
        uint256 entryPrice;
        uint256 lastFundingIndex;
        uint256 timestamp;
    }
    
    // Mappings
    mapping(bytes32 => Market) public markets;
    mapping(bytes32 => Position) public positions;
    mapping(address => bytes32[]) public userPositions;
    mapping(address => bool) public allowedCollateral;
    mapping(bytes32 => uint256) public fundingIndexes;
    mapping(bytes32 => int256) public cumulativeFunding;
    
    // Events
    event MarketCreated(bytes32 indexed marketId, address oracle, uint256 maxLeverage);
    event MarketUpdated(bytes32 indexed marketId, bool isActive);
    event CollateralUpdated(address token, bool isAllowed);
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
        uint256 closePrice,
        int256 pnl,
        uint256 fee
    );
    event PositionLiquidated(
        bytes32 indexed positionId,
        address indexed trader,
        address liquidator,
        uint256 liquidationPrice,
        uint256 fee
    );
    event FundingRateUpdated(
        bytes32 indexed marketId,
        int256 fundingRate,
        uint256 fundingIndex
    );
    
    // Constructor
    constructor(address _feeCollector) {
        require(_feeCollector != address(0), "Invalid fee collector");
        feeCollector = _feeCollector;
        tradingFeeRate = 10; // 0.1% by default (10 bps)
        isPaused = false;
    }
    
    // Modifiers
    modifier whenNotPaused() {
        require(!isPaused, "Trading is paused");
        _;
    }
    
    modifier validMarket(bytes32 _marketId) {
        require(markets[_marketId].isActive, "Market not active");
        _;
    }
    
    modifier validCollateral(address _token) {
        require(allowedCollateral[_token], "Collateral not allowed");
        _;
    }
    
    // Admin functions
    function setPaused(bool _isPaused) external onlyOwner {
        isPaused = _isPaused;
    }
    
    function setTradingFeeRate(uint256 _tradingFeeRate) external onlyOwner {
        require(_tradingFeeRate <= 500, "Fee too high"); // Max 5%
        tradingFeeRate = _tradingFeeRate;
    }
    
    function setFeeCollector(address _feeCollector) external onlyOwner {
        require(_feeCollector != address(0), "Invalid address");
        feeCollector = _feeCollector;
    }
    
    function createMarket(
        bytes32 _marketId,
        address _oracle,
        uint256 _minCollateral,
        uint256 _maxLeverage,
        uint256 _maintenanceMargin
    ) external onlyOwner {
        require(markets[_marketId].oracle == address(0), "Market already exists");
        require(_oracle != address(0), "Invalid oracle");
        require(_maxLeverage >= 1 && _maxLeverage <= 100, "Invalid leverage");
        require(_maintenanceMargin >= 100 && _maintenanceMargin <= 5000, "Invalid margin");
        
        markets[_marketId] = Market({
            oracle: _oracle,
            minCollateral: _minCollateral,
            maxLeverage: _maxLeverage,
            maintenanceMargin: _maintenanceMargin,
            isActive: true
        });
        
        emit MarketCreated(_marketId, _oracle, _maxLeverage);
    }
    
    function updateMarket(
        bytes32 _marketId,
        address _oracle,
        uint256 _minCollateral,
        uint256 _maxLeverage,
        uint256 _maintenanceMargin,
        bool _isActive
    ) external onlyOwner {
        require(markets[_marketId].oracle != address(0), "Market doesn't exist");
        
        Market storage market = markets[_marketId];
        
        if (_oracle != address(0)) {
            market.oracle = _oracle;
        }
        
        if (_minCollateral > 0) {
            market.minCollateral = _minCollateral;
        }
        
        if (_maxLeverage > 0) {
            require(_maxLeverage >= 1 && _maxLeverage <= 100, "Invalid leverage");
            market.maxLeverage = _maxLeverage;
        }
        
        if (_maintenanceMargin > 0) {
            require(_maintenanceMargin >= 100 && _maintenanceMargin <= 5000, "Invalid margin");
            market.maintenanceMargin = _maintenanceMargin;
        }
        
        market.isActive = _isActive;
        
        emit MarketUpdated(_marketId, _isActive);
    }
    
    function setAllowedCollateral(address _token, bool _isAllowed) external onlyOwner {
        allowedCollateral[_token] = _isAllowed;
        emit CollateralUpdated(_token, _isAllowed);
    }
    
    function updateFundingRate(
        bytes32 _marketId,
        int256 _fundingRate
    ) external onlyOwner validMarket(_marketId) {
        uint256 newIndex = fundingIndexes[_marketId] + 1;
        cumulativeFunding[_marketId] += _fundingRate;
        fundingIndexes[_marketId] = newIndex;
        
        emit FundingRateUpdated(_marketId, _fundingRate, newIndex);
    }
    
    // Core trading functions
    function openPosition(
        bytes32 _marketId,
        address _collateralToken,
        bool _isLong,
        uint256 _margin,
        uint256 _leverage,
        uint256 _maxSlippage
    ) external whenNotPaused nonReentrant validMarket(_marketId) validCollateral(_collateralToken) {
        Market memory market = markets[_marketId];
        
        // Validate parameters
        require(_leverage >= 1 && _leverage <= market.maxLeverage, "Invalid leverage");
        require(_margin >= market.minCollateral, "Margin too small");
        
        // Transfer collateral from user
        IERC20(_collateralToken).transferFrom(msg.sender, address(this), _margin);
        
        // Get price from oracle
        uint256 entryPrice = getOraclePrice(market.oracle);
        require(entryPrice > 0, "Invalid price");
        
        // Check slippage if provided
        if (_maxSlippage > 0) {
            // Slippage check logic here
        }
        
        // Calculate position size
        uint256 positionSize = _margin * _leverage;
        
        // Generate position ID
        bytes32 positionId = keccak256(abi.encodePacked(
            msg.sender,
            _marketId,
            block.timestamp
        ));
        
        // Store position
        positions[positionId] = Position({
            trader: msg.sender,
            marketId: _marketId,
            isLong: _isLong,
            size: positionSize,
            margin: _margin,
            entryPrice: entryPrice,
            lastFundingIndex: fundingIndexes[_marketId],
            timestamp: block.timestamp
        });
        
        // Track user positions
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
    
    function closePosition(bytes32 _positionId) external nonReentrant {
        Position memory position = positions[_positionId];
        require(position.trader == msg.sender, "Not position owner");
        require(position.size > 0, "Position already closed");
        
        Market memory market = markets[position.marketId];
        
        // Get price from oracle
        uint256 closePrice = getOraclePrice(market.oracle);
        require(closePrice > 0, "Invalid price");
        
        // Calculate PnL
        int256 pnl = calculatePnL(position, closePrice);
        
        // Calculate funding fee
        int256 fundingFee = calculateFundingFee(position);
        
        // Calculate trading fee
        uint256 tradingFee = position.size * tradingFeeRate / 10000;
        
        // Transfer fees to fee collector
        if (tradingFee > 0) {
            // Logic to transfer trading fee
            // This is a simplified implementation
        }
        
        // Calculate return amount
        uint256 returnAmount;
        address collateralToken = getCollateralToken(position.marketId);
        
        int256 totalPnl = pnl - fundingFee;
        int256 finalAmount = int256(position.margin) + totalPnl - int256(tradingFee);
        
        if (finalAmount > 0) {
            returnAmount = uint256(finalAmount);
            IERC20(collateralToken).transfer(msg.sender, returnAmount);
        }
        
        // Clean up
        removeUserPosition(msg.sender, _positionId);
        delete positions[_positionId];
        
        emit PositionClosed(
            _positionId,
            msg.sender,
            closePrice,
            pnl,
            tradingFee
        );
    }
    
    function liquidatePosition(bytes32 _positionId) external nonReentrant {
        Position memory position = positions[_positionId];
        require(position.size > 0, "Position not found");
        
        Market memory market = markets[position.marketId];
        
        // Get price from oracle
        uint256 currentPrice = getOraclePrice(market.oracle);
        require(currentPrice > 0, "Invalid price");
        
        // Check if position is liquidatable
        bool isLiquidatable = isPositionLiquidatable(position, currentPrice, market.maintenanceMargin);
        require(isLiquidatable, "Position not liquidatable");
        
        // Calculate liquidation fee (e.g., 3% of margin)
        uint256 liquidationFee = position.margin * 3 / 100;
        
        // Transfer liquidation fee to caller
        address collateralToken = getCollateralToken(position.marketId);
        IERC20(collateralToken).transfer(msg.sender, liquidationFee);
        
        // Clean up
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
    
    // Helper functions
    function getOraclePrice(address _oracle) public view returns (uint256) {
        // This would integrate with your chosen oracle solution
        // For this template, we return a placeholder value
        return 1000;
    }
    
    function calculatePnL(Position memory _position, uint256 _closePrice) internal pure returns (int256) {
        int256 priceDelta = _position.isLong ? 
            int256(_closePrice) - int256(_position.entryPrice) : 
            int256(_position.entryPrice) - int256(_closePrice);
        
        return (priceDelta * int256(_position.size)) / int256(_position.entryPrice);
    }
    
    function calculateFundingFee(Position memory _position) internal view returns (int256) {
        // Calculate funding based on the difference between current and entry funding indexes
        uint256 currentIndex = fundingIndexes[_position.marketId];
        uint256 entryIndex = _position.lastFundingIndex;
        
        if (currentIndex <= entryIndex) {
            return 0;
        }
        
        int256 fundingDelta = cumulativeFunding[_position.marketId];
        int256 fundingFee = _position.isLong ? fundingDelta : -fundingDelta;
        
        return (fundingFee * int256(_position.size)) / 10000;
    }
    
    function isPositionLiquidatable(
        Position memory _position, 
        uint256 _currentPrice,
        uint256 _maintenanceMargin
    ) internal pure returns (bool) {
        // Calculate current PnL
        int256 pnl = calculatePnL(_position, _currentPrice);
        
        // Calculate remaining margin after PnL
        int256 remainingMargin = int256(_position.margin) + pnl;
        
        // Calculate required maintenance margin
        uint256 requiredMargin = (_position.size * _maintenanceMargin) / 10000;
        
        // Position is liquidatable if remaining margin < required maintenance margin
        return remainingMargin < int256(requiredMargin);
    }
    
    function getCollateralToken(bytes32 _marketId) internal pure returns (address) {
        // In practice, you would store this information in the Market struct
        // This is a simplified implementation
        return address(0x9E36CB86a159d479cEd94Fa05036f235Ac40E1d5);
    }
    
    function removeUserPosition(address _user, bytes32 _positionId) internal {
        bytes32[] storage userPositionsList = userPositions[_user];
        
        for (uint256 i = 0; i < userPositionsList.length; i++) {
            if (userPositionsList[i] == _positionId) {
                // Replace with the last element and pop
                if (i < userPositionsList.length - 1) {
                    userPositionsList[i] = userPositionsList[userPositionsList.length - 1];
                }
                userPositionsList.pop();
                break;
            }
        }
    }
    
    // View functions
    function getUserPositionCount(address _user) external view returns (uint256) {
        return userPositions[_user].length;
    }
    
    function getUserPositions(address _user) external view returns (bytes32[] memory) {
        return userPositions[_user];
    }
    
    function getPositionDetails(bytes32 _positionId) external view returns (
        address trader,
        bytes32 marketId,
        bool isLong,
        uint256 size,
        uint256 margin,
        uint256 entryPrice,
        uint256 timestamp,
        uint256 lastFundingIndex
    ) {
        Position memory position = positions[_positionId];
        return (
            position.trader,
            position.marketId,
            position.isLong,
            position.size,
            position.margin,
            position.entryPrice,
            position.timestamp,
            position.lastFundingIndex
        );
    }
    
    function getMarketDetails(bytes32 _marketId) external view returns (
        address oracle,
        uint256 minCollateral,
        uint256 maxLeverage,
        uint256 maintenanceMargin,
        bool isActive
    ) {
        Market memory market = markets[_marketId];
        return (
            market.oracle,
            market.minCollateral,
            market.maxLeverage,
            market.maintenanceMargin,
            market.isActive
        );
    }
}
