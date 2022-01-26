// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;

import './libraries/ERC20Permit.sol';
import './libraries/Ownable.sol';
import './interfaces/IStakedDumboERC20.sol';
import './interfaces/IRelations.sol';

contract StakedDumboERC20 is ERC20Permit, IStakedDumboERC20, Ownable {

    using SafeMath for uint256;

    modifier onlyStakingContract() {
        require( msg.sender == stakingContract );
        _;
    }

    address public stakingContract;
    address public initializer;
    address public relations;
    address public DAO;

    event LogSupply(uint256 indexed epoch, uint256 timestamp, uint256 totalSupply );
    event LogRebase( uint256 indexed epoch, uint256 rebase, uint256 index );
    event LogStakingContractUpdated( address stakingContract );

    struct Rebase {
        uint epoch;
        uint rebase; // 18 decimals
        uint totalStakedBefore;
        uint totalStakedAfter;
        uint amountRebased;
        uint index;
        uint blockNumberOccured;
    }
    Rebase[] public rebases;

    uint public INDEX;

    uint256 private constant MAX_UINT256 = ~uint256(0);
    uint256 private constant INITIAL_FRAGMENTS_SUPPLY = 5000000 * 10**9; // 50m

    // TOTAL_GONS is a multiple of INITIAL_FRAGMENTS_SUPPLY so that _gonsPerFragment is an integer.
    // Use the highest value that fits in a uint256 for max granularity.
    uint256 private constant TOTAL_GONS = MAX_UINT256 - (MAX_UINT256 % INITIAL_FRAGMENTS_SUPPLY);

    // MAX_SUPPLY = maximum integer < (sqrt(4*TOTAL_GONS + 1) - 1) / 2
    uint256 private constant MAX_SUPPLY = ~uint128(0);  // (2^128) - 1

    uint256 private _gonsPerFragment;
    mapping(address => uint256) private _gonBalances;

    mapping ( address => mapping ( address => uint256 ) ) private _allowedValue;

    mapping(address => uint256) private _balanceCache;
    mapping(address => uint256) private _rewards;

    constructor(address _DAO, address _relations) ERC20("Staked Dumbo", "sDUM", 9) ERC20Permit() {
        initializer = msg.sender;
        DAO = _DAO;
        relations = _relations;

        _totalSupply = INITIAL_FRAGMENTS_SUPPLY;
        _gonsPerFragment = TOTAL_GONS.div(_totalSupply);
    }

    function initialize( address stakingContract_ ) external returns ( bool ) {
        require( msg.sender == initializer );
        require( stakingContract_ != address(0) );
        stakingContract = stakingContract_;
        _gonBalances[ stakingContract ] = TOTAL_GONS;

        emit Transfer( address(0x0), stakingContract, _totalSupply );
        emit LogStakingContractUpdated( stakingContract_ );
        
        initializer = address(0);
        return true;
    }

    function setIndex( uint _INDEX ) external onlyOwner() returns ( bool ) {
        require( INDEX == 0 );
        INDEX = gonsForBalance( _INDEX );
        return true;
    }

    /**
        @notice increases sOHM supply to increase staking balances relative to profit_
        @param profit_ uint256
        @return uint256
     */
    function rebase( uint256 profit_, uint epoch_ ) public override onlyStakingContract() returns ( uint256 ) {
        uint256 rebaseAmount;
        uint256 circulatingSupply_ = circulatingSupply();

        if ( profit_ == 0 ) {
            emit LogSupply( epoch_, block.timestamp, _totalSupply );
            emit LogRebase( epoch_, 0, index() );
            return _totalSupply;
        } else if ( circulatingSupply_ > 0 ){
            rebaseAmount = profit_.mul( _totalSupply ).div( circulatingSupply_ );
        } else {
            rebaseAmount = profit_;
        }

        _totalSupply = _totalSupply.add( rebaseAmount );

        if ( _totalSupply > MAX_SUPPLY ) {
            _totalSupply = MAX_SUPPLY;
        }

        _gonsPerFragment = TOTAL_GONS.div( _totalSupply );

        _storeRebase( circulatingSupply_, profit_, epoch_ );

        return _totalSupply;
    }

    /**
        @notice emits event with data about rebase
        @param previousCirculating_ uint
        @param profit_ uint
        @param epoch_ uint
        @return bool
     */
    function _storeRebase( uint previousCirculating_, uint profit_, uint epoch_ ) internal returns ( bool ) {
        uint rebasePercent = profit_.mul( 1e18 ).div( previousCirculating_ );

        rebases.push( Rebase ( {
            epoch: epoch_,
            rebase: rebasePercent, // 18 decimals
            totalStakedBefore: previousCirculating_,
            totalStakedAfter: circulatingSupply(),
            amountRebased: profit_,
            index: index(),
            blockNumberOccured: block.number
        }));
        
        emit LogSupply( epoch_, block.timestamp, _totalSupply );
        emit LogRebase( epoch_, rebasePercent, index() );

        return true;
    }

    function updateReward(address who) public {
        _updateReward(who, 0, false);
    }

    function _updateReward(address who, uint gonValue, bool isPositive) private {
        uint oldBalance = _balanceCache[who];
        uint nowBalance = balanceOf(who);
        uint addValue = (nowBalance > oldBalance ? nowBalance - oldBalance : 0);
        if (addValue > 0) {
            // 给自己结算奖励
            uint myRewards = _rewards[who];
            if (myRewards > 0) {
                _rewards[who] = 0; // clear
                uint addGons = gonsForBalance(addValue);
                if (myRewards > addGons) {
                    myRewards = addGons;
                }
                // 将奖励转换成sdum
                _gonBalances[who] = _gonBalances[who].add(addGons);
            }
        }
        uint rewardValue = addValue.div(5);
        if (rewardValue > 0) {
            // 给别人结算奖励
            IRelations relationsContract = IRelations(relations);
            address inviter = relationsContract.getInviter(who);
            if (inviter == address(0)) {
                inviter = DAO;
            }
            uint rewardGons = gonsForBalance(rewardValue);
            _rewards[inviter] = _rewards[inviter].add(rewardGons);
        }
        uint gonBalance = _gonBalances[who];
        if (gonValue > 0) {
            gonBalance = isPositive ? gonBalance.add(gonValue) : gonBalance.sub(gonValue);
        }
        _balanceCache[who] = balanceForGons(gonBalance);
    }

    function claimRewards(address who) public {

    }

    function balanceOf( address who ) public view override(ERC20, IStakedDumboERC20) returns ( uint256 ) {
        return _gonBalances[ who ].div( _gonsPerFragment );
    }

    function rewardOf( address who ) public view returns ( uint256 ) {
        return _rewards[ who ].div( _gonsPerFragment );
    }

    function gonsForBalance( uint amount ) public view override returns ( uint ) {
        return amount.mul( _gonsPerFragment );
    }

    function balanceForGons( uint gons ) public view override returns ( uint ) {
        return gons.div( _gonsPerFragment );
    }

    // Staking contract holds excess sOHM
    function circulatingSupply() public view override returns ( uint ) {
        return _totalSupply.sub( balanceOf( stakingContract ) );
    }

    function index() public view override returns ( uint ) {
        return balanceForGons( INDEX );
    }

    function _transfer( address from,  address to, uint256 value ) internal override  {
        uint256 gonValue = value.mul( _gonsPerFragment );

        _updateReward(from, gonValue, false);
        _gonBalances[ from ] = _gonBalances[ from ].sub( gonValue );

        _updateReward(to, gonValue, true);
        _gonBalances[ to ] = _gonBalances[ to ].add( gonValue );

        emit Transfer( from, to, value );
    }

    function allowance( address owner_, address spender ) public view override returns ( uint256 ) {
        return _allowedValue[ owner_ ][ spender ];
    }

    function transferFrom( address from, address to, uint256 value ) public override returns ( bool ) {
       _allowedValue[ from ][ msg.sender ] = _allowedValue[ from ][ msg.sender ].sub( value );
       emit Approval( from, msg.sender,  _allowedValue[ from ][ msg.sender ] );

        _transfer(from, to, value);

        return true;
    }

    function approve( address spender, uint256 value ) public override returns (bool) {
         _allowedValue[ msg.sender ][ spender ] = value;
         emit Approval( msg.sender, spender, value );
         return true;
    }

    // What gets called in a permit
    function _approve( address owner, address spender, uint256 value ) internal override virtual {
        _allowedValue[owner][spender] = value;
        emit Approval( owner, spender, value );
    }

    function increaseAllowance( address spender, uint256 addedValue ) public override returns (bool) {
        _allowedValue[ msg.sender ][ spender ] = _allowedValue[ msg.sender ][ spender ].add( addedValue );
        emit Approval( msg.sender, spender, _allowedValue[ msg.sender ][ spender ] );
        return true;
    }

    function decreaseAllowance( address spender, uint256 subtractedValue ) public override returns (bool) {
        uint256 oldValue = _allowedValue[ msg.sender ][ spender ];
        if (subtractedValue >= oldValue) {
            _allowedValue[ msg.sender ][ spender ] = 0;
        } else {
            _allowedValue[ msg.sender ][ spender ] = oldValue.sub( subtractedValue );
        }
        emit Approval( msg.sender, spender, _allowedValue[ msg.sender ][ spender ] );
        return true;
    }
}