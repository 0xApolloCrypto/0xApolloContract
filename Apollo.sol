// SPDX-License-Identifier: Unlicensed

// Apollo PROTOCOL COPYRIGHT (C) 2022

pragma solidity ^0.8.0;
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import {SafeMath} from "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./IApollo.sol";

library SafeMathInt {
    int256 private constant MIN_INT256 = int256(1) << 255;
    int256 private constant MAX_INT256 = ~(int256(1) << 255);

    function mul(int256 a, int256 b) internal pure returns (int256) {
        int256 c = a * b;

        require(c != MIN_INT256 || (a & MIN_INT256) != (b & MIN_INT256));
        require((b == 0) || (c / b == a));
        return c;
    }

    function div(int256 a, int256 b) internal pure returns (int256) {
        require(b != -1 || a != MIN_INT256);

        return a / b;
    }

    function sub(int256 a, int256 b) internal pure returns (int256) {
        int256 c = a - b;
        require((b >= 0 && c <= a) || (b < 0 && c > a));
        return c;
    }

    function add(int256 a, int256 b) internal pure returns (int256) {
        int256 c = a + b;
        require((b >= 0 && c >= a) || (b < 0 && c < a));
        return c;
    }

    function abs(int256 a) internal pure returns (int256) {
        require(a != MIN_INT256);
        return a < 0 ? -a : a;
    }
}

