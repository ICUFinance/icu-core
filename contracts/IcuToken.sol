// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/utils/Address.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';
import '@openzeppelin/contracts/token/ERC20/SafeERC20.sol';
import './mdex/IMdexFactory.sol';
import './mdex/IMdexPair.sol';
import './mdex/IMdexRouter.sol';
import "./pancake/IPancakeRouter.sol";
import "./pancake/IPancakeFactory.sol";

contract IcuToken is Context, IERC20, Ownable {
    using SafeMath for uint256;
    using Address for address;
    using SafeERC20 for IERC20;

    uint256 constant MULTIPLY_FACTOR = 10*10;

    mapping(address => uint256) private _tOwned;
    mapping(address => uint256) private _rOwned;
    mapping(address => mapping(address => uint256)) private _allowances;

    mapping(address => bool) private _isExcludedFromFeeFrom;
    mapping(address => bool) private _isExcludedFromFeeTo;
    mapping(address => bool) private _isExcluded;
    address[] private _excluded;

    uint256 private constant MAX = ~uint256(0);
    uint256 private _tTotal = 1 * 10 ** 9 * 10 ** 18;
    uint256 private _rTotal = (MAX - (MAX % _tTotal));
    uint256 private _tFeeTotal;

    string private _name = "ICU";
    string private _symbol = "ICU";
    uint8 private _decimals = 18;

    uint256 public _repurchaseFee = 3;
    uint256 private _previousRepurchaseFee = _repurchaseFee;

    uint256 public _liquidityFee = 3;
    uint256 private _previousLiquidityFee = _liquidityFee;

    uint256 public _managementFee = 3;
    uint256 private _previousManagementFee = _managementFee;

    IPancakeRouter public immutable uniswapV2Router;
    address public immutable uniswapV2Pair;

    bool inSwapAndLiquify;
    bool public swapAndLiquifyEnabled = true;

    uint256 public _maxTxAmount = 5 * 10 ** 6 * 10 ** 18;
    uint256 private numTokensSellToAddToLiquidity = 1 * 10 ** 4 * 10 ** 18;

    address internal feeMgr;
    address internal repurchaseMgr;

    uint256 public holders;

    event MinTokensBeforeSwapUpdated(uint256 minTokensBeforeSwap);
    event SwapAndLiquifyEnabledUpdated(bool enabled);
    event SwapAndLiquify(
        uint256 tokensSwapped,
        uint256 ethReceived,
        uint256 tokensIntoLiqudity
    );

    modifier lockTheSwap {
        inSwapAndLiquify = true;
        _;
        inSwapAndLiquify = false;
    }

    constructor (address pancakeRouter, address _feeManager, address _repurchaseManager) public {
        _rOwned[_msgSender()] = _rTotal;

        IPancakeRouter _uniswapV2Router = IPancakeRouter(pancakeRouter);
        uniswapV2Pair = IPancakeFactory(_uniswapV2Router.factory()).createPair(address(this), _uniswapV2Router.WETH());

        uniswapV2Router = _uniswapV2Router;

        _isExcludedFromFeeFrom[owner()] = true;
        _isExcludedFromFeeTo[owner()] = true;

        _isExcludedFromFeeFrom[address(this)] = true;
        _isExcludedFromFeeTo[address(this)] = true;


        feeMgr = _feeManager;
        repurchaseMgr = _repurchaseManager;

        emit Transfer(address(0), _msgSender(), _tTotal);
    }

    function name() public view returns (string memory) {
        return _name;
    }

    function symbol() public view returns (string memory) {
        return _symbol;
    }

    function decimals() public view returns (uint8) {
        return _decimals;
    }

    function totalSupply() public view override returns (uint256) {
        return _tTotal;
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (_isExcluded[account]) return _tOwned[account];
        return tokenFromReflection(_rOwned[account]);
    }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(sender, _msgSender(), _allowances[sender][_msgSender()].sub(amount, "ERC20: transfer amount exceeds allowance"));
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender].add(addedValue));
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender].sub(subtractedValue, "ERC20: decreased allowance below zero"));
        return true;
    }

    function isExcludedFromReward(address account) public view returns (bool) {
        return _isExcluded[account];
    }

    function totalFees() public view returns (uint256) {
        return _tFeeTotal;
    }

    function deliver(uint256 tAmount) public {
        address sender = _msgSender();
        require(!_isExcluded[sender], "Excluded addresses cannot call this function");
        (uint256 rAmount,,,,,,) = _getValues(tAmount);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _rTotal = _rTotal.sub(rAmount);
        _tFeeTotal = _tFeeTotal.add(tAmount);
    }

    function reflectionFromToken(uint256 tAmount, bool deductTransferFee) public view returns (uint256) {
        require(tAmount <= _tTotal, "Amount must be less than supply");
        if (!deductTransferFee) {
            (uint256 rAmount,,,,,,) = _getValues(tAmount);
            return rAmount;
        } else {
            (,uint256 rTransferAmount,,,,,) = _getValues(tAmount);
            return rTransferAmount;
        }
    }

    function tokenFromReflection(uint256 rAmount) public view returns (uint256) {
        require(rAmount <= _rTotal, "Amount must be less than total reflections");
        uint256 currentRate = _getRate();
        return rAmount.div(currentRate);
    }

    function excludeFromReward(address account) public onlyOwner() {
        require(!_isExcluded[account], "Account is already excluded");
        if (_rOwned[account] > 0) {
            _tOwned[account] = tokenFromReflection(_rOwned[account]);
        }
        _isExcluded[account] = true;
        _excluded.push(account);
    }

    function includeInReward(address account) external onlyOwner() {
        require(_isExcluded[account], "Account is already included");
        for (uint256 i = 0; i < _excluded.length; i++) {
            if (_excluded[i] == account) {
                _excluded[i] = _excluded[_excluded.length - 1];
                _tOwned[account] = 0;
                _isExcluded[account] = false;
                _excluded.pop();
                break;
            }
        }
    }


    function setIsExcludeFromFeeFrom(address account, bool flag) public onlyOwner {
        _isExcludedFromFeeFrom[account] = flag;
    }

    function setIsExcludeFromFeeTp(address account, bool flag) public onlyOwner {
        _isExcludedFromFeeTo[account] = flag;
    }


    function setTaxFeePercent(uint256 taxFee) external onlyOwner() {
        _repurchaseFee = taxFee;
    }

    function setLiquidityFeePercent(uint256 liquidityFee) external onlyOwner() {
        _liquidityFee = liquidityFee;
    }

    function setManagementFeePercent(uint256 managementFee) external onlyOwner() {
        _managementFee = managementFee;
    }

    function setMaxTxPercent(uint256 maxTxPercent) external onlyOwner() {
        _maxTxAmount = _tTotal.mul(maxTxPercent).div(
            10 ** 2
        );
    }

    function setSwapAndLiquifyEnabled(bool _enabled) public onlyOwner {
        swapAndLiquifyEnabled = _enabled;
        emit SwapAndLiquifyEnabledUpdated(_enabled);
    }

    receive() external payable {}

    function _reflectFee(uint256 rFee, uint256 tFee) private {
        _rTotal = _rTotal.sub(rFee);
        _tFeeTotal = _tFeeTotal.add(tFee);
    }

    function _getValues(uint256 tAmount) private view returns (uint256, uint256, uint256, uint256, uint256, uint256, uint256/*tManagement*/) {
        (uint256 tTransferAmount, uint256 tRepurchase, uint256 tLiquidity, uint256 tManagement) = _getTValues(tAmount);
        (uint256 rAmount, uint256 rTransferAmount, uint256 rRepurchase) = _getRValues(tAmount, tRepurchase, tLiquidity, tManagement, _getRate());
        return (rAmount, rTransferAmount, rRepurchase, tTransferAmount, tRepurchase, tLiquidity, tManagement);
    }

    function _getTValues(uint256 tAmount) private view returns (uint256, uint256, uint256, uint256) {
        uint256 tRepurchase = calculateRepurchaseFee(tAmount);
        uint256 tLiquidity = calculateLiquidityFee(tAmount);
        uint256 tManagement = calculateManagementFee(tAmount);
        uint256 tTransferAmount = tAmount.sub(tRepurchase).sub(tLiquidity).sub(tManagement);
        return (tTransferAmount, tRepurchase, tLiquidity, tManagement);
    }

    function _getRValues(uint256 tAmount, uint256 tRepurchase, uint256 tLiquidity, uint256 tManagement, uint256 currentRate) private pure returns (uint256, uint256, uint256) {
        uint256 rAmount = tAmount.mul(currentRate);

        uint256 rRepurchase = tRepurchase.mul(currentRate);
        uint256 rLiquidity = tLiquidity.mul(currentRate);
        uint256 rManagement = tManagement.mul(currentRate);
        uint256 rTransferAmount = rAmount.sub(rRepurchase).sub(rLiquidity).sub(rManagement);
        return (rAmount, rTransferAmount, rRepurchase);
    }

    function _getRate() private view returns (uint256) {
        (uint256 rSupply, uint256 tSupply) = _getCurrentSupply();
        return rSupply.div(tSupply);
    }

    function _getCurrentSupply() private view returns (uint256, uint256) {
        uint256 rSupply = _rTotal;
        uint256 tSupply = _tTotal;
        for (uint256 i = 0; i < _excluded.length; i++) {
            if (_rOwned[_excluded[i]] > rSupply || _tOwned[_excluded[i]] > tSupply) return (_rTotal, _tTotal);
            rSupply = rSupply.sub(_rOwned[_excluded[i]]);
            tSupply = tSupply.sub(_tOwned[_excluded[i]]);
        }
        if (rSupply < _rTotal.div(_tTotal)) return (_rTotal, _tTotal);
        return (rSupply, tSupply);
    }

    function _takeRepurchase(uint256 tRepurchase) private {
        uint256 currentRate = _getRate();
        uint256 rRepurchase = tRepurchase.mul(currentRate);
        //repurchase + liquidity mixed
        _rOwned[address(this)] = _rOwned[address(this)].add(rRepurchase);
        if (_isExcluded[address(this)])
            _tOwned[address(this)] = _tOwned[address(this)].add(tRepurchase);
    }

    function _takeLiquidity(uint256 tLiquidity) private {
        uint256 currentRate = _getRate();
        uint256 rLiquidity = tLiquidity.mul(currentRate);
        //repurchase + liquidity mixed
        _rOwned[address(this)] = _rOwned[address(this)].add(rLiquidity);
        if (_isExcluded[address(this)])
            _tOwned[address(this)] = _tOwned[address(this)].add(tLiquidity);
    }

    function _takeManagementFee(uint256 tManagement) private {
        uint256 currentRate = _getRate();
        uint256 rManagement = tManagement.mul(currentRate);
        _rOwned[feeMgr] = _rOwned[feeMgr].add(rManagement);
        if (_isExcluded[feeMgr])
            _tOwned[feeMgr] = _tOwned[feeMgr].add(tManagement);
    }

    function calculateRepurchaseFee(uint256 _amount) private view returns (uint256) {
        return _amount.mul(_repurchaseFee).div(
            10 ** 2
        );
    }

    function calculateLiquidityFee(uint256 _amount) private view returns (uint256) {
        return _amount.mul(_liquidityFee).div(
            10 ** 2
        );
    }

    function calculateManagementFee(uint256 _amount) private view returns (uint256) {
        return _amount.mul(_managementFee).div(
            10 ** 2
        );
    }

    function removeAllFee() private {
        if (_repurchaseFee == 0 && _liquidityFee == 0 && _managementFee == 0) return;

        _previousManagementFee = _managementFee;
        _previousRepurchaseFee = _repurchaseFee;
        _previousLiquidityFee = _liquidityFee;

        _repurchaseFee = 0;
        _liquidityFee = 0;
        _managementFee = 0;
    }

    function restoreAllFee() private {
        _repurchaseFee = _previousRepurchaseFee;
        _liquidityFee = _previousLiquidityFee;
        _managementFee = _previousManagementFee;
    }

    function isExcludedFromFeeFrom(address account) public view returns (bool) {
        return _isExcludedFromFeeFrom[account];
    }

    function isExcludedFromFeeTo(address account) public view returns (bool) {
        return _isExcludedFromFeeTo[account];
    }

    function _approve(address owner, address spender, uint256 amount) private {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) private {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");
        require(amount > 0, "Transfer amount must be greater than zero");
        if (from != owner() && to != owner())
            require(amount <= _maxTxAmount, "Transfer amount exceeds the maxTxAmount.");

        uint256 contractTokenBalance = balanceOf(address(this));

        if (contractTokenBalance >= _maxTxAmount)
        {
            contractTokenBalance = _maxTxAmount;
        }

        bool overMinTokenBalance = contractTokenBalance >= numTokensSellToAddToLiquidity;
        if (
            overMinTokenBalance &&
            !inSwapAndLiquify &&
            from != uniswapV2Pair &&
            swapAndLiquifyEnabled
        ) {
            contractTokenBalance = numTokensSellToAddToLiquidity;
            swapAndLiquify(contractTokenBalance);
        }

        bool takeFee = true;

        if (_isExcludedFromFeeFrom[from] || _isExcludedFromFeeTo[to]) {
            takeFee = false;
        }

        uint256 toBalanceBefore = balanceOf(to);

        _tokenTransfer(from, to, amount, takeFee);

        uint256 fromBalanceAfter = balanceOf(from);
        if (fromBalanceAfter == 0) {
            holders = holders.sub(1);
        }
        if (toBalanceBefore == 0) {
            holders = holders.add(1);
        }
    }

    function swapAndLiquify(uint256 contractTokenBalance) private lockTheSwap {

        //repurchase + liquidity
        uint256 tokenToSell = contractTokenBalance
        .mul(_repurchaseFee.mul(MULTIPLY_FACTOR).add(_liquidityFee.mul(MULTIPLY_FACTOR).div(2)))
        .div(_repurchaseFee.mul(MULTIPLY_FACTOR).add(_liquidityFee.mul(MULTIPLY_FACTOR)));
        uint256 tokenLeftForLiquidity = contractTokenBalance.sub(tokenToSell);

        uint256 initialBalance = address(this).balance;
        swapTokensForEth(tokenToSell);
        uint256 soldEth = address(this).balance.sub(initialBalance);

        uint256 repurchasedEth = soldEth
        .mul(_repurchaseFee.mul(MULTIPLY_FACTOR))
        .div(_repurchaseFee.mul(MULTIPLY_FACTOR).add(_liquidityFee.mul(MULTIPLY_FACTOR).div(2)));

        safeTransferETH(repurchaseMgr, repurchasedEth);

        uint256 liquidifyEth = soldEth.sub(repurchasedEth);

        addLiquidity(tokenLeftForLiquidity, liquidifyEth);

        emit SwapAndLiquify(tokenToSell, soldEth, tokenLeftForLiquidity);
    }

    function swapTokensForEth(uint256 tokenAmount) private {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();

        _approve(address(this), address(uniswapV2Router), tokenAmount);

        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            address(this),
            block.timestamp
        );
    }

    function addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {
        _approve(address(this), address(uniswapV2Router), tokenAmount);

        uniswapV2Router.addLiquidityETH{value : ethAmount}(
            address(this),
            tokenAmount,
            0,
            0,
            owner(),
            block.timestamp
        );
    }

    function _tokenTransfer(address sender, address recipient, uint256 amount, bool takeFee) private {
        if (!takeFee)
            removeAllFee();

        if (_isExcluded[sender] && !_isExcluded[recipient]) {
            _transferFromExcluded(sender, recipient, amount);
        } else if (!_isExcluded[sender] && _isExcluded[recipient]) {
            _transferToExcluded(sender, recipient, amount);
        } else if (!_isExcluded[sender] && !_isExcluded[recipient]) {
            _transferStandard(sender, recipient, amount);
        } else if (_isExcluded[sender] && _isExcluded[recipient]) {
            _transferBothExcluded(sender, recipient, amount);
        } else {
            revert("should not happens");
        }

        if (!takeFee)
            restoreAllFee();
    }

    function _transferStandard(address sender, address recipient, uint256 tAmount) private {
        (uint256 rAmount, uint256 rTransferAmount, uint256 rRepurchase, uint256 tTransferAmount, uint256 tRepurchase, uint256 tLiquidity,uint256 tManagement) = _getValues(tAmount);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);
        _takeLiquidity(tLiquidity);
        _takeRepurchase(tRepurchase);
        _takeManagementFee(tManagement);
        //_reflectFee(rRepurchase, tRepurchase);
        emit Transfer(sender, recipient, tTransferAmount);
    }

    function _transferToExcluded(address sender, address recipient, uint256 tAmount) private {
        (uint256 rAmount, uint256 rTransferAmount, uint256 rRepurchase, uint256 tTransferAmount, uint256 tRepurchase, uint256 tLiquidity,uint256 tManagement) = _getValues(tAmount);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _tOwned[recipient] = _tOwned[recipient].add(tTransferAmount);
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);
        _takeLiquidity(tLiquidity);
        _takeRepurchase(tRepurchase);
        _takeManagementFee(tManagement);
        //_reflectFee(rRepurchase, tRepurchase);
        emit Transfer(sender, recipient, tTransferAmount);
    }

    function _transferFromExcluded(address sender, address recipient, uint256 tAmount) private {
        (uint256 rAmount, uint256 rTransferAmount, uint256 rRepurchase, uint256 tTransferAmount, uint256 tRepurchase, uint256 tLiquidity,uint256 tManagement) = _getValues(tAmount);
        _tOwned[sender] = _tOwned[sender].sub(tAmount);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);
        _takeLiquidity(tLiquidity);
        _takeRepurchase(tRepurchase);
        _takeManagementFee(tManagement);
        //_reflectFee(rRepurchase, tRepurchase);
        emit Transfer(sender, recipient, tTransferAmount);
    }

    function _transferBothExcluded(address sender, address recipient, uint256 tAmount) private {
        (uint256 rAmount, uint256 rTransferAmount, uint256 rRepurchase, uint256 tTransferAmount, uint256 tRepurchase, uint256 tLiquidity,uint256 tManagement) = _getValues(tAmount);
        _tOwned[sender] = _tOwned[sender].sub(tAmount);
        _rOwned[sender] = _rOwned[sender].sub(rAmount);
        _tOwned[recipient] = _tOwned[recipient].add(tTransferAmount);
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);
        _takeLiquidity(tLiquidity);
        _takeRepurchase(tRepurchase);
        _takeManagementFee(tManagement);
        //_reflectFee(rRepurchase, tRepurchase);
        emit Transfer(sender, recipient, tTransferAmount);
    }

    function safeTransferETH(address to, uint value) internal {
        (bool success,) = to.call{value : value}(new bytes(0));
        require(success, 'ETH_TRANSFER_FAILED');
    }

    function transferBack(IERC20 erc20Token, address to, uint256 amount) external onlyOwner {
        require(address(erc20Token) != address(this), "Can not transfer the token itself");

        if (address(erc20Token) == address(0)) {
            payable(to).transfer(amount);
        } else {
            erc20Token.safeTransfer(to, amount);
        }
    }
}
