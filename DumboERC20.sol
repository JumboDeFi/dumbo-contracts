// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;

import "./libraries/ERC20Permit.sol";
import "./libraries/Ownable.sol";
import "./libraries/VaultOwned.sol";

import "./interfaces/IDumboERC20.sol";
import "./interfaces/ITreasury.sol";
import "./interfaces/IUniswapV2Factory.sol";
import "./interfaces/IUniswapV2Router02.sol";

contract DumboERC20Token is ERC20Permit, IDumboERC20, VaultOwned {
    using SafeMath for uint256;

    uint256 public _limitTime = 1637503200; // 22:00
    uint256 public _openTime = 1637505000;  // 22:30

    uint256 public _maximumHold = 20000000000;

    mapping(address => bool) private _isNoLimit;
    mapping (address => bool) private _isExcludedFromFee;
    
    bool inSwapAndLiquify;
    IUniswapV2Router02 public immutable _uniswapV2Router;
    address public immutable _uniswapV2Pair;

    address _busdAddress;
    address _treasury;
    address _DAO;

    modifier lockTheSwap {
        inSwapAndLiquify = true;
        _;
        inSwapAndLiquify = false;
    }

    // busdAddress: 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56
    // swapRouterAddress: 0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F
    constructor(address busdAddress, address swapRouterAddress, address DAO) ERC20("Dumbo", "DUM", 9) {
        _busdAddress = busdAddress;
        _DAO = DAO;
        
        IUniswapV2Router02 uniswapV2Router = IUniswapV2Router02(swapRouterAddress);
         // Create a uniswap pair for this new token
        _uniswapV2Pair = IUniswapV2Factory(uniswapV2Router.factory()).createPair(address(this), busdAddress);

        // exclude owner and this contract from fee
        _isExcludedFromFee[owner()] = true;
        _isExcludedFromFee[address(this)] = true;

        // set the rest of the contract variables
        _uniswapV2Router = uniswapV2Router;
    }

    function _beforeTokenTransfer(address from_, address to_, uint256 amount_) internal override {
        if (block.timestamp < _limitTime) {
            require(_isNoLimit[to_], "receiver not in whitelist");
        } else if (block.timestamp < _openTime) {
            if (!_isNoLimit[to_]) {
                require(_isNoLimit[from_], "can not transfer before open-time");
                require(balanceOf(to_) + amount_ <= _maximumHold, "receiver exceeded the maximum hold");
            }
        }
        super._beforeTokenTransfer(from_, to_, amount_);
    }

    function noLimit(address address_) external onlyOwner {
        _isNoLimit[address_] = true;
    }

    function setLimitTime(uint256 limitTime_) external onlyOwner {
        require(limitTime_ < _openTime && limitTime_ < 1672502400, "invaid time");
        _limitTime = limitTime_;
    }

    function setOpenTime(uint256 openTime_) external onlyOwner {
        require(openTime_ > _limitTime && openTime_ < 1672502400, "invaid time");
        _openTime = openTime_;
    }

    function mint(address account_, uint256 amount_) external override onlyVault {
        _mint(account_, amount_);
    }

    function burn(uint256 amount) external override {
        _burn(msg.sender, amount);
    }

    function burnFrom(address account_, uint256 amount_) external override {
        _burnFrom(account_, amount_);
    }

    function _burnFrom(address account_, uint256 amount_) internal virtual {
        uint256 decreasedAllowance_ = allowance(account_, msg.sender).sub(amount_, "ERC20: burn amount exceeds allowance");
        _approve(account_, msg.sender, decreasedAllowance_);
        _burn(account_, amount_);
    }

    function _transfer(address sender, address recipient, uint256 amount) internal override {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");

        bool takeFee = true;
        // if any account belongs to _isExcludedFromFee account then remove the fee
        if(_isExcludedFromFee[sender] || _isExcludedFromFee[recipient] || sender == _uniswapV2Pair) {
            takeFee = false;
        }

        _beforeTokenTransfer(sender, recipient, amount);

        _balances[sender] = _balances[sender].sub(amount, "ERC20: transfer amount exceeds balance");
        
        uint256 fee = takeFee ? amount.div(10) : 0;
        amount = amount.sub(fee);

        address self = address(this);

        _balances[recipient] = _balances[recipient].add(amount);
        emit Transfer(sender, recipient, amount);

        if (fee > 0) {
            _balances[self] = _balances[self].add(fee);
            emit Transfer(sender, self, fee);

            uint256 contractTokenBalance = balanceOf(address(this));
            if (contractTokenBalance >= 10**9 && !inSwapAndLiquify && sender != _uniswapV2Pair) {
                _handleFees(contractTokenBalance);
            }
        }
    }

    function _handleFees(uint256 contractTokenBalance) private {
        // 10% for commission
        // commission: 20% to burn, 30% add liquidty, 30% add treasury, 20% to DAO
        uint256 numBurn = contractTokenBalance.div(5);
        uint256 numSell = contractTokenBalance.mul(65).div(100);
        uint256 numLeft = contractTokenBalance.sub(numBurn).sub(numSell);

        // burn 
        _burn(address(this), numBurn);

        // swap
        swapAndLiquify(numSell, numLeft);

        // transfer to treasury and DAO
        address self = address(this);
        ERC20 busdContract = ERC20(_busdAddress);
        ITreasury treasury = ITreasury(_treasury); 
        
        uint256 leftBalance = busdContract.balanceOf(self);
        uint256 amountToTreasury = leftBalance.mul(3).div(5);
        uint256 profit = amountToTreasury.mul(10**9);
        treasury.deposit(amountToTreasury, _busdAddress, profit);
    }

    function swapAndLiquify(uint256 numSell, uint256 tokenAmount) private lockTheSwap {
        ERC20 busdContract = ERC20(_busdAddress);
        address self = address(this);

        // capture the contract's current ETH balance.
        // this is so that we can capture exactly the amount of ETH that the
        // swap creates, and not make the liquidity event include any ETH that
        // has been manually sent to the contract
        // uint256 initialBalance = busdContract.balanceOf(self);

        // swap tokens for ETH
        swapTokensForBUSD(numSell); // <- this breaks the ETH -> HATE swap when swap+liquify is triggered

        // how much BUSD did we just swap into?
        uint256 newBalance = busdContract.balanceOf(self);

        // add liquidity to uniswap
        uint256 busdAmount = newBalance.div(4);
        addLiquidity(tokenAmount, busdAmount);
        
        // todo: emit SwapAndLiquify(half, newBalance, otherHalf);
    }

    function swapTokensForBUSD(uint256 tokenAmount) private {
        // generate the uniswap pair path of token -> weth
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = _busdAddress;

        _approve(address(this), address(_uniswapV2Router), tokenAmount);

        // make the swap
        _uniswapV2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of BUSD
            path,
            address(this),
            block.timestamp
        );
    }

    function addLiquidity(uint256 tokenAmount, uint256 busdAmount) private {
        // approve token transfer to cover all possible scenarios
        _approve(address(this), address(_uniswapV2Router), tokenAmount);
        _approve(_busdAddress, address(_uniswapV2Router), busdAmount);

        // add the liquidity
        _uniswapV2Router.addLiquidity(
            address(this),
            _busdAddress,
            tokenAmount,
            busdAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            owner(),
            block.timestamp
        );
    }

    function excludedInFee(address account) public onlyOwner {
        _isExcludedFromFee[account] = true;
    }
    
    function includedInFee(address account) public onlyOwner {
        _isExcludedFromFee[account] = false;
    }

    function setTreasury(address treasury) public onlyOwner {
        require(_treasury == address(0), "treasury has been set");
        _isExcludedFromFee[treasury] = true;
        _treasury = treasury;
    }

    function swapPair() external view returns(address) {
        return _uniswapV2Pair;
    }

}
