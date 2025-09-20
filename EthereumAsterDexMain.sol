// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title AsterDexMain
 * @dev Main contract for AsterDex on Ethereum
 */
contract AsterDexMain is Ownable, ReentrancyGuard {
    string public constant name = "AsterDex Protocol";
    string public constant version = "1.0.0";
    
    bool public isPaused;
    uint256 public tradingFeeRate; // basis points (1/10000)
    
    struct PerpMarket {
        address oracle;        // Chainlink price feed
        uint256 minCollateral; // Minimum collateral amount in USD
        uint256 maxLeverage;   // Maximum leverage (e.g. 100x = 10000)
        uint256 liquidationThreshold; // Percentage of collateral that triggers liquidation
        bool isActive;         // Market status
    }
    
    struct Position {
        address trader;        // Position owner
        bytes32 marketId;      // Market identifier
        bool isLong;           // Long or short
        uint256 size;          // Position size in USD
        uint256 collateral;    // Collateral amount in token
        uint256 entryPrice;    // Entry price in USD
        uint256 entryFunding;  // Funding index at entry
        uint256 leverage;      // Position leverage
        uint256 timestamp;     // Position creation timestamp
    }
    
    // Mappings
    mapping(bytes32 => PerpMarket) public markets;
    mapping(bytes32 => Position) public positions;
    mapping(address => bytes32[]) public userPositions;
    mapping(address => bool) public supportedCollateral;
    
    // Events
    event MarketAdded(bytes32 indexed marketId, address oracle, uint256 maxLeverage);
    event MarketUpdated(bytes32 indexed marketId, address oracle, uint256 maxLeverage);
    event PositionOpened(
        bytes32 indexed positionId,
        address indexed trader,
        bytes32 indexed marketId,
        bool isLong,
        uint256 collateral, 
        uint256 size,
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
    
    constructor(uint256 _tradingFeeRate) {
        tradingFeeRate = _tradingFeeRate;
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
    
    function addMarket(
        bytes32 _marketId,
        address _oracle,
        uint256 _minCollateral,
        uint256 _maxLeverage,
        uint256 _liquidationThreshold
    ) external onlyOwner {
        require(!markets[_marketId].isActive, "Market already exists");
        require(_oracle != address(0), "Invalid oracle address");
        require(_maxLeverage >= 1 && _maxLeverage <= 100, "Invalid max leverage");
        require(_liquidationThreshold > 0 && _liquidationThreshold < 100, "Invalid liquidation threshold");
        
        markets[_marketId] = PerpMarket({
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
        require(markets[_marketId].isActive, "Market does not exist");
        
        if (_oracle != address(0)) {
            markets[_marketId].oracle = _oracle;
        }
        
        if (_minCollateral > 0) {
            markets[_marketId].minCollateral = _minCollateral;
        }
        
        if (_maxLeverage > 0) {
            require(_maxLeverage >= 1 && _maxLeverage <= 100, "Invalid max leverage");
            markets[_marketId].maxLeverage = _maxLeverage;
        }
        
        if (_liquidationThreshold > 0) {
            require(_liquidationThreshold < 100, "Invalid liquidation threshold");
            markets[_marketId].liquidationThreshold = _liquidationThreshold;
        }
        
        markets[_marketId].isActive = _isActive;
        
        emit MarketUpdated(_marketId, markets[_marketId].oracle, markets[_marketId].maxLeverage);
    }
    
    function addSupportedCollateral(address _token) external onlyOwner {
        require(_token != address(0), "Invalid token");
        supportedCollateral[_token] = true;
    }
    
    function removeSupportedCollateral(address _token) external onlyOwner {
        supportedCollateral[_token] = false;
    }
    
    // Trading functions
    function openPosition(
        bytes32 _marketId,
        address _collateralToken,
        bool _isLong,
        uint256 _collateralAmount,
        uint256 _leverage,
        uint256 _slippage
    ) external whenNotPaused nonReentrant validMarket(_marketId) validCollateral(_collateralToken) returns (bytes32) {
        PerpMarket memory market = markets[_marketId];
        
        // Validate parameters
        require(_leverage >= 1 && _leverage <= market.maxLeverage, "Invalid leverage");
        require(_collateralAmount > 0, "Zero collateral");
        uint256 collateralValueUsd = getCollateralValue(_collateralToken, _collateralAmount);
        require(collateralValueUsd >= market.minCollateral, "Collateral too small");
        
        // Transfer collateral from user
        IERC20(_collateralToken).transferFrom(msg.sender, address(this), _collateralAmount);
        
        // Get current price from oracle
        uint256 currentPrice = getPrice(market.oracle);
        
        // Calculate position size and check slippage
        uint256 positionSize = collateralValueUsd * _leverage;
        
        // Generate position ID
        bytes32 positionId = keccak256(abi.encodePacked(
            msg.sender,
            _marketId,
            block.timestamp,
            blockhash(block.number - 1)
        ));
        
        // Create and store position
        positions[positionId] = Position({
            trader: msg.sender,
            marketId: _marketId,
            isLong: _isLong,
            size: positionSize,
            collateral: _collateralAmount,
            entryPrice: currentPrice,
            entryFunding: getCurrentFundingIndex(_marketId),
            leverage: _leverage,
            timestamp: block.timestamp
        });
        
        // Add to user's positions
        userPositions[msg.sender].push(positionId);
        
        emit PositionOpened(
            positionId,
            msg.sender,
            _marketId,
            _isLong,
            _collateralAmount,
            positionSize,
            currentPrice,
            _leverage
        );
        
        return positionId;
    }
    
    function closePosition(bytes32 _positionId) external nonReentrant {
        Position memory position = positions[_positionId];
        require(position.trader == msg.sender, "Not position owner");
        require(position.size > 0, "Position already closed");
        
        PerpMarket memory market = markets[position.marketId];
        
        // Get current price from oracle
        uint256 currentPrice = getPrice(market.oracle);
        
        // Calculate PnL
        (int256 pnl, uint256 fee) = calculatePnL(position, currentPrice);
        
        // Calculate collateral return amount
        uint256 returnAmount;
        address collateralToken = getCollateralToken(_positionId);
        
        if (pnl >= 0) {
            returnAmount = position.collateral + uint256(pnl) - fee;
        } else {
            int256 remaining = int256(position.collateral) + pnl - int256(fee);
            returnAmount = remaining > 0 ? uint256(remaining) : 0;
        }
        
        // Clean up position
        delete positions[_positionId];
        
        // Remove from user positions array
        removeUserPosition(msg.sender, _positionId);
        
        // Transfer funds back to user
        if (returnAmount > 0) {
            IERC20(collateralToken).transfer(msg.sender, returnAmount);
        }
        
        emit PositionClosed(
            _positionId,
            msg.sender,
            currentPrice,
            pnl,
            fee
        );
    }
    
    function liquidatePosition(bytes32 _positionId) external nonReentrant {
        Position memory position = positions[_positionId];
        require(position.size > 0, "Position not found or closed");
        
        PerpMarket memory market = markets[position.marketId];
        
        // Get current price
        uint256 currentPrice = getPrice(market.oracle);
        
        // Calculate current PnL
        (int256 pnl, ) = calculatePnL(position, currentPrice);
        
        // Check if position is liquidatable
        int256 equityPercentage = (int256(position.collateral) + pnl) * 100 / int256(position.collateral);
        
        require(equityPercentage <= int256(market.liquidationThreshold), "Cannot liquidate yet");
        
        // Calculate liquidation fee
        uint256 liquidationFee = position.collateral * 3 / 100; // 3% fee to liquidator
        
        // Clean up position
        delete positions[_positionId];
        
        // Remove from user positions array
        removeUserPosition(position.trader, _positionId);
        
        // Transfer liquidation fee to caller
        address collateralToken = getCollateralToken(_positionId);
        if (liquidationFee > 0) {
            IERC20(collateralToken).transfer(msg.sender, liquidationFee);
        }
        
        emit PositionLiquidated(
            _positionId,
            position.trader,
            msg.sender,
            currentPrice,
            liquidationFee
        );
    }
    
    // Helper functions
    function getPrice(address _oracle) internal view returns (uint256) {
        AggregatorV3Interface oracle = AggregatorV3Interface(_oracle);
        (,int256 price,,,) = oracle.latestRoundData();
        require(price > 0, "Invalid price");
        return uint256(price);
    }
    
    function calculatePnL(Position memory _position, uint256 _currentPrice) internal pure returns (int256, uint256) {
        int256 priceDelta = _position.isLong ? 
            int256(_currentPrice) - int256(_position.entryPrice) : 
            int256(_position.entryPrice) - int256(_currentPrice);
        
        int256 pnlPercentage = (priceDelta * 10000) / int256(_position.entryPrice);
        int256 rawPnl = (pnlPercentage * int256(_position.size)) / 10000;
        
        // Calculate trading fee
        uint256 fee = (_position.size * 10) / 10000; // 0.1% fee
        
        return (rawPnl, fee);
    }
    
    function getCollateralValue(address _token, uint256 _amount) internal view returns (uint256) {
        // In production, this would use a price oracle
        // For simplicity, we return a fixed value
        return _amount; // Assuming 1:1 with USD for this example
    }
    
    function getCurrentFundingIndex(bytes32 _marketId) internal view returns (uint256) {
        // In production, this would track the accumulated funding rate
        return block.timestamp; // Placeholder
    }
    
    function getCollateralToken(bytes32 _positionId) internal pure returns (address) {
        // In production, this would retrieve the correct token from position data
        return address(0x604DD02d620633Ae427888d41bfd15e38483736E); // Placeholder
    }
    
    function removeUserPosition(address _user, bytes32 _positionId) internal {
        bytes32[] storage userPositionsList = userPositions[_user];
        for (uint256 i = 0; i < userPositionsList.length; i++) {
            if (userPositionsList[i] == _positionId) {
                if (i != userPositionsList.length - 1) {
                    userPositionsList[i] = userPositionsList[userPositionsList.length - 1];
                }
                userPositionsList.pop();
                break;
            }
        }
    }
    
    function getUserPositions(address _user) external view returns (bytes32[] memory) {
        return userPositions[_user];
    }
}