contract Apollo is IApollo, Ownable {
    using SafeMath for uint256;
    using SafeMathInt for int256;

    string public constant override name = "apl";
    string public constant override symbol = "APL";
    uint8 public constant override decimals = 5;

    uint8 public constant RATE_DECIMALS = 7;
    uint256 private constant INITIAL_FRAGMENTS_SUPPLY = 600000 * 10**decimals;
    uint256 private constant PRESALE_FRAGMENTS_SUPPLY = 250000 * 10**decimals;
    uint256 private constant TOTAL_GONS = type(uint256).max - (type(uint256).max % INITIAL_FRAGMENTS_SUPPLY);
    uint256 private constant MAX_SUPPLY = 60 * 10**7 * 10**decimals;

    uint256 public override totalSupply;

    uint256 public liquidityFee = 40;
    uint256 public treasuryFee = 25;
    uint256 public safuuInsuranceFundFee = 50;
    uint256 public sellFee = 20;
    uint256 public firePitFee = 25;
    uint256 public totalFee = liquidityFee + treasuryFee + safuuInsuranceFundFee + firePitFee;
    uint256 public feeDenominator = 1000;

    uint256 public _initRebaseStartTime;
    uint256 public _lastRebasedTime;
    uint256 public _lastAddLiquidityTime;
    uint256 private _gonsPerFragment;

    IERC20 public usdcToken;
    IUniswapV2Router02 public router;
    address public autoLiquidityReceiver;
    address public treasuryReceiver;
    address public safuuInsuranceFundReceiver;
    address public firePit;
    address public pair;

    bool public swapEnabled = true;
    bool inSwap = false;
    bool public _autoRebase;
    bool public _autoAddLiquidity;

    mapping(address => bool) _isFeeExempt;
    mapping(address => uint256) private _gonBalances;
    mapping(address => mapping(address => uint256)) private _allowedFragments;
    mapping(address => bool) public blacklist;

    event LogRebase(uint256 indexed epoch, uint256 totalSupply);

    modifier validRecipient(address to) {
        require(to != address(0));
        _;
    }
    modifier swapping() {
        inSwap = true;
        _;
        inSwap = false;
    }

    constructor(
        IERC20 usdc,
        IUniswapV2Router02 _router,
        address presaleAddress
    ) {
        usdcToken = usdc;
        router = _router;
        pair = IUniswapV2Factory(_router.factory()).createPair(address(usdc), address(this));

        autoLiquidityReceiver = 0xE1A0b2a8FF9C17b80f558eC002e7E857c0D062FD; //2
        treasuryReceiver = 0xfFde24E2Ab5f2c9cbc95118777cD68a4aAF05647; //1
        safuuInsuranceFundReceiver = 0x6e1D3DD0fC635805bEE48eFDad5D6f4A3a4508BE; //3
        firePit = 0x9186E356cC60A5E07C400929E7E13503a538039a; //4

        _allowedFragments[address(this)][address(_router)] = type(uint256).max;
        _allowedFragments[presaleAddress][address(_router)] = type(uint256).max;
        usdc.approve(address(_router), type(uint256).max);

        totalSupply = INITIAL_FRAGMENTS_SUPPLY;
        _gonBalances[treasuryReceiver] =
            type(uint256).max -
            (type(uint256).max % (INITIAL_FRAGMENTS_SUPPLY - PRESALE_FRAGMENTS_SUPPLY));
        _gonBalances[presaleAddress] = type(uint256).max - (type(uint256).max % PRESALE_FRAGMENTS_SUPPLY);
        _gonsPerFragment = TOTAL_GONS.div(totalSupply);
        _initRebaseStartTime = block.timestamp;
        _lastRebasedTime = block.timestamp;
        _autoRebase = true;
        _autoAddLiquidity = true;
        _isFeeExempt[treasuryReceiver] = true;
        _isFeeExempt[address(this)] = true;
        _isFeeExempt[presaleAddress] = true;

        _transferOwnership(treasuryReceiver);
        emit Transfer(address(0), presaleAddress, PRESALE_FRAGMENTS_SUPPLY);
        emit Transfer(address(0), treasuryReceiver, INITIAL_FRAGMENTS_SUPPLY - PRESALE_FRAGMENTS_SUPPLY);
    }

    function rebase() internal {
        if (inSwap) return;
        uint256 rebaseRate;
        uint256 deltaTimeFromInit = block.timestamp - _initRebaseStartTime;
        uint256 deltaTime = block.timestamp - _lastRebasedTime;
        uint256 times = deltaTime.div(15 minutes);
        uint256 epoch = times.mul(15);

        if (deltaTimeFromInit < (365 days)) {
            rebaseRate = 2355;
        } else if (deltaTimeFromInit >= (7 * 365 days)) {
            rebaseRate = 2;
        } else if (deltaTimeFromInit >= ((15 * 365 days) / 10)) {
            rebaseRate = 14;
        } else if (deltaTimeFromInit >= (365 days)) {
            rebaseRate = 211;
        }

        for (uint256 i = 0; i < times; i++) {
            totalSupply = totalSupply.mul((10**RATE_DECIMALS).add(rebaseRate)).div(10**RATE_DECIMALS);
        }

        _gonsPerFragment = TOTAL_GONS.div(totalSupply);
        _lastRebasedTime = _lastRebasedTime.add(times.mul(15 minutes));

        IUniswapV2Pair(pair).sync();

        emit LogRebase(epoch, totalSupply);
    }

    function transfer(address to, uint256 value) external override validRecipient(to) returns (bool) {
        _transferFrom(msg.sender, to, value);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 value
    ) external override validRecipient(to) returns (bool) {
        if (_allowedFragments[from][msg.sender] != type(uint256).max) {
            _allowedFragments[from][msg.sender] = _allowedFragments[from][msg.sender].sub(
                value,
                "Insufficient Allowance"
            );
        }
        _transferFrom(from, to, value);
        return true;
    }

    function _basicTransfer(
        address from,
        address to,
        uint256 amount
    ) internal returns (bool) {
        uint256 gonAmount = amount.mul(_gonsPerFragment);
        _gonBalances[from] = _gonBalances[from].sub(gonAmount);
        _gonBalances[to] = _gonBalances[to].add(gonAmount);
        return true;
    }

    function _transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) internal returns (bool) {
        require(!blacklist[sender] && !blacklist[recipient], "in_blacklist");

        if (inSwap) {
            return _basicTransfer(sender, recipient, amount);
        }
        if (shouldRebase()) {
            rebase();
        }

        if (shouldAddLiquidity()) {
            addLiquidity();
        }

        if (shouldSwapBack()) {
            swapBack();
        }

        uint256 gonAmount = amount.mul(_gonsPerFragment);
        _gonBalances[sender] = _gonBalances[sender].sub(gonAmount);
        uint256 gonAmountReceived = shouldTakeFee(sender, recipient)
            ? takeFee(sender, recipient, gonAmount)
            : gonAmount;
        _gonBalances[recipient] = _gonBalances[recipient].add(gonAmountReceived);

        emit Transfer(sender, recipient, gonAmountReceived.div(_gonsPerFragment));
        return true;
    }

    function takeFee(
        address sender,
        address recipient,
        uint256 gonAmount
    ) internal returns (uint256) {
        uint256 _totalFee = totalFee;
        uint256 _treasuryFee = treasuryFee;

        if (recipient == pair) {
            _totalFee = totalFee.add(sellFee);
            _treasuryFee = treasuryFee.add(sellFee);
        }

        uint256 feeAmount = gonAmount.div(feeDenominator).mul(_totalFee);

        _gonBalances[firePit] = _gonBalances[firePit].add(gonAmount.div(feeDenominator).mul(firePitFee));
        _gonBalances[address(this)] = _gonBalances[address(this)].add(
            gonAmount.div(feeDenominator).mul(_treasuryFee.add(safuuInsuranceFundFee))
        );
        _gonBalances[autoLiquidityReceiver] = _gonBalances[autoLiquidityReceiver].add(
            gonAmount.div(feeDenominator).mul(liquidityFee)
        );

        emit Transfer(sender, address(this), feeAmount.div(_gonsPerFragment));
        return gonAmount.sub(feeAmount);
    }

    function addLiquidity() internal swapping {
        uint256 autoLiquidityAmount = _gonBalances[autoLiquidityReceiver].div(_gonsPerFragment);
        _gonBalances[address(this)] = _gonBalances[address(this)].add(_gonBalances[autoLiquidityReceiver]);
        _gonBalances[autoLiquidityReceiver] = 0;
        uint256 amountToLiquify = autoLiquidityAmount.div(2);
        uint256 amountToSwap = autoLiquidityAmount.sub(amountToLiquify);

        if (amountToSwap == 0) {
            return;
        }
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = address(usdcToken);

        uint256 balanceBefore = usdcToken.balanceOf(address(this));

        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountToSwap,
            0,
            path,
            address(this),
            block.timestamp
        );

        uint256 amountUsdcLiquidity = usdcToken.balanceOf(address(this)) - balanceBefore;

        if (amountToLiquify > 0 && amountUsdcLiquidity > 0) {
            router.addLiquidity(
                address(usdcToken),
                address(this),
                amountUsdcLiquidity,
                amountToLiquify,
                0,
                0,
                autoLiquidityReceiver,
                block.timestamp
            );
        }
        _lastAddLiquidityTime = block.timestamp;
    }

    function swapBack() internal swapping {
        uint256 amountToSwap = _gonBalances[address(this)].div(_gonsPerFragment);

        if (amountToSwap == 0) {
            return;
        }

        uint256 balanceBefore = usdcToken.balanceOf(address(this));
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = address(usdcToken);

        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountToSwap,
            0,
            path,
            address(this),
            block.timestamp
        );

        uint256 amountUsdcToTreasuryAndSIF = usdcToken.balanceOf(address(this)) - balanceBefore;

        usdcToken.transfer(
            treasuryReceiver,
            (amountUsdcToTreasuryAndSIF * treasuryFee) / (treasuryFee + safuuInsuranceFundFee)
        );
        usdcToken.transfer(
            safuuInsuranceFundReceiver,
            (amountUsdcToTreasuryAndSIF * safuuInsuranceFundFee) / (treasuryFee + safuuInsuranceFundFee)
        );
    }

    function withdrawAllToTreasury() external swapping onlyOwner {
        uint256 amountToSwap = _gonBalances[address(this)].div(_gonsPerFragment);
        require(amountToSwap > 0, "There is no Safuu token deposited in token contract");
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = address(usdcToken);
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountToSwap,
            0,
            path,
            treasuryReceiver,
            block.timestamp
        );
    }

    function shouldTakeFee(address from, address to) internal view returns (bool) {
        return (pair == from || pair == to) && !_isFeeExempt[from];
    }

    function shouldRebase() internal view returns (bool) {
        return
            _autoRebase &&
            (totalSupply < MAX_SUPPLY) &&
            msg.sender != pair &&
            !inSwap &&
            block.timestamp >= (_lastRebasedTime + 15 minutes);
    }

    function shouldAddLiquidity() internal view returns (bool) {
        return
            _autoAddLiquidity && !inSwap && msg.sender != pair && block.timestamp >= (_lastAddLiquidityTime + 2 days);
    }

    function shouldSwapBack() internal view returns (bool) {
        return !inSwap && msg.sender != pair;
    }

    function setAutoRebase(bool _flag) external onlyOwner {
        if (_flag) {
            _autoRebase = _flag;
            _lastRebasedTime = block.timestamp;
        } else {
            _autoRebase = _flag;
        }
    }

    function setAutoAddLiquidity(bool _flag) external onlyOwner {
        if (_flag) {
            _autoAddLiquidity = _flag;
            _lastAddLiquidityTime = block.timestamp;
        } else {
            _autoAddLiquidity = _flag;
        }
    }

    function allowance(address owner_, address spender) external view override returns (uint256) {
        return _allowedFragments[owner_][spender];
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) external returns (bool) {
        uint256 oldValue = _allowedFragments[msg.sender][spender];
        if (subtractedValue >= oldValue) {
            _allowedFragments[msg.sender][spender] = 0;
        } else {
            _allowedFragments[msg.sender][spender] = oldValue.sub(subtractedValue);
        }
        emit Approval(msg.sender, spender, _allowedFragments[msg.sender][spender]);
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) external returns (bool) {
        _allowedFragments[msg.sender][spender] = _allowedFragments[msg.sender][spender].add(addedValue);
        emit Approval(msg.sender, spender, _allowedFragments[msg.sender][spender]);
        return true;
    }

    function approve(address spender, uint256 value) external override returns (bool) {
        _allowedFragments[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function checkFeeExempt(address _addr) external view returns (bool) {
        return _isFeeExempt[_addr];
    }

    function getCirculatingSupply() public view returns (uint256) {
        return (TOTAL_GONS - _gonBalances[address(0xdead)] - _gonBalances[address(0)]) / _gonsPerFragment;
    }

    function isNotInSwap() external view returns (bool) {
        return !inSwap;
    }

    function manualSync() external {
        IUniswapV2Pair(pair).sync();
    }

    function setFeeReceivers(
        address _autoLiquidityReceiver,
        address _treasuryReceiver,
        address _safuuInsuranceFundReceiver,
        address _firePit
    ) external onlyOwner {
        autoLiquidityReceiver = _autoLiquidityReceiver;
        treasuryReceiver = _treasuryReceiver;
        safuuInsuranceFundReceiver = _safuuInsuranceFundReceiver;
        firePit = _firePit;
    }

    function getLiquidityBacking(uint256 accuracy) public view returns (uint256) {
        uint256 liquidityBalance = _gonBalances[pair].div(_gonsPerFragment);
        return accuracy.mul(liquidityBalance.mul(2)).div(getCirculatingSupply());
    }

    function setWhitelist(address _addr) external onlyOwner {
        _isFeeExempt[_addr] = true;
    }

    function setBotBlacklist(address _botAddress, bool _flag) external onlyOwner {
        require(isContract(_botAddress), "only contract address, not allowed exteranlly owned account");
        blacklist[_botAddress] = _flag;
    }

    function balanceOf(address who) external view override returns (uint256) {
        return _gonBalances[who].div(_gonsPerFragment);
    }

    function isContract(address addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }
}
