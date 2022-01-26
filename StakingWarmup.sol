// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.7.5;

import './interfaces/IERC20.sol';
import './interfaces/IWarmup.sol';


contract StakingWarmup is IWarmup {

    address public immutable staking;
    address public immutable sDUM;

    constructor ( address _staking, address _sDUM ) {
        require( _staking != address(0) );
        staking = _staking;
        require( _sDUM != address(0) );
        sDUM = _sDUM;
    }

    function retrieve( address _staker, uint _amount ) override external {
        require( msg.sender == staking );
        IERC20( sDUM ).transfer( _staker, _amount );
    }
}