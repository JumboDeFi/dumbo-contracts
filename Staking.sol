// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;

import './libraries/Ownable.sol';
import './libraries/SafeMath.sol';
import './libraries/SafeERC20.sol';

import './interfaces/IWarmup.sol';
import './interfaces/IStakedDumboERC20.sol';
import './interfaces/IStaking.sol';
import './interfaces/IDistributor.sol';


contract DumboStaking is IStaking, Ownable {

    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public immutable DUM;
    address public immutable sDUM;

    struct Epoch {
        uint length;
        uint number;
        uint endBlock;
        uint distribute;
    }
    Epoch public epoch;

    address public distributor;
    
    address public locker;
    uint public totalBonus;
    
    address public warmupContract;
    uint public warmupPeriod;
    
    constructor (address _DUM, address _sDUM, uint _epochLength, uint _firstEpochNumber,uint _firstEpochBlock) {
        require( _DUM != address(0) );
        DUM = _DUM;
        require( _sDUM != address(0) );
        sDUM = _sDUM;
        
        if (_firstEpochBlock == 0) _firstEpochBlock = block.number;

        epoch = Epoch({
            length: _epochLength,
            number: _firstEpochNumber,
            endBlock: _firstEpochBlock,
            distribute: 0
        });
    }

    struct Claim {
        uint deposit;
        uint gons;
        uint expiry;
        bool lock; // prevents malicious delays
    }
    mapping( address => Claim ) public warmupInfo;

    /**
        @notice stake DUM to enter warmup
        @param _amount uint
        @return bool
     */
    function stake( uint _amount, address _recipient ) external override returns ( bool ) {
        rebase();
        
        IERC20( DUM ).safeTransferFrom( msg.sender, address(this), _amount );

        Claim memory info = warmupInfo[ _recipient ];
        require( !info.lock, "Deposits for account are locked" );

        if (warmupPeriod > 0) {
            warmupInfo[ _recipient ] = Claim ({
                deposit: info.deposit.add( _amount ),
                gons: info.gons.add( IStakedDumboERC20( sDUM ).gonsForBalance( _amount ) ),
                expiry: epoch.number.add( warmupPeriod ),
                lock: false
            });
            IERC20( sDUM ).safeTransfer( warmupContract, _amount );
        } else {
            IERC20( sDUM ).safeTransfer( _recipient, _amount );
        }
        
        return true;
    }

    /**
        @notice retrieve sDUM from warmup
        @param _recipient address
     */
    function claim ( address _recipient ) public override {
        Claim memory info = warmupInfo[ _recipient ];
        if ( epoch.number >= info.expiry && info.expiry != 0 ) {
            delete warmupInfo[ _recipient ];
            IWarmup( warmupContract ).retrieve( _recipient, IStakedDumboERC20( sDUM ).balanceForGons( info.gons ) );
        }
    }

    /**
        @notice forfeit sDUM in warmup and retrieve DUM
     */
    function forfeit() external {
        Claim memory info = warmupInfo[ msg.sender ];
        delete warmupInfo[ msg.sender ];

        IWarmup( warmupContract ).retrieve( address(this), IStakedDumboERC20( sDUM ).balanceForGons( info.gons ) );
        IERC20( DUM ).safeTransfer( msg.sender, info.deposit );
    }

    /**
        @notice prevent new deposits to address (protection from malicious activity)
     */
    function toggleDepositLock() external {
        warmupInfo[ msg.sender ].lock = !warmupInfo[ msg.sender ].lock;
    }

    /**
        @notice redeem sDUM for DUM
        @param _amount uint
        @param _trigger bool
     */
    function unstake( uint _amount, bool _trigger ) external override {
        require(_amount <= contractBalance(), "Insufficient contract balance");
        if ( _trigger ) {
            rebase();
        }
        IERC20( sDUM ).safeTransferFrom( msg.sender, address(this), _amount );
        IERC20( DUM ).safeTransfer( msg.sender, _amount );
    }

    /**
        @notice returns the sDUM index, which tracks rebase growth
        @return uint
     */
    function index() public view override returns ( uint ) {
        return IStakedDumboERC20( sDUM ).index();
    }

    /**
        @notice trigger rebase if epoch over
     */
    function rebase() public {
        if( epoch.endBlock <= block.number ) {

            uint distribute = epoch.distribute.mul(8).div(10);  // 80%
            IStakedDumboERC20( sDUM ).rebase( distribute, epoch.number );

            epoch.endBlock = epoch.endBlock.add( epoch.length );
            epoch.number++;
            
            if ( distributor != address(0) ) {
                IDistributor( distributor ).distribute();
            }

            uint balance = contractBalance();
            uint staked = IStakedDumboERC20( sDUM ).circulatingSupply();

            if( balance <= staked ) {
                epoch.distribute = 0;
            } else {
                epoch.distribute = balance.sub( staked );
            }
        }
    }

    /**
        @notice returns contract DUM holdings, including bonuses provided
        @return uint
     */
    function contractBalance() public view returns ( uint ) {
        return IERC20( DUM ).balanceOf( address(this) ).add( totalBonus );
    }

    /**
        @notice provide bonus to locked staking contract
        @param _amount uint
     */
    function giveLockBonus( uint _amount ) external {
        require( msg.sender == locker );
        totalBonus = totalBonus.add( _amount );
        IERC20( sDUM ).safeTransfer( locker, _amount );
    }

    /**
        @notice reclaim bonus from locked staking contract
        @param _amount uint
     */
    function returnLockBonus( uint _amount ) external {
        require( msg.sender == locker );
        totalBonus = totalBonus.sub( _amount );
        IERC20( sDUM ).safeTransferFrom( locker, address(this), _amount );
    }

    enum CONTRACTS { DISTRIBUTOR, WARMUP, LOCKER }

    /**
        @notice sets the contract address for LP staking
        @param _contract address
     */
    function setContract( CONTRACTS _contract, address _address ) external onlyOwner() {
        if( _contract == CONTRACTS.DISTRIBUTOR ) { // 0
            distributor = _address;
        } else if ( _contract == CONTRACTS.WARMUP ) { // 1
            require( warmupContract == address( 0 ), "Warmup cannot be set more than once" );
            warmupContract = _address;
        } else if ( _contract == CONTRACTS.LOCKER ) { // 2
            require( locker == address(0), "Locker cannot be set more than once" );
            locker = _address;
        }
    }
    
    /**
     * @notice set warmup period for new stakers
     * @param _warmupPeriod uint
     */
    function setWarmup( uint _warmupPeriod ) external onlyOwner() {
        warmupPeriod = _warmupPeriod;
    }
}