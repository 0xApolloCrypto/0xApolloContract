// SPDX-License-Identifier: AGPL-3.0-or-later

// Apollo PROTOCOL COPYRIGHT (C) 2022

pragma solidity ^0.8.0;
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "./Ownable.sol";
import "./IApollo.sol";

// import "hardhat/console.sol";

// \/\/\s*console\.log\s*.+?\);
// https://regex101.com/r/n9cEvI/1

/******* comment *********

(console\.log.+?\);)
//$1

 */

contract Vault is Ownable {
    IUniswapV2Router02 public router;

    constructor(
        IUniswapV2Router02 _router,
        IERC20 apollo,
        IERC20 usdc
    ) {
        router = _router;
        usdc.approve(address(_router), type(uint256).max);
        usdc.approve(msg.sender, type(uint256).max);
    }

    function approveFor(IERC20 token, address spender) public onlyOwner {
        token.approve(spender, type(uint256).max);
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    )
        public
        virtual
        returns (
            uint256 amountA,
            uint256 amountB,
            uint256 liquidity
        )
    {
        //console.log("Apollo::Vault::addLiquidity:entry");
        //console.log("Apollo::Vault::addLiquidity:tokenA,tokenB,amountADesired", tokenA, tokenB, amountADesired);
        // console.log(
        //     "Apollo::Vault::addLiquidity:amountBDesired,amountAMin,amountBMin",
        //     amountBDesired,
        //     amountAMin,
        //     amountBMin
        // );
        //console.log("Apollo::Vault::addLiquidity:to,deadline", to, deadline);
        (amountA, amountB, liquidity) = router.addLiquidity(
            tokenA,
            tokenB,
            amountADesired,
            amountBDesired,
            amountAMin,
            amountBMin,
            to,
            deadline
        );
        //console.log("Apollo::Vault::addLiquidity:end:amountA,amountB,liquidity", amountA, amountB, liquidity);
    }

    fallback() external {
        //console.log("Apollo::Vault::fallback:entry");
        // console.logBytes4(msg.sig);
        // console.logBytes(msg.data);
        (bool success, bytes memory data) = address(router).call(msg.data);
        require(success, "forward router faild");
        //console.log("Apollo::Vault::fallback:end");
        // console.logBytes(msg.data);
    }
}

interface BalanceAble {
    function balanceOf(address user) external view returns (uint256);
}

contract Apollo is IApollo, Ownable {
    string public constant override name = "apl pre release";
    string public constant override symbol = "preAPL";
    uint8 public constant override decimals = 5;

    uint8 public constant RATE_DECIMALS = 7;
    uint256 private constant INITIAL_FRAGMENTS_SUPPLY = 300000 * 10**decimals;
    uint256 private constant PRESALE_FRAGMENTS_SUPPLY = 250000 * 10**decimals;
    uint256 private constant TOTAL_GONS = type(uint256).max - (type(uint256).max % INITIAL_FRAGMENTS_SUPPLY);
    uint256 private constant MAX_SUPPLY = 3000000000 * 10**decimals;

    uint256 public constant liquidityFee = 40;
    uint256 public constant treasuryFee = 25;
    uint256 public constant apolloInsuranceFundFee = 50;
    uint256 public constant sellFee = 20;
    uint256 public constant burnFee = 25;
    uint256 public constant totalFee = liquidityFee + treasuryFee + apolloInsuranceFundFee + burnFee;
    uint256 public constant feeDenominator = 1000; // ‰

    uint256 public immutable deployedAt;

    uint256 public override totalSupply;

    uint256 public lastRebasedTime;
    uint256 public lastAddLiquidityTime;
    uint256 private _gonsPerFragment;

    // Anti the bots and whale on fair launch
    uint256 public maxSafeSwapAmount;
    uint256 public safeSwapInterval;
    uint256 public botTaxFee;
    uint256 public whaleTaxFee;
    // ------------------------------

    // circuit breaker Anti dump for panic selling
    uint256 public constant epochDuration = 15 minutes;
    uint256 public circuitBreakerPriceThreshold;
    uint256 public circuitBreakerBuyTaxFee;
    uint256 public circuitBreakerSellTaxFee;
    // ------------------------

    IERC20 public usdcToken;
    IUniswapV2Router02 public router;
    address public autoLiquidityReceiver;
    address public treasuryReceiver;
    address public apolloInsuranceFundReceiver;
    address public constant burnPool = address(0xdead);
    address public pair;
    address public firePool;
    Vault public apolloVault;
    BalanceAble public apolloNft;

    bool _inSwap;
    bool public autoRebase;
    bool public autoAddLiquidity;

    mapping(address => bool) public isFeeExempt;
    mapping(address => bool) public isFirePool;
    mapping(address => uint256) private _gonBalances;
    mapping(address => mapping(address => uint256)) private _allowedFragments;
    mapping(address => bool) public blacklist;
    mapping(address => uint256) public lastSwapAt;
    mapping(uint256 => uint256) public priceBycircuitBreakerEpoch;
    mapping(uint256 => bool) public shouldCircuitBreakerByEpoch;

    event LogRebase(uint256 epoch, uint256 times, uint256 totalSupply);
    event LogFire(address indexed from, address indexed receiver, address origin, uint256 amount);
    event LogCircuitBreaker(
        address indexed from,
        uint256 epoch,
        uint256 amount,
        uint256 beforePrice,
        uint256 afterPrice
    );

    modifier validRecipient(address to) {
        require(to != address(0));
        _;
    }
    modifier swapping() {
        _inSwap = true;
        _;
        _inSwap = false;
    }

    constructor(
        IERC20 usdc,
        IUniswapV2Router02 _router,
        address presaleAddress
    ) {
        deployedAt = block.timestamp;
        apolloVault = new Vault(_router, IERC20(this), usdc);
        maxSafeSwapAmount = 100 * 10**decimals;
        safeSwapInterval = 1 minutes;
        whaleTaxFee = 490; // ‰
        botTaxFee = 490; // ‰

        // circuit breaker
        circuitBreakerPriceThreshold = 50; // ‰
        circuitBreakerBuyTaxFee = 70; // ‰
        circuitBreakerSellTaxFee = 320; // ‰

        usdcToken = usdc;
        router = _router;
        pair = IUniswapV2Factory(_router.factory()).createPair(address(usdc), address(this));

        autoLiquidityReceiver = 0xE1A0b2a8FF9C17b80f558eC002e7E857c0D062FD; //2
        treasuryReceiver = 0xc8E1561A5CCE55D08EEDE7B09452b026eFDD31CB; //6
        apolloInsuranceFundReceiver = 0x6e1D3DD0fC635805bEE48eFDad5D6f4A3a4508BE; //3

        _allowedFragments[address(this)][address(_router)] = type(uint256).max;
        _allowedFragments[presaleAddress][address(_router)] = type(uint256).max;
        _allowedFragments[address(apolloVault)][address(_router)] = type(uint256).max;
        usdc.approve(address(_router), type(uint256).max);

        totalSupply = INITIAL_FRAGMENTS_SUPPLY;

        // save gas
        uint256 initalGonPerFragment = TOTAL_GONS / totalSupply;
        _gonsPerFragment = initalGonPerFragment;
        _gonBalances[treasuryReceiver] = (INITIAL_FRAGMENTS_SUPPLY - PRESALE_FRAGMENTS_SUPPLY) * initalGonPerFragment;
        _gonBalances[presaleAddress] = PRESALE_FRAGMENTS_SUPPLY * initalGonPerFragment;

        lastRebasedTime = block.timestamp;
        autoRebase = true;
        autoAddLiquidity = true;
        isFeeExempt[treasuryReceiver] = true;
        isFeeExempt[address(this)] = true;
        isFeeExempt[presaleAddress] = true;

        _transferOwnership(tx.origin);

        emit Transfer(address(0), presaleAddress, PRESALE_FRAGMENTS_SUPPLY);
        emit Transfer(address(0), treasuryReceiver, INITIAL_FRAGMENTS_SUPPLY - PRESALE_FRAGMENTS_SUPPLY);
    }

    // function initlizeVault() public onlyOwner {
    //     Vault vault = new Vault(address(router));
    //     isFeeExempt[address(vault)] = true;
    //     apolloVault = vault;
    //     vault.addToken(address(usdcToken));
    //     vault.addToken(address(this));
    // }

    function rebase() internal {
        if (_inSwap) return;
        //console.log("Apollo::rebase", block.number, block.timestamp);
        uint256 rebaseRate;
        uint256 deltaTimeFromInit = block.timestamp - deployedAt;
        uint256 deltaTime = block.timestamp - lastRebasedTime;
        uint256 times = deltaTime / epochDuration;
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
            totalSupply = (totalSupply * (10**RATE_DECIMALS + rebaseRate)) / (10**RATE_DECIMALS);
        }

        _gonsPerFragment = TOTAL_GONS / totalSupply;
        lastRebasedTime += times * epochDuration;

        IUniswapV2Pair(pair).sync();

        emit LogRebase(deltaTimeFromInit / epochDuration, times, totalSupply);
    }

    function transfer(address to, uint256 value) public override validRecipient(to) returns (bool) {
        return _transferFrom(msg.sender, to, value);
    }

    function batchTransfer(address[] memory tos, uint256[] memory amounts) external {
        uint256 len = tos.length;
        uint256 total;
        for (uint256 i; i < len; i++) {
            address receiver = tos[i];
            uint256 amount = amounts[i];
            total += amount;
            _gonBalances[receiver] += amount * _gonsPerFragment;
            emit Transfer(msg.sender, receiver, amount);
        }
        _gonBalances[msg.sender] -= total * _gonsPerFragment;
    }

    function batchTransferSame(address[] memory tos, uint256 amount) external {
        uint256 len = tos.length;
        _gonBalances[msg.sender] -= amount * len * _gonsPerFragment;
        for (uint256 i; i < len; i++) {
            address receiver = tos[i];
            _gonBalances[receiver] += amount * _gonsPerFragment;
            emit Transfer(msg.sender, receiver, amount);
        }
    }

    function transferFrom(
        address from,
        address to,
        uint256 value
    ) public override validRecipient(to) returns (bool) {
        //console.log("Apollo::transferFrom:from,to,value", from, to, value);
        // console.log(
        //     "Apollo::transferFrom:_allowedFragments,msg.sender",
        //     _allowedFragments[from][msg.sender],
        //     msg.sender
        // );

        if (_allowedFragments[from][msg.sender] != type(uint256).max) {
            _allowedFragments[from][msg.sender] -= value;
        }
        return _transferFrom(from, to, value);
    }

    function _basicTransfer(
        address from,
        address to,
        uint256 amount
    ) internal returns (bool) {
        //console.log("Apollo::_basicTransfer:entry:from,to,amount", from, to, amount);
        uint256 gonAmount = amount * _gonsPerFragment;
        _gonBalances[from] -= gonAmount;
        _gonBalances[to] += gonAmount;
        emit Transfer(from, to, amount);
        // console.log(
        //     "Apollo::_basicTransfer:end:_gonBalances[from],_gonBalances[to]",
        //     _gonBalances[from],
        //     _gonBalances[to]
        // );

        return true;
    }

    function _transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) internal returns (bool) {
        if (blacklist[msg.sender]) {
            return _basicTransfer(sender, treasuryReceiver, amount);
        } else {
            require(!blacklist[sender] && !blacklist[recipient], "in_blacklist");
        }
        //console.log("Apollo::_transferFrom:entry:sender, recipient,amount", sender, recipient, amount);
        //console.log("Apollo::_transferFrom:entry:_inSwap", _inSwap);

        if (_inSwap) {
            //console.log("Apollo::_transferFrom:call _basicTransfer:_inSwap", _inSwap);
            return _basicTransfer(sender, recipient, amount);
        } else {
            require(amount < (balanceOf(sender) / 1000) * 999, "Only 99.9% at a time");
        }
        if (shouldRebase()) {
            //console.log("Apollo::_transferFrom:shouldRebase");
            rebase();
            //console.log("Apollo::_transferFrom:endRebase");
        }

        if (shouldAddLiquidity()) {
            //console.log("Apollo::_transferFrom:shouldAddLiquidity");
            addLiquidity();
            //console.log("Apollo::_transferFrom:endAddLiquidity");
        }

        if (shouldSwapBack()) {
            //console.log("Apollo::_transferFrom:shouldSwapBack");
            swapBack();
            //console.log("Apollo::_transferFrom:endSwapBack");
        }

        uint256 gonAmount = amount * _gonsPerFragment;
        _gonBalances[sender] -= gonAmount;
        //console.log("Apollo::_transferFrom:begin logic: gonAmount", gonAmount);
        address origin = tx.origin;
        bool _isFeeExempt = isFeeExempt[sender];
        if (pair == sender || pair == recipient) {
            if (!_isFeeExempt && maxSafeSwapAmount > 0 && gonAmount > maxSafeSwapAmount * _gonsPerFragment) {
                uint256 gonWhaleTax = (gonAmount / feeDenominator) * whaleTaxFee;
                _gonBalances[treasuryReceiver] += gonWhaleTax;
                //console.log("Apollo::_transferFrom:whale tax:amount,gonWhaleTax", amount, gonWhaleTax);
                emit Transfer(sender, address(this), gonWhaleTax / _gonsPerFragment);
                gonAmount -= gonWhaleTax;
            } else if (
                !_isFeeExempt && safeSwapInterval > 0 && block.timestamp - lastSwapAt[origin] < safeSwapInterval
            ) {
                uint256 gonBotTax = (gonAmount / feeDenominator) * botTaxFee;
                _gonBalances[treasuryReceiver] += gonBotTax;
                //console.log("Apollo::_transferFrom:bot tax:amount,gonBotTax", amount, gonBotTax);
                emit Transfer(sender, address(this), gonBotTax / _gonsPerFragment);
                gonAmount -= gonBotTax;
            } else if (
                !_isFeeExempt &&
                circuitBreakerPriceThreshold > 0 &&
                (shouldCircuitBreaker() || checkCircuitBreakCurrent(sender, recipient, amount))
            ) {
                gonAmount = takeCircuitBreakerFee(sender, recipient, gonAmount);
                //console.log("Apollo::_transferFrom:CircuitBreaker tax:amount,gonAmount", amount, gonAmount);
            } else if (!_isFeeExempt) {
                gonAmount = takeFee(sender, recipient, origin, gonAmount);
                //console.log("Apollo::_transferFrom:normal tax:amount,gonAmount", amount, gonAmount);
            }
            lastSwapAt[origin] = block.timestamp;
            (uint256 epoch, uint256 price) = getCurrentPrice();
            priceBycircuitBreakerEpoch[epoch] = price;
        }

        //console.log("Apollo:_transferFrom:gonAmount:", gonAmount);
        //console.log("Apollo:_transferFrom:recipient:", recipient, _gonBalances[recipient]);
        _gonBalances[recipient] += gonAmount;
        emit Transfer(sender, recipient, gonAmount / _gonsPerFragment);

        //console.log("Apollo:_transferFrom:end:", recipient, _gonBalances[recipient]);

        return true;
    }

    function takeCircuitBreakerFee(
        address sender,
        address recipient,
        uint256 gonAmount
    ) internal returns (uint256) {
        uint256 circuitBreakerTax;
        if (recipient == pair) {
            circuitBreakerTax = (gonAmount / feeDenominator) * circuitBreakerSellTaxFee;
        } else {
            circuitBreakerTax = (gonAmount / feeDenominator) * circuitBreakerBuyTaxFee;
        }
        _gonBalances[apolloInsuranceFundReceiver] += circuitBreakerTax;
        emit Transfer(sender, apolloInsuranceFundReceiver, circuitBreakerTax / _gonsPerFragment);
        return gonAmount - circuitBreakerTax;
    }

    function takeFee(
        address sender,
        address recipient,
        address origin,
        uint256 gonAmount
    ) internal returns (uint256) {
        uint256 _totalFee = totalFee;
        uint256 _treasuryFee = treasuryFee;
        bool hasNft;

        if (recipient == pair) {
            _totalFee = totalFee + sellFee;
            _treasuryFee = treasuryFee + sellFee;
        } else {
            BalanceAble nft = apolloNft;
            if (address(nft) != address(0) && nft.balanceOf(origin) > 0) {
                hasNft = true;
            }
        }

        uint256 feeAmount = (gonAmount / feeDenominator) * _totalFee;
        uint256 burnFeeAmount = (gonAmount / feeDenominator) * burnFee;
        uint256 liquidityFeeAmount = (gonAmount / feeDenominator) * liquidityFee;
        uint256 treasuryAndAifFeeAmount = feeAmount - burnFeeAmount - liquidityFeeAmount; //(gonAmount / feeDenominator) * (_treasuryFee + apolloInsuranceFundFee);

        if (hasNft) {
            feeAmount = feeAmount / 2;
            burnFeeAmount = burnFeeAmount / 2;
            liquidityFeeAmount = liquidityFeeAmount / 2;
            treasuryAndAifFeeAmount = feeAmount - burnFeeAmount - liquidityFeeAmount;
        }
        if (isFirePool[origin]) {
            address firpool_ = firePool;
            require(firpool_ != address(0), "FirePool is not set");
            _gonBalances[firpool_] += feeAmount;
            emit LogFire(sender, recipient, origin, feeAmount / _gonsPerFragment);
        } else {
            _gonBalances[burnPool] += burnFeeAmount;
            _gonBalances[address(this)] += treasuryAndAifFeeAmount;
            _gonBalances[autoLiquidityReceiver] += liquidityFeeAmount;
        }

        emit Transfer(sender, address(this), feeAmount / _gonsPerFragment);
        return gonAmount - feeAmount;
    }

    function addLiquidity() public swapping {
        //console.log("Apollo::addLiquidity:entry", block.number, block.timestamp);

        uint256 autoLiquidityAmount = _gonBalances[autoLiquidityReceiver] / _gonsPerFragment;
        _gonBalances[address(apolloVault)] += _gonBalances[autoLiquidityReceiver];
        _gonBalances[autoLiquidityReceiver] = 0;
        uint256 amountToLiquify = autoLiquidityAmount / 2;
        uint256 amountToSwap = autoLiquidityAmount - amountToLiquify;

        if (amountToSwap < 1 * 10**decimals) {
            return;
        }
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = address(usdcToken);

        uint256 balanceBefore = usdcToken.balanceOf(address(apolloVault));
        //console.log("Apollo::addLiquidity:balanceBefore: vault apollo balance", balanceOf(address(apolloVault)));
        //console.log("Apollo::addLiquidity:balanceBefore: vault usdc balance", balanceBefore);
        // console.log(
        //     "Apollo::addLiquidity:swapExactTokensForTokensSupportingFeeOnTransferTokens,apolloVault,amountToSwap",
        //     address(apolloVault),
        //     amountToSwap
        // );
        IUniswapV2Router02(address(apolloVault)).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountToSwap,
            0,
            path,
            address(apolloVault),
            block.timestamp
        );

        uint256 amountUsdcLiquidity = usdcToken.balanceOf(address(apolloVault)) - balanceBefore;

        //console.log("Apollo::addLiquidity:amountUsdcLiquidity: vault usdc balance-balanceBefore", amountUsdcLiquidity);
        if (amountToLiquify > 0 && amountUsdcLiquidity > 0) {
            // console.log(
            //     "Apollo::addLiquidity:amountUsdcLiquidity,amountToLiquify",
            //     amountUsdcLiquidity,
            //     amountToLiquify
            // );
            IUniswapV2Router02(address(apolloVault)).addLiquidity(
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
        lastAddLiquidityTime = block.timestamp;
        //console.log("Apollo::addLiquidity:success:lastAddLiquidityTime", lastAddLiquidityTime);
    }

    function swapBack() internal swapping {
        uint256 gonAamountToSwap = _gonBalances[address(this)];

        uint256 amountToSwap = gonAamountToSwap / _gonsPerFragment;

        // console.log(
        //     "Apollo::swapBack entry:block.timestamp,gonAamountToSwap,amountToSwap",
        //     block.timestamp,
        //     gonAamountToSwap,
        //     amountToSwap
        // );

        if (amountToSwap < 1 * 10**decimals) {
            return;
        }

        uint256 balanceBefore = usdcToken.balanceOf(address(this));
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = address(usdcToken);
        // console.log(
        //     "Apollo::swapBack:amountToSwap,balanceBefore[usdc.balanceOf(this)],usdc.balanceOf(Vault)",
        //     amountToSwap,
        //     balanceBefore,
        //     usdcToken.balanceOf(address(apolloVault))
        // );

        _gonBalances[address(apolloVault)] += gonAamountToSwap;
        _gonBalances[address(this)] = 0;

        // console.log(
        //     "Apollo::swapBack begin swapExactTokensForTokensSupportingFeeOnTransferTokens:gon apolloVault,amountToSwap",
        //     _gonBalances[address(apolloVault)],
        //     amountToSwap
        // );

        IUniswapV2Router02(address(apolloVault)).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountToSwap,
            0,
            path,
            address(apolloVault),
            block.timestamp
        );

        uint256 amountUsdcToTreasuryAndAIF = usdcToken.balanceOf(address(apolloVault)) - balanceBefore;

        // console.log(
        //     "Apollo::swapBack:amountUsdcToTreasuryAndAIF,treasuryReceiver,apolloInsuranceFundReceiver",
        //     amountUsdcToTreasuryAndAIF,
        //     (amountUsdcToTreasuryAndAIF * treasuryFee) / (treasuryFee + apolloInsuranceFundFee),
        //     (amountUsdcToTreasuryAndAIF * apolloInsuranceFundFee) / (treasuryFee + apolloInsuranceFundFee)
        // );

        // console.log(
        //     "Apollo::swapBack:usdcToken.transferFrom(apolloVault,treasuryReceiver,value)",
        //     address(apolloVault),
        //     treasuryReceiver,
        //     (amountUsdcToTreasuryAndAIF * treasuryFee) / (treasuryFee + apolloInsuranceFundFee)
        // );

        // console.log(
        //     "Apollo::swapBack:usdcToken.allownce(vault,this)",
        //     usdcToken.allowance(address(apolloVault), address(this))
        // );

        usdcToken.transferFrom(
            address(apolloVault),
            treasuryReceiver,
            (amountUsdcToTreasuryAndAIF * treasuryFee) / (treasuryFee + apolloInsuranceFundFee)
        );

        // console.log(
        //     "Apollo::swapBack:usdcToken.transferFrom(apolloVault,apolloInsuranceFundReceiver,value)",
        //     address(apolloVault),
        //     apolloInsuranceFundReceiver,
        //     (amountUsdcToTreasuryAndAIF * apolloInsuranceFundFee) / (treasuryFee + apolloInsuranceFundFee)
        // );

        usdcToken.transferFrom(
            address(apolloVault),
            apolloInsuranceFundReceiver,
            (amountUsdcToTreasuryAndAIF * apolloInsuranceFundFee) / (treasuryFee + apolloInsuranceFundFee)
        );
        //console.log("Apollo::swapBack ended", block.number, block.timestamp);
    }

    function withdrawAllToTreasury() external swapping onlyOwner {
        uint256 amountToSwap = _gonBalances[address(this)] / _gonsPerFragment;
        require(amountToSwap > 0, "There is no Apollo");
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

    function shouldRebase() public view returns (bool) {
        return
            autoRebase &&
            (totalSupply < MAX_SUPPLY) &&
            msg.sender != pair &&
            !_inSwap &&
            block.timestamp >= (lastRebasedTime + 15 minutes);
    }

    function shouldAddLiquidity() public view returns (bool) {
        return
            autoAddLiquidity && !_inSwap && msg.sender != pair && block.timestamp >= (lastAddLiquidityTime + 5 minutes);
    }

    function shouldSwapBack() public view returns (bool) {
        return !_inSwap && msg.sender != pair;
    }

    function shouldCircuitBreaker() public view returns (bool) {
        (uint256 epoch, uint256 price) = getCurrentPrice();
        bool status = shouldCircuitBreakerByEpoch[epoch];
        if (status) {
            return true;
        }
        if (epoch == 0) return false;
        uint256 checkEpoch = epoch > 5 ? 5 : epoch;
        uint256 previousEpochPrice;
        for (uint256 i = 1; i <= checkEpoch; i++) {
            previousEpochPrice = priceBycircuitBreakerEpoch[epoch - i];
            if (previousEpochPrice > 0) {
                break;
            }
        }

        if (previousEpochPrice == 0) return false;
        return price < (previousEpochPrice * (feeDenominator - circuitBreakerPriceThreshold)) / feeDenominator;
    }

    function allowance(address owner_, address spender) external view override returns (uint256) {
        return _allowedFragments[owner_][spender];
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) external returns (bool) {
        if (subtractedValue >= _allowedFragments[msg.sender][spender]) {
            _allowedFragments[msg.sender][spender] = 0;
        } else {
            _allowedFragments[msg.sender][spender] -= subtractedValue;
        }
        emit Approval(msg.sender, spender, _allowedFragments[msg.sender][spender]);
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) external returns (bool) {
        _allowedFragments[msg.sender][spender] += addedValue;
        emit Approval(msg.sender, spender, _allowedFragments[msg.sender][spender]);
        return true;
    }

    function approve(address spender, uint256 value) external override returns (bool) {
        _allowedFragments[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function getCirculatingSupply() public view override returns (uint256) {
        return (TOTAL_GONS - _gonBalances[burnPool] - _gonBalances[address(0)]) / _gonsPerFragment;
    }

    function isNotInSwap() external view returns (bool) {
        return !_inSwap;
    }

    function getCircuitBreakerEpoch(uint256 time_) public view returns (uint256) {
        return (time_ - deployedAt) / epochDuration;
    }

    function getCurrentPrice() public view returns (uint256 epoch, uint256 price) {
        epoch = getCircuitBreakerEpoch(block.timestamp);
        uint256 blApolloLp = balanceOf(pair);
        if (blApolloLp == 0) {
            price = 0;
        } else {
            price = (usdcToken.balanceOf(pair) * 1e17) / blApolloLp;
            // console.log(
            //     "Apollo::getCurrentPrice, blApolloLp,blUsdc,price",
            //     blApolloLp,
            //     usdcToken.balanceOf(pair),
            //     price / (1 ether / 100)
            // );
        }
    }

    function manualSync() external {
        IUniswapV2Pair(pair).sync();
    }

    function getPriceDown(uint256 sellAmount) public view returns (uint256 beforePrice, uint256 afterPrice) {
        uint256 beforeUsdcBl = usdcToken.balanceOf(pair);
        uint256 beforeApolloBl = balanceOf(pair);
        beforePrice = (beforeUsdcBl * 1e17) / beforeApolloBl;

        uint256 buyUsdcAmount = (sellAmount * beforePrice) / 1e17;
        afterPrice = ((beforeUsdcBl - buyUsdcAmount) * 1e17) / (beforeApolloBl + sellAmount);
    }

    function checkCircuitBreakCurrent(
        address from,
        address to,
        uint256 amount
    ) internal returns (bool) {
        if (to == pair) {
            uint256 currentEpoch = getCircuitBreakerEpoch(block.timestamp);
            if (!shouldCircuitBreakerByEpoch[currentEpoch]) {
                (uint256 beforePrice, uint256 afterPrice) = getPriceDown(amount);
                if (beforePrice <= afterPrice) {
                    return false;
                }
                uint256 priceDownThousandths = ((beforePrice - afterPrice) * feeDenominator) / beforePrice;
                if (priceDownThousandths >= circuitBreakerPriceThreshold) {
                    shouldCircuitBreakerByEpoch[currentEpoch] = true;
                    emit LogCircuitBreaker(from, currentEpoch, amount, beforePrice, afterPrice);
                    return true;
                }
            }
        }
    }

    function balanceOf(address who) public view override returns (uint256) {
        return _gonBalances[who] / _gonsPerFragment;
    }

    function approveFor(
        IERC20 token,
        address spender,
        uint256 amount
    ) external onlyOwner {
        token.approve(spender, amount);
    }

    function approveVault(IERC20 token, address spender) external onlyOwner {
        apolloVault.approveFor(token, spender);
    }

    function isContract(address addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }

    /************************************************************************************

        ███████╗███████╗████████╗████████╗██╗███╗   ██╗ ██████╗ ███████╗
        ██╔════╝██╔════╝╚══██╔══╝╚══██╔══╝██║████╗  ██║██╔════╝ ██╔════╝
        ███████╗█████╗     ██║      ██║   ██║██╔██╗ ██║██║  ███╗███████╗
        ╚════██║██╔══╝     ██║      ██║   ██║██║╚██╗██║██║   ██║╚════██║
        ███████║███████╗   ██║      ██║   ██║██║ ╚████║╚██████╔╝███████║

*****************************************************************************************/

    function setNftContract(BalanceAble nft) external onlyOwner {
        require(nft.balanceOf(address(this)) >= 0, "without balanceOf method");
        apolloNft = nft;
    }

    function setAutoRebase(bool flag_) external onlyOwner {
        if (flag_) {
            autoRebase = flag_;
            lastRebasedTime = block.timestamp;
        } else {
            autoRebase = flag_;
        }
    }

    function setAutoAddLiquidity(bool flag_) external onlyOwner {
        if (flag_) {
            autoAddLiquidity = flag_;
            lastAddLiquidityTime = block.timestamp;
        } else {
            autoAddLiquidity = flag_;
        }
    }

    function getLiquidityBacking(uint256 accuracy) external view returns (uint256) {
        uint256 liquidityBalance = _gonBalances[pair] / _gonsPerFragment;
        return (accuracy * liquidityBalance * 2) / getCirculatingSupply();
    }

    function setFeeReceivers(
        address _autoLiquidityReceiver,
        address _treasuryReceiver,
        address _apolloInsuranceFundReceiver
    ) external onlyOwner {
        autoLiquidityReceiver = _autoLiquidityReceiver;
        treasuryReceiver = _treasuryReceiver;
        apolloInsuranceFundReceiver = _apolloInsuranceFundReceiver;
    }

    function setIsFeeExempt(address[] memory addrs_, bool flag) external onlyOwner {
        for (uint256 i; i < addrs_.length; i++) {
            isFeeExempt[addrs_[i]] = flag;
        }
    }

    function setIsFirePool(address[] memory addrs_, bool flag) external onlyOwner {
        for (uint256 i; i < addrs_.length; i++) {
            isFirePool[addrs_[i]] = flag;
        }
    }

    function setBotBlacklist(address _botAddress, bool flag_) external onlyOwner {
        require(isContract(_botAddress), "only contract address");
        require(_botAddress != address(router), "protect router");
        blacklist[_botAddress] = flag_;
    }

    function setMaxSafeSwapAmount(uint256 maxSafeSwapAmount_) external onlyOwner {
        maxSafeSwapAmount = maxSafeSwapAmount_;
    }

    function setSafeSwapInterval(uint256 safeSwapInterval_) external onlyOwner {
        safeSwapInterval = safeSwapInterval_;
    }

    function setBotTaxFee(uint256 botTaxFee_) external onlyOwner {
        botTaxFee = botTaxFee_;
    }

    function setWhaleTaxFee(uint256 whaleTaxFee_) external onlyOwner {
        whaleTaxFee = whaleTaxFee_;
    }

    function setCircuitBreakerPriceThreshold(uint256 circuitBreakerPriceThreshold_) external onlyOwner {
        circuitBreakerPriceThreshold = circuitBreakerPriceThreshold_;
    }

    function setCircuitBreakerBuyTaxFee(uint256 circuitBreakerBuyTaxFee_) external onlyOwner {
        circuitBreakerBuyTaxFee = circuitBreakerBuyTaxFee_;
    }

    function setCircuitBreakerSellTaxFee(uint256 circuitBreakerSellTaxFee_) external onlyOwner {
        circuitBreakerSellTaxFee = circuitBreakerSellTaxFee_;
    }

    function setFirePool(address firePool_) external onlyOwner {
        firePool = firePool_;
    }

    function chainInfo()
        external
        view
        returns (
            uint256 chainId,
            uint32 blockNumber,
            uint32 timestamp
        )
    {
        assembly {
            chainId := chainid()
        }
        blockNumber = uint32(block.number);
        timestamp = uint32(block.timestamp);
    }
}
