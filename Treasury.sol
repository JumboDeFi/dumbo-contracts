// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;

import './libraries/Ownable.sol';
import './libraries/SafeMath.sol';
import './libraries/SafeERC20.sol';

import './interfaces/IDumboERC20.sol';
import './interfaces/ITreasury.sol';
import './interfaces/IBondingCalculator.sol';

contract DumboTreasury is Ownable, ITreasury {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  event Deposit(address indexed token, uint256 amount, uint256 value);
  event Withdrawal(address indexed token, uint256 amount, uint256 value);
  event CreateDebt(
    address indexed debtor,
    address indexed token,
    uint256 amount,
    uint256 value
  );
  event RepayDebt(
    address indexed debtor,
    address indexed token,
    uint256 amount,
    uint256 value
  );
  event ReservesManaged(address indexed token, uint256 amount);
  event ReservesUpdated(uint256 indexed totalReserves);
  event ReservesAudited(uint256 indexed totalReserves);
  event RewardsMinted(
    address indexed caller,
    address indexed recipient,
    uint256 amount
  );
  event ChangeQueued(MANAGING indexed managing, address queued);
  event ChangeActivated(
    MANAGING indexed managing,
    address activated,
    bool result
  );

  enum MANAGING {
    RESERVE_DEPOSITOR,
    RESERVE_SPENDER,
    RESERVE_TOKEN,
    RESERVE_MANAGER,
    LIQUIDITY_DEPOSITOR,
    LIQUIDITY_TOKEN,
    LIQUIDITY_MANAGER,
    DEBTOR,
    REWARD_MANAGER,
    SDUM
  }

  address public immutable DUM;
  uint256 public immutable blocksNeededForQueue;

  address[] public reserveTokens; // Push only, beware false-positives.
  mapping(address => bool) public isReserveToken;
  mapping(address => uint256) public reserveTokenQueue; // Delays changes to mapping.

  address[] public reserveDepositors; // Push only, beware false-positives. Only for viewing.
  mapping(address => bool) public isReserveDepositor;
  mapping(address => uint256) public reserveDepositorQueue; // Delays changes to mapping.

  address[] public reserveSpenders; // Push only, beware false-positives. Only for viewing.
  mapping(address => bool) public isReserveSpender;
  mapping(address => uint256) public reserveSpenderQueue; // Delays changes to mapping.

  address[] public liquidityTokens; // Push only, beware false-positives.
  mapping(address => bool) public isLiquidityToken;
  mapping(address => uint256) public LiquidityTokenQueue; // Delays changes to mapping.

  address[] public liquidityDepositors; // Push only, beware false-positives. Only for viewing.
  mapping(address => bool) public isLiquidityDepositor;
  mapping(address => uint256) public LiquidityDepositorQueue; // Delays changes to mapping.

  mapping(address => address) public bondCalculator; // bond calculator for liquidity token

  address[] public reserveManagers; // Push only, beware false-positives. Only for viewing.
  mapping(address => bool) public isReserveManager;
  mapping(address => uint256) public ReserveManagerQueue; // Delays changes to mapping.

  address[] public liquidityManagers; // Push only, beware false-positives. Only for viewing.
  mapping(address => bool) public isLiquidityManager;
  mapping(address => uint256) public LiquidityManagerQueue; // Delays changes to mapping.

  address[] public debtors; // Push only, beware false-positives. Only for viewing.
  mapping(address => bool) public isDebtor;
  mapping(address => uint256) public debtorQueue; // Delays changes to mapping.
  mapping(address => uint256) public debtorBalance;

  address[] public rewardManagers; // Push only, beware false-positives. Only for viewing.
  mapping(address => bool) public isRewardManager;
  mapping(address => uint256) public rewardManagerQueue; // Delays changes to mapping.

  address public sDUM;
  uint256 public sDUMQueue; // Delays change to sDUM address

  uint256 public totalReserves; // Risk-free value of all assets
  uint256 public totalDebt;

  constructor(
    address _DUM,
    address _BUSD,
    //address _DUMDAI,
    uint256 _blocksNeededForQueue
  ) {
    require(_DUM != address(0));
    DUM = _DUM;

    isReserveToken[_BUSD] = true;
    reserveTokens.push(_BUSD);

    // isLiquidityToken[ _DUMDAI ] = true;
    // liquidityTokens.push( _DUMDAI );

    blocksNeededForQueue = _blocksNeededForQueue;

    // default reserve Depositor
    reserveDepositors.push(_DUM);
    isReserveDepositor[_DUM] = true;

    reserveDepositors.push(msg.sender);
    isReserveDepositor[msg.sender] = true;
  }

  /**
    @notice allow approved address to deposit an asset for DUM
    @param _amount uint
    @param _token address
    @param _profit uint
    @return send_ uint
  */
  function deposit(uint256 _amount, address _token, uint256 _profit) external override returns (uint256 send_){
    require(isReserveToken[_token] || isLiquidityToken[_token], "Not accepted");
    IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);

    if (isReserveToken[_token]) {
      require(isReserveDepositor[msg.sender], "Not approved");
    } else {
      require(isLiquidityDepositor[msg.sender], "Not approved");
    }

    uint256 value = valueOfToken(_token, _amount);
    // (_token, _amount);
    // mint DUM needed and store amount of rewards for distribution
    send_ = value.sub(_profit);
    IDumboERC20(DUM).mint(msg.sender, send_);

    totalReserves = totalReserves.add(value);
    emit ReservesUpdated(totalReserves);

    emit Deposit(_token, _amount, value);
  }

  /**
    @notice allow approved address to burn DUM for reserves
    @param _amount uint
    @param _token address
  */
  function withdraw(uint256 _amount, address _token) external {
    require(isReserveToken[_token], "Not accepted"); // Only reserves can be used for redemptions
    require(isReserveSpender[msg.sender] == true, "Not approved");

    uint256 value = valueOfToken(_token, _amount);
    IDumboERC20(DUM).burnFrom(msg.sender, value);

    totalReserves = totalReserves.sub(value);
    emit ReservesUpdated(totalReserves);

    IERC20(_token).safeTransfer(msg.sender, _amount);

    emit Withdrawal(_token, _amount, value);
  }

  /**
    @notice allow approved address to borrow reserves
    @param _amount uint
    @param _token address
  */
  function incurDebt(uint256 _amount, address _token) external {
    require(isDebtor[msg.sender], "Not approved");
    require(isReserveToken[_token], "Not accepted");

    uint256 value = valueOfToken(_token, _amount);

    uint256 maximumDebt = IERC20(sDUM).balanceOf(msg.sender); // Can only borrow against sDUM held
    uint256 availableDebt = maximumDebt.sub(debtorBalance[msg.sender]);
    require(value <= availableDebt, "Exceeds debt limit");

    debtorBalance[msg.sender] = debtorBalance[msg.sender].add(value);
    totalDebt = totalDebt.add(value);

    totalReserves = totalReserves.sub(value);
    emit ReservesUpdated(totalReserves);

    IERC20(_token).transfer(msg.sender, _amount);

    emit CreateDebt(msg.sender, _token, _amount, value);
  }

  /**
    @notice allow approved address to repay borrowed reserves with reserves
    @param _amount uint
    @param _token address
  */
  function repayDebtWithReserve(uint256 _amount, address _token) external {
    require(isDebtor[msg.sender], "Not approved");
    require(isReserveToken[_token], "Not accepted");

    IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);

    uint256 value = valueOfToken(_token, _amount);
    debtorBalance[msg.sender] = debtorBalance[msg.sender].sub(value);
    totalDebt = totalDebt.sub(value);

    totalReserves = totalReserves.add(value);
    emit ReservesUpdated(totalReserves);

    emit RepayDebt(msg.sender, _token, _amount, value);
  }

  /**
    @notice allow approved address to repay borrowed reserves with DUM
    @param _amount uint
  */
  function repayDebtWithDUM(uint256 _amount) external {
    require(isDebtor[msg.sender], "Not approved");

    IDumboERC20(DUM).burnFrom(msg.sender, _amount);

    debtorBalance[msg.sender] = debtorBalance[msg.sender].sub(_amount);
    totalDebt = totalDebt.sub(_amount);

    emit RepayDebt(msg.sender, DUM, _amount, _amount);
  }

  /**
    @notice allow approved address to withdraw assets
    @param _token address
    @param _amount uint
  */
  function manage(address _token, uint256 _amount) external {
    if (isLiquidityToken[_token]) {
      require(isLiquidityManager[msg.sender], "Not approved");
    } else {
      require(isReserveManager[msg.sender], "Not approved");
    }

    uint256 value = valueOfToken(_token, _amount);

    require(value <= excessReserves(), "Insufficient reserves");

    totalReserves = totalReserves.sub(value);
    emit ReservesUpdated(totalReserves);

    IERC20(_token).safeTransfer(msg.sender, _amount);

    emit ReservesManaged(_token, _amount);
  }

  /**
    @notice send epoch reward to staking contract
  */
  function mintRewards(address _recipient, uint256 _amount) external override {
    require(isRewardManager[msg.sender], "Not approved");
    require(_amount <= excessReserves(), "Insufficient reserves");

    IDumboERC20(DUM).mint(_recipient, _amount);

    emit RewardsMinted(msg.sender, _recipient, _amount);
  }

  /**
    @notice returns excess reserves not backing tokens
    @return uint
  */
  function excessReserves() public view returns (uint256) {
    return totalReserves.sub(IERC20(DUM).totalSupply().sub(totalDebt));
  }

  /**
    @notice takes inventory of all tracked assets
    @notice always consolidate to recognized reserves before audit
  */
  function auditReserves() external onlyOwner {
    uint256 reserves;
    for (uint256 i = 0; i < reserveTokens.length; i++) {
      reserves = reserves.add(
        valueOfToken(
          reserveTokens[i],
          IERC20(reserveTokens[i]).balanceOf(address(this))
        )
      );
    }
    for (uint256 i = 0; i < liquidityTokens.length; i++) {
      reserves = reserves.add(
        valueOfToken(
          liquidityTokens[i],
          IERC20(liquidityTokens[i]).balanceOf(address(this))
        )
      );
    }
    totalReserves = reserves;
    emit ReservesUpdated(reserves);
    emit ReservesAudited(reserves);
  }

  /**
    @notice returns DUM valuation of asset
    @param _token address
    @param _amount uint
    @return value_ uint
  */
  function valueOfToken(address _token, uint256 _amount) public view override returns (uint256 value_) {
    if (isReserveToken[_token]) {
      // convert amount to match DUM decimals  1:1000
      value_ = _amount.mul(10**IERC20(DUM).decimals()).mul(1000).div(10**IERC20(_token).decimals());
    } else if (isLiquidityToken[_token]) {
      value_ = IBondingCalculator(bondCalculator[_token]).valuation( _token, _amount );
    }
  }

  /**
    @notice queue address to change boolean in mapping
    @param _managing MANAGING
    @param _address address
    @return bool
  */
  function queue(MANAGING _managing, address _address) external onlyOwner returns (bool) {
    require(_address != address(0));
    if (_managing == MANAGING.RESERVE_DEPOSITOR) {
      // 0
      reserveDepositorQueue[_address] = block.number.add(blocksNeededForQueue);
    } else if (_managing == MANAGING.RESERVE_SPENDER) {
      // 1
      reserveSpenderQueue[_address] = block.number.add(blocksNeededForQueue);
    } else if (_managing == MANAGING.RESERVE_TOKEN) {
      // 2
      reserveTokenQueue[_address] = block.number.add(blocksNeededForQueue);
    } else if (_managing == MANAGING.RESERVE_MANAGER) {
      // 3
      ReserveManagerQueue[_address] = block.number.add(
        blocksNeededForQueue.mul(2)
      );
    } else if (_managing == MANAGING.LIQUIDITY_DEPOSITOR) {
      // 4
      LiquidityDepositorQueue[_address] = block.number.add(
        blocksNeededForQueue
      );
    } else if (_managing == MANAGING.LIQUIDITY_TOKEN) {
      // 5
      LiquidityTokenQueue[_address] = block.number.add(blocksNeededForQueue);
    } else if (_managing == MANAGING.LIQUIDITY_MANAGER) {
      // 6
      LiquidityManagerQueue[_address] = block.number.add(
        blocksNeededForQueue.mul(2)
      );
    } else if (_managing == MANAGING.DEBTOR) {
      // 7
      debtorQueue[_address] = block.number.add(blocksNeededForQueue);
    } else if (_managing == MANAGING.REWARD_MANAGER) {
      // 8
      rewardManagerQueue[_address] = block.number.add(blocksNeededForQueue);
    } else if (_managing == MANAGING.SDUM) {
      // 9
      sDUMQueue = block.number.add(blocksNeededForQueue);
    } else return false;

    emit ChangeQueued(_managing, _address);
    return true;
  }

  /**
        @notice verify queue then set boolean in mapping
        @param _managing MANAGING
        @param _address address
        @param _calculator address
        @return bool
     */
  function toggle(MANAGING _managing, address _address, address _calculator) external onlyOwner returns (bool) {
    require(_address != address(0));
    bool result;
    if (_managing == MANAGING.RESERVE_DEPOSITOR) {
      // 0
      if (requirements(reserveDepositorQueue, _address)) {
        reserveDepositorQueue[_address] = 0;
        if (!listContains(reserveDepositors, _address)) {
          reserveDepositors.push(_address);
          result = true;
          isReserveDepositor[_address] = true;
        } else {
          _removeFromList(reserveDepositors, _address);
          delete isReserveDepositor[_address];
        }
      }
      
    } else if (_managing == MANAGING.RESERVE_SPENDER) {
      // 1
      if (requirements(reserveSpenderQueue, _address)) {
        reserveSpenderQueue[_address] = 0;
        if (!listContains(reserveSpenders, _address)) {
          reserveSpenders.push(_address);
          result = true;
          isReserveSpender[_address] = true;
        } else {
          _removeFromList(reserveSpenders, _address);
          delete isReserveSpender[_address];
        }
      }
    } else if (_managing == MANAGING.RESERVE_TOKEN) {
      // 2
      if (requirements(reserveTokenQueue, _address)) {
        reserveTokenQueue[_address] = 0;
        if (!listContains(reserveTokens, _address)) {
          reserveTokens.push(_address);
          result = true;
          isReserveToken[_address] = true;
        } else {
          _removeFromList(reserveTokens, _address);
          delete isReserveToken[_address];
        }
      }
    } else if (_managing == MANAGING.RESERVE_MANAGER) {
      // 3
      if (requirements(ReserveManagerQueue, _address)) {
        ReserveManagerQueue[_address] = 0;
        if (!listContains(reserveManagers, _address)) {
          reserveManagers.push(_address);
          result = true;
          isReserveManager[_address] = true;
        } else {
          _removeFromList(reserveManagers, _address);
          delete isReserveManager[_address];
        }
      }
    } else if (_managing == MANAGING.LIQUIDITY_DEPOSITOR) {
      // 4
      if (requirements(LiquidityDepositorQueue, _address)) {
        LiquidityDepositorQueue[_address] = 0;
        if (!listContains(liquidityDepositors, _address)) {
          liquidityDepositors.push(_address);
          result = true;
          isLiquidityDepositor[_address] = true;
        } else {
          _removeFromList(liquidityDepositors, _address);
          delete isLiquidityDepositor[_address];
        }
      }
    } else if (_managing == MANAGING.LIQUIDITY_TOKEN) {
      // 5
      if (requirements(LiquidityTokenQueue, _address)) {
        LiquidityTokenQueue[_address] = 0;
        if (!listContains(liquidityTokens, _address)) {
          liquidityTokens.push(_address);
          result = true;
          isLiquidityToken[_address] = true;
          bondCalculator[_address] = _calculator;
        } else {
          _removeFromList(liquidityTokens, _address);
          delete isLiquidityToken[_address];
          delete bondCalculator[_address];
        }
      }
      
    } else if (_managing == MANAGING.LIQUIDITY_MANAGER) {
      // 6
      if (requirements(LiquidityManagerQueue, _address)) {
        LiquidityManagerQueue[_address] = 0;
        if (!listContains(liquidityManagers, _address)) {
          liquidityManagers.push(_address);
          result = true;
          isLiquidityManager[_address] = true;
        } else {
          _removeFromList(liquidityManagers, _address);
          delete isLiquidityManager[_address];
        }
      }
    } else if (_managing == MANAGING.DEBTOR) {
      // 7
      if (requirements(debtorQueue, _address)) {
        debtorQueue[_address] = 0;
        if (!listContains(debtors, _address)) {
          debtors.push(_address);
          result = true;
          isDebtor[_address] = true;
        } else {
          _removeFromList(debtors, _address);
          delete isDebtor[_address];
        }
      }
    } else if (_managing == MANAGING.REWARD_MANAGER) {
      // 8
      if (requirements(rewardManagerQueue, _address)) {
        rewardManagerQueue[_address] = 0;
        if (!listContains(rewardManagers, _address)) {
          rewardManagers.push(_address);
          result = true;
          isRewardManager[_address] = true;
        } else {
          _removeFromList(rewardManagers, _address);
          delete isRewardManager[_address];
        }
      }
    } else if (_managing == MANAGING.SDUM) {
      // 9
      sDUMQueue = 0;
      sDUM = _address;
      result = true;
    } else return false;

    emit ChangeActivated(_managing, _address, result);
    return true;
  }

  /**
        @notice checks requirements and returns altered structs
        @param queue_ mapping( address => uint )
        @param _address address
        @return bool 
     */
  function requirements(mapping(address => uint256) storage queue_, address _address) internal view returns (bool) {
    require(queue_[_address] != 0, "Must queue");
    require(queue_[_address] <= block.number, "Queue not expired");
    return true;
  }

  /**
    @notice checks array to ensure against duplicate
    @param _list address[]
    @param _token address
    @return bool
  */
  function listContains(address[] storage _list, address _token) internal view returns (bool) {
    for (uint256 i = 0; i < _list.length; i++) {
      if (_list[i] == _token) {
        return true;
      }
    }
    return false;
  }

  /**
    @notice remove the element from the list
    @param list_ address[]
    @param el_ address
    @return uint256
  */
  function _removeFromList(address[] storage list_, address el_) internal returns (uint256) {
    uint256 i;
    for (i = 0; i < list_.length; i++) {
      if (list_[i] == el_) {
          list_[i] = list_[list_.length - 1];
          delete list_[list_.length - 1];
          list_.pop();
          break;
      }
    }

    return i;
    }
}
