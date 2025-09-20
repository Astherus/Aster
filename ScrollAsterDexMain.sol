// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title AsterDexScroll
 * @dev Main contract for AsterDex on Scroll optimized for L2 efficiency
 */
contract AsterDexScroll is Ownable, ReentrancyGuard {
    // Constants
    string public constant name = "AsterDex Protocol";
    string public constant version = "1.0.0";
    
    // State variables
    bool public isPaused;
    uint256 public tradingFeeRate; // basis points (1/10000)
    address public treasury;
    
    struct Market {
        address oracle;
        uint256 minCollateral;
        uint256 maxLeverage;
        uint256 liquidationThreshold; // basis points below 100%
        bool isActive;
    }
    
    struct Position {
        address trader;
        bytes32 marketId;
                bool isLong;
        uint256 size;
        uint256 margin;
        uint256 entryPrice;
        uint256 entryTimestamp;
        uint256 lastFundingIndex;
    }
    
    // Storage mappings
    mapping(bytes32 => Market) public markets;
    mapping(bytes32 => Position) public positions;
    mapping(address => bytes32[]) public userPositions;
    mapping(address => bool) public supportedCollateral;
    mapping(bytes32 => uint256) public marketFundingIndex;
    mapping(bytes32 => int256) public cumulativeFundingRate;
    
    // Events - optimized for L2 gas efficiency with minimal indexed parameters
    event MarketAdded(bytes32 marketId, address oracle, uint256 maxLeverage);
    event MarketUpdated(bytes32 marketId, bool isActive);
    event CollateralUpdated(address token, bool isSupported);
    event PositionOpened(
        bytes32 indexed positionId,
        address trader,
        bytes32 marketId,
        bool isLong,
        uint256 size,
        uint256 margin,
        uint256 entryPrice
    );
    event PositionClosed(
        bytes32 indexed positionId,
        address trader,
        uint256 exitPrice,
        int256 pnl,
        uint256 fee
    );
    event PositionLiquidated(
        bytes32 indexed positionId,
        address trader,
        address liquidator,
        uint256 price
    );
    event FundingUpdated(bytes32 marketId, int256 rate, uint256 index);
    
    constructor(address _treasury) {
        require(_treasury != address(0), "Invalid treasury");
        treasury = _treasury;
        tradingFeeRate = 10; // 0.1% default
        isPaused = false;
    }
    
    // Modifiers
    modifier whenNotPaused() {
        require(!isPaused, "Trading is paused");
        _;
    }
    
    modifier marketExists(bytes32 _marketId) {
        require(markets[_marketId].isActive, "Market not active");
        _;
    }
    
    modifier validCollateral(address _token) {
        require(supportedCollateral[_token], "Unsupported collateral");
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
    
    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "Invalid treasury");
        treasury = _treasury;
    }
    
    function addMarket(
        bytes32 _marketId,
        address _oracle,
        uint256 _minCollateral,
        uint256 _maxLeverage,
        uint256 _liquidationThreshold
    ) external onlyOwner {
        require(markets[_marketId].oracle == address(0), "Market exists");
        require(_oracle != address(0), "Invalid oracle");
        require(_maxLeverage >= 1 && _maxLeverage <= 100, "Invalid leverage");
        require(_liquidationThreshold > 0 && _liquidationThreshold < 10000, "Invalid threshold");
        
        markets[_marketId] = Market({
            oracle: _oracle,
            minCollateral: _minCollateral,
            maxLeverage: _maxLeverage,
            liquidationThreshold: _liquidationThreshold,
            isActive: true
        });
        
        emit MarketAdded(_marketId, _oracle, _maxLeverage);
    }
    
    function updateMarket(
        bytes32 _marketId,
        address _oracle,
        uint256 _minCollateral,
        uint256 _maxLeverage,
        uint256 _liquidationThreshold,
        bool _isActive
    ) external onlyOwner {
        Market storage market = markets[_marketId];
        require(market.oracle != address(0), "Market does not exist");
        
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
        
        if (_liquidationThreshold > 0) {
            require(_liquidationThreshold < 10000, "Invalid threshold");
            market.liquidationThreshold = _liquidationThreshold;
        }
        
        market.isActive = _isActive;
        
        emit MarketUpdated(_marketId, _isActive);
    }
    
    function setSupportedCollateral(address _token, bool _isSupported) external onlyOwner {
        supportedCollateral[_token] = _isSupported;
        emit CollateralUpdated(_token, _isSupported);
    }
    
    function updateFundingRate(bytes32 _marketId, int256 _fundingRate) external onlyOwner marketExists(_marketId) {
        uint256 newIndex = marketFundingIndex[_marketId] + 1;
        cumulativeFundingRate[_marketId] += _fundingRate;
        marketFundingIndex[_marketId] = newIndex;
        
        emit FundingUpdated(_marketId, _fundingRate, newIndex);
    }
    
    // Core trading functions
    function openPosition(
        bytes32 _marketId,
        address _collateral,
        bool _isLong,
        uint256 _margin,
        uint256 _leverage,
        uint256 _maxSlippage
    ) external whenNotPaused nonReentrant marketExists(_marketId) validCollateral(_collateral) {
        Market memory market = markets[_marketId];
        
        // Validation
        require(_leverage >= 1 && _leverage <= market.maxLeverage, "Invalid leverage");
        require(_margin >= market.minCollateral, "Insufficient collateral");
        
        // Transfer collateral
        IERC20(_collateral).transferFrom(msg.sender, address(this), _margin);
        
        // Get price
        uint256 price = getPrice(market.oracle);
        require(price > 0, "Invalid price");
        
        // Apply slippage check if provided
        if (_maxSlippage > 0) {
            // Slippage protection logic would go here
        }
        
        // Calculate size
        uint256 size = _margin * _leverage;
        
        // Generate position ID - unique for Scroll with block.number for efficiency
        bytes32 positionId = keccak256(abi.encodePacked(
            msg.sender,
            _marketId,
            block.timestamp,
            block.number
        ));
        
        // Store position
        positions[positionId] = Position({
            trader: msg.sender,
            marketId: _marketId,
            isLong: _isLong,
            size: size,
            margin: _margin,
            entryPrice: price,
            entryTimestamp: block.timestamp,
            lastFundingIndex: marketFundingIndex[_marketId]
        });
        
        // Add to user positions list
        userPositions[msg.sender].push(positionId);
        
        emit PositionOpened(
            positionId,
            msg.sender,
            _marketId,
            _isLong,
            size,
            _margin,
            price
        );
    }
    
    function closePosition(bytes32 _positionId) external nonReentrant {
        Position memory position = positions[_positionId];
        require(position.trader == msg.sender, "Not position owner");
        require(position.size > 0, "Position not found");
        
        Market memory market = markets[position.marketId];
        
        // Get exit price
        uint256 exitPrice = getPrice(market.oracle);
        require(exitPrice > 0, "Invalid price");
        
        // Calculate PnL
        int256 pnl = calculatePnL(position, exitPrice);
        
        // Calculate and apply funding fee
        int256 fundingFee = calculateFundingFee(position);
        pnl -= fundingFee;
        
        // Calculate trading fee
        uint256 fee = (position.size * tradingFeeRate) / 10000;
        
        // Calculate return amount
        int256 returnAmount = int256(position.margin) + pnl - int256(fee);
        
        // Get collateral token (in practice would be stored with position)
        address collateralToken = getCollateralToken(position.marketId);
        
        // Transfer funds back to user if profit, or what's left after loss
        if (returnAmount > 0) {
            IERC20(collateralToken).transfer(msg.sender, uint256(returnAmount));
        }
        
        // Transfer fee to treasury
        if (fee > 0) {
            IERC20(collateralToken).transfer(treasury, fee);
        }
        
        // Clean up position
        removeUserPosition(msg.sender, _positionId);
        delete positions[_positionId];
        
        emit PositionClosed(
            _positionId,
            msg.sender,
            exitPrice,
            pnl,
            fee
        );
    }
    
    function liquidatePosition(bytes32 _positionId) external nonReentrant {
        Position memory position = positions[_positionId];
        require(position.size > 0, "Position not found");
        
        Market memory market = markets[position.marketId];
        
        // Get current price
        uint256 price = getPrice(market.oracle);
        require(price > 0, "Invalid price");
        
        // Calculate current PnL
        int256 pnl = calculatePnL(position, price);
        
        // Apply funding fee
        int256 fundingFee = calculateFundingFee(position);
        pnl -= fundingFee;
        
        // Check if position is liquidatable
        uint256 healthFactor = calculateHealthFactor(position.margin, pnl);
        require(healthFactor < market.liquidationThreshold, "Not liquidatable");
        
        // Calculate liquidator reward (5% of remaining margin)
        uint256 liquidationReward = position.margin * 5 / 100;
        
        // Transfer liquidation reward to caller
        address collateralToken = getCollateralToken(position.marketId);
        IERC20(collateralToken).transfer(msg.sender, liquidationReward);
        
        // Clean up position
        removeUserPosition(position.trader, _positionId);
        delete positions[_positionId];
        
        emit PositionLiquidated(
            _positionId,
            position.trader,
            msg.sender,
            price
        );
    }
    
    // Helper functions
    function getPrice(address _oracle) internal view returns (uint256) {
        // In practice, this would integrate with your specific oracle solution
        // This is a placeholder implementation
        return 1000; 
    }
    
    function calculatePnL(Position memory _position, uint256 _currentPrice) internal pure returns (int256) {
        int256 priceDelta = _position.isLong ? 
            int256(_currentPrice) - int256(_position.entryPrice) : 
            int256(_position.entryPrice) - int256(_currentPrice);

        return (priceDelta * int256(_position.size)) / int256(_position.entryPrice);
    }
    
    function calculateFundingFee(Position memory _position) internal view returns (int256) {
        uint256 currentIndex = marketFundingIndex[_position.marketId];
        if (currentIndex <= _position.lastFundingIndex) {
            return 0;
        }
        
        // In a real implementation, this would account for the accumulated funding rate
        // between lastFundingIndex and currentIndex
        int256 accumulatedRate = cumulativeFundingRate[_position.marketId];
        
        int256 direction = _position.isLong ? int256(1) : int256(-1);
        return (accumulatedRate * direction * int256(_position.size)) / 10000;
    }
    
    function calculateHealthFactor(uint256 _margin, int256 _pnl) internal pure returns (uint256) {
        if (_pnl >= 0) {
            return 10000; // 100% health if in profit
        }
        
        uint256 absPnl = uint256(-_pnl);
        if (absPnl >= _margin) {
            return 0; // 0% health if underwater
        }
        
        // Calculate remaining margin as percentage of original margin
        return 10000 - (absPnl * 10000 / _margin);
    }
    
    function getCollateralToken(bytes32 _marketId) internal pure returns (address) {
        // In practice, this would be stored with the market or position
        // This is a placeholder implementation
        return address(0x7BE980E327692Cf11E793A0d141D534779AF8Ef4);
    }
    
    function removeUserPosition(address _user, bytes32 _positionId) internal {
        bytes32[] storage userPositionsList = userPositions[_user];
        
        for (uint256 i = 0; i < userPositionsList.length; i++) {
            if (userPositionsList[i] == _positionId) {
                if (i < userPositionsList.length - 1) {
                    userPositionsList[i] = userPositionsList[userPositionsList.length - 1];
                }
                userPositionsList.pop();
                break;
            }
        }
    }
    
    // View functions
    function getUserPositionsCount(address _user) external view returns (uint256) {
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
        uint256 entryTimestamp,
        int256 currentPnl,
        int256 fundingFee
    ) {
        Position memory position = positions[_positionId];
        require(position.size > 0, "Position not found");
        
        // Get current price
        uint256 currentPrice = getPrice(markets[position.marketId].oracle);
        
        // Calculate current PnL
        int256 pnl = calculatePnL(position, currentPrice);
        
        // Calculate funding fee
        int256 funding = calculateFundingFee(position);
        
        return (
            position.trader,
            position.marketId,
            position.isLong,
            position.size,
            position.margin,
            position.entryPrice,
            position.entryTimestamp,
            pnl,
            funding
        );
    }
}

