
// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelinV3/contracts/token/ERC20/SafeERC20.sol";

/*
    This zap performs each of the following conversions
    1) CRV -> LP -> vault deposit
    2) CRV -> yvBOOST
    3) yvBOOST -> LP -> vault deposit
    4) LP vault -> yveCRV -> yvBOOST
*/

interface ICurve {
    function exchange(int128 i, int128 j, uint256 dx, uint256 _min_dy) external returns (uint256);
    function add_liquidity(uint256[2] calldata amounts, uint256 _min_mint_amount) external returns (uint256);
    function remove_liquidity_one_coin(uint256 _token_amount, int128 i, uint256 min_amount) external returns (uint256);
    function get_dy(int128 i, int128 j, uint256 dx) external returns (uint256);
    function get_balances() external returns (uint256[2] calldata);
}

interface IVault {
    function withdraw(uint256 amount) external returns (uint256);
    function deposit(uint256 amount, address receiver) external returns (uint256);
}

interface IVaultV1 {
    function deposit(uint256 amount) external;
}

contract ZapYearnVeCRV {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public gov = 0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52;
    IERC20 public CRV = IERC20(0xD533a949740bb3306d119CC777fa900bA034cd52);
    IERC20 public yveCRV = IERC20(0xc5bDdf9843308380375a611c18B50Fb9341f502A);
    IVault public yvBOOST = IVault(0x9d409a0A012CFbA9B15F6D4B36Ac57A46966Ab9a);
    IVault public yvCrvYveCRV = IVault(0x2E919d27D515868f3D5Bc9110fa738f9449FC6ad);
    ICurve public pool = ICurve(0x7E46fd8a30869aa9ed55af031067Df666EfE87da);  

    constructor() public {
        CRV.approve(address(pool), type(uint256).max);
        CRV.approve(address(yveCRV), type(uint256).max);
        yveCRV.approve(address(pool), type(uint256).max);
        yveCRV.approve(address(yvBOOST), type(uint256).max);
        IERC20(address(pool)).approve(address(yvCrvYveCRV), type(uint256).max);
    }

    /// @notice Convert CRV to yvBOOST by trading to yveCRV and depositing
    /// @dev We dynamically choose whether to mint or swap based on expected output
    /// @param _amount Amount of CRV to convert
    /// @param _minOut Minimum yveCRV out from the CRV --> yveCRV swap
    /// @return uint256 Amount of yvBOOST received
    function zapCRVtoYvBOOST(uint256 _amount, uint256 _minOut, address _recipient) external returns (uint256) {
        CRV.transferFrom(msg.sender, address(this), _amount);
        if (_amount > projectSwapAmount(_amount)){
            IVaultV1(address(yveCRV)).deposit(_amount);
        }
        else {
            _amount = pool.exchange(0, 1, _amount, _minOut);
        }
        return yvBOOST.deposit(_amount, _recipient);
    }

    /// @notice Convert CRV to LPs and deposit into Yearn vault to compound
    /// @dev We dynamically choose whether to mint or swap based on expected output
    /// @param _amount Amount of CRV to convert
    /// @param _minOut Minimum acceptable amount of LP tokens to mint from the deposit
    /// @return uint256 Amount of yvTokens received
    function zapCRVtoLPVault(uint256 _amount, uint256 _minOut, address _recipient) external returns (uint256) {
        CRV.transferFrom(msg.sender, address(this), _amount);
        uint256[2] memory amounts;
        uint256[2] memory balances = pool.get_balances();
        if (balances[0] > balances[1]){
            IVaultV1(address(yveCRV)).deposit(_amount);
            amounts[1] = _amount;
        }
        else {
            amounts[0] = _amount;
        }
        uint256 lpAmount = lp(amounts, _minOut);
        return yvCrvYveCRV.deposit(lpAmount, _recipient);
    }

    /// @notice Convert yvBOOST to LP and deposit to vault
    /// @dev use the pool's virtual price to calculate your _minOut parameter.
    /// @param _amount Amount of yvBOOST to convert
    /// @param _minOut Minimum acceptable amount of LP tokens to mint from the deposit
    /// @return uint256 Amount of yvTokens received
    function zapYvBOOSTtoLPVault(uint256 _amount, uint256 _minOut, address _recipient) external returns (uint256) {
        IERC20(address(yvBOOST)).transferFrom(msg.sender, address(this), _amount);
        uint256[2] memory amounts;
        amounts[1] = yvBOOST.withdraw(_amount);
        uint256 lpAmount = lp(amounts, _minOut);
        return yvCrvYveCRV.deposit(lpAmount, _recipient);
    }

    /// @notice Convert from Curve LP yearn vault to yveCRV and then deposit to yvBOOST
    /// @dev use the pool's virtual price to calculate your _minOut parameter.
    /// @param _amount Amount of Curve LP yearn vault tokens
    /// @param _minOut Minimum acceptable amount of yveCRV tokens to receive after burning LPs
    /// @return uint256 Amount of yvBOOST tokens received
    function zapLPVaultToYvBOOST(uint256 _amount, uint256 _minOut, address _recipient) external returns (uint256) {
        IERC20(address(yvCrvYveCRV)).transferFrom(msg.sender, address(this), _amount);
        uint256 lpAmount = yvCrvYveCRV.withdraw(_amount);
        uint256[2] memory balances = pool.get_balances();
        if (balances[0] > balances[1]){
            _amount = pool.remove_liquidity_one_coin(lpAmount, 0, _minOut);
            IVaultV1(address(yveCRV)).deposit(_amount);
        }
        else {
            _amount = pool.remove_liquidity_one_coin(lpAmount, 1, _minOut);
        }
        return yvBOOST.deposit(_amount, _recipient);
    }

    /// @notice Perform single-sided LP from either CRV or yveCRV
    /// @param _amounts Amount of yvBOOST to convert
    /// @param _minOut Minimum acceptable amount of LP tokens to mint from the deposit
    /// @return uint256 Amount of LPs minted
    function lp(uint256[2] memory _amounts, uint256 _minOut) internal returns (uint256) {
        return pool.add_liquidity(_amounts, _minOut);
    }

    /// @notice Used to calculate expected amount out based on input amount
    /// @param _amount Amount of CRV to exchange
    /// @return uint256 Amount of yveCRV output from swap
    function projectSwapAmount(uint256 _amount) internal returns (uint256) {
        return pool.get_dy(0, 1, _amount);
    }

    function sweep(IERC20 _token) external returns (uint256 balance) {
        balance = _token.balanceOf(address(this));
        if (balance > 0) {
            _token.safeTransfer(gov, balance);
        }   
    }
}