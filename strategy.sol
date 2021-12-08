// SPDX-License-Identifier: AGPL-3.0

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {BaseStrategy} from "@yearnvaults/contracts/BaseStrategy.sol";
import {
    SafeERC20,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/math/Math.sol";

import {IBalancerVault} from "../interfaces/IBalancerVault.sol";
import {IBalancerStablePool} from "../interfaces/IBalancerStablePool.sol";
import {IBalancerPool} from "../interfaces/IBalancerPool.sol";
import {IAsset} from "../interfaces/IAsset.sol";
import {IBeethovenxChef} from "../interfaces/IBeethovenxChef.sol";

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    IERC20 internal constant weth =
        IERC20(address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    IBalancerVault public balancerVault;
    IBalancerPool public bpt;
    IERC20 public rewardToken;
    IAsset[] internal assets;
    SwapSteps internal swapSteps;
    uint256[] internal minAmountsOut;
    bytes32 internal balancerPoolId;
    uint8 internal numTokens;
    uint8 internal tokenIndex;
    bool internal abandonRewards;

    // masterchef
    IBeethovenxChef internal masterChef;
    IAsset[] internal stakeAssets;
    IBalancerPool public stakeBpt;
    uint256 internal stakeTokenIndex;
    uint256 internal stakePercentage;
    uint256 internal unstakePercentage;

    struct SwapSteps {
        bytes32[] poolIds;
        IAsset[] assets;
    }

    uint256 internal constant max = type(uint256).max;

    //	  1	0.01%
    //	  5	0.05%
    //   10	0.1%
    //   50	0.5%
    //  100	1%
    // 1000	10%
    //10000	100%
    uint256 public maxSlippageIn; // bips
    uint256 public maxSlippageOut; // bips
    uint256 public maxSingleDeposit;
    uint256 public minDepositPeriod; // seconds
    uint256 public lastDepositTime;
    uint256 internal masterChefPoolId;
    uint256 internal masterChefStakePoolId;
    uint256 internal constant basisOne = 10000;

    constructor(
        address _vault,
        address _balancerVault,
        address _balancerPool,
        address _masterChef,
        uint256 _maxSlippageIn,
        uint256 _maxSlippageOut,
        uint256 _maxSingleDeposit,
        uint256 _minDepositPeriod,
        uint256 _masterChefPoolId
    ) public BaseStrategy(_vault) {
        healthCheck = address(0xf13Cd6887C62B5beC145e30c38c4938c5E627fe0);
        bpt = IBalancerPool(_balancerPool);
        balancerPoolId = bpt.getPoolId();
        balancerVault = IBalancerVault(_balancerVault);
        (IERC20[] memory tokens, , ) =
            balancerVault.getPoolTokens(balancerPoolId);
        numTokens = uint8(tokens.length);
        assets = new IAsset[](numTokens);
        tokenIndex = type(uint8).max;
        for (uint8 i = 0; i < numTokens; i++) {
            if (tokens[i] == want) {
                tokenIndex = i;
            }
            assets[i] = IAsset(address(tokens[i]));
        }
        require(tokenIndex != type(uint8).max, "token not in pool!");

        maxSlippageIn = _maxSlippageIn;
        maxSlippageOut = _maxSlippageOut;
        maxSingleDeposit = _maxSingleDeposit.mul(
            10**uint256(ERC20(address(want)).decimals())
        );
        minAmountsOut = new uint256[](numTokens);
        minDepositPeriod = _minDepositPeriod;
        masterChefPoolId = _masterChefPoolId;
        masterChef = IBeethovenxChef(_masterChef);
        require(masterChef.lpTokens(masterChefPoolId) == address(bpt));

        want.safeApprove(address(balancerVault), max);
        bpt.approve(address(masterChef), max);
    }

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        // Add your own name here, suggestion e.g. "StrategyCreamYFI"
        return
            string(
                abi.encodePacked(
                    "SingleSidedBeethoven ",
                    bpt.symbol(),
                    "Pool ",
                    ERC20(address(want)).symbol()
                )
            );
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfWant().add(balanceOfPooled());
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        if (_debtOutstanding > 0) {
            (_debtPayment, _loss) = liquidatePosition(_debtOutstanding);
        }

        uint256 beforeWant = balanceOfWant();

        collectTradingFees();
        // claim beets
        claimRewards();
        // consolidate % to stake and unstake
        consolidate();
        // sell the % not staking
        sellRewards();

        uint256 afterWant = balanceOfWant();

        _profit = afterWant.sub(beforeWant);
        if (_profit > _loss) {
            _profit = _profit.sub(_loss);
            _loss = 0;
        } else {
            _loss = _loss.sub(_profit);
            _profit = 0;
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (now - lastDepositTime < minDepositPeriod) {
            return;
        }

        // put want into lp then put want-lp into masterchef
        uint256 pooledBefore = balanceOfPooled();
        uint256 amountIn = Math.min(maxSingleDeposit, balanceOfWant());
        if (joinPool(amountIn, assets, numTokens, tokenIndex, balancerPoolId)) {
            // put all want-lp into masterchef
            masterChef.deposit(masterChefPoolId, balanceOfBpt(), address(this));

            uint256 pooledDelta = balanceOfPooled().sub(pooledBefore);
            uint256 joinSlipped =
                amountIn > pooledDelta ? amountIn.sub(pooledDelta) : 0;
            uint256 maxLoss = amountIn.mul(maxSlippageIn).div(basisOne);
            require(joinSlipped <= maxLoss, "Slipped in!");
            lastDepositTime = now;
        }

        // claim all beets
        claimRewards();
        // and stake all
        stakeAllRewards();
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        if (estimatedTotalAssets() < _amountNeeded) {
            _liquidatedAmount = liquidateAllPositions();
            return (_liquidatedAmount, _amountNeeded.sub(_liquidatedAmount));
        }

        uint256 looseAmount = balanceOfWant();
        if (_amountNeeded > looseAmount) {
            uint256 toExitAmount = _amountNeeded.sub(looseAmount);

            // withdraw all bpt out of masterchef
            masterChef.withdrawAndHarvest(
                masterChefPoolId,
                balanceOfBptInMasterChef(),
                address(this)
            );
            // sell some bpt
            exitPoolExactToken(toExitAmount);
            // put remaining bpt back into masterchef
            masterChef.deposit(masterChefPoolId, balanceOfBpt(), address(this));

            _liquidatedAmount = Math.min(balanceOfWant(), _amountNeeded);
            _loss = _amountNeeded.sub(_liquidatedAmount);

            _enforceSlippageOut(
                toExitAmount,
                _liquidatedAmount.sub(looseAmount)
            );
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function liquidateAllPositions()
        internal
        override
        returns (uint256 liquidated)
    {
        uint256 eta = estimatedTotalAssets();
        // withdraw all bpt out of masterchef
        masterChef.withdrawAndHarvest(
            masterChefPoolId,
            balanceOfBptInMasterChef(),
            address(this)
        );
        // sell all bpt
        exitPoolExactBpt(
            balanceOfBpt(),
            assets,
            tokenIndex,
            balancerPoolId,
            minAmountsOut
        );

        liquidated = balanceOfWant();
        _enforceSlippageOut(eta, liquidated);

        return liquidated;
    }

    // note that this withdraws into newStrategy.
    function prepareMigration(address _newStrategy) internal override {
        _withdrawFromMasterChef(_newStrategy);
        uint256 rewards = balanceOfReward();
        if (rewards > 0) {
            rewardToken.transfer(_newStrategy, rewards);
        }
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}

    function ethToWant(uint256 _amtInWei)
        public
        view
        override
        returns (uint256)
    {}

    function tendTrigger(uint256 callCostInWei)
        public
        view
        override
        returns (bool)
    {
        return
            now.sub(lastDepositTime) > minDepositPeriod && balanceOfWant() > 0;
    }

    // HELPERS //

    // Manually returns lps in masterchef to the strategy. Used in emergencies.
    function emergencyWithdrawFromMasterChef() external onlyVaultManagers {
        _withdrawFromMasterChef(address(this));
    }

    // AbandonRewards withdraws lp without rewards. Specify where to withdraw to
    function _withdrawFromMasterChef(address _to) internal {
        uint256 balanceOfBptInMasterChef = balanceOfBptInMasterChef();
        if (balanceOfBptInMasterChef > 0) {
            abandonRewards
                ? masterChef.emergencyWithdraw(masterChefPoolId, address(_to))
                : masterChef.withdrawAndHarvest(
                    masterChefPoolId,
                    balanceOfBptInMasterChef,
                    address(_to)
                );
        }

        uint256 balanceOfStakeBptInMasterChef = balanceOfStakeBptInMasterChef();
        if (balanceOfStakeBptInMasterChef > 0) {
            abandonRewards
                ? masterChef.emergencyWithdraw(
                    masterChefStakePoolId,
                    address(_to)
                )
                : masterChef.withdrawAndHarvest(
                    masterChefStakePoolId,
                    balanceOfStakeBptInMasterChef,
                    address(_to)
                );
        }
    }

    // claim all beets rewards from masterchef
    function claimRewards() internal {
        masterChef.harvest(masterChefPoolId, address(this));
        masterChef.harvest(masterChefStakePoolId, address(this));
    }

    function sellRewards() internal {
        uint256 amount = balanceOfReward();
        uint256 decReward = ERC20(address(rewardToken)).decimals();
        uint256 decWant = ERC20(address(want)).decimals();

        if (amount > 10**(decReward > decWant ? decReward.sub(decWant) : 0)) {
            uint256 length = swapSteps.poolIds.length;
            IBalancerVault.BatchSwapStep[] memory steps =
                new IBalancerVault.BatchSwapStep[](length);
            int256[] memory limits = new int256[](length + 1);
            limits[0] = int256(amount);
            for (uint256 j = 0; j < length; j++) {
                steps[j] = IBalancerVault.BatchSwapStep(
                    swapSteps.poolIds[j],
                    j,
                    j + 1,
                    j == 0 ? amount : 0,
                    abi.encode(0)
                );
            }
            balancerVault.batchSwap(
                IBalancerVault.SwapKind.GIVEN_IN,
                steps,
                swapSteps.assets,
                IBalancerVault.FundManagement(
                    address(this),
                    false,
                    address(this),
                    false
                ),
                limits,
                now + 10
            );
        }
    }

    function collectTradingFees() internal {
        uint256 total = estimatedTotalAssets();
        uint256 debt = vault.strategies(address(this)).totalDebt;
        if (total > debt) {
            // withdraw all bpt out of masterchef
            masterChef.withdrawAndHarvest(
                masterChefPoolId,
                balanceOfBptInMasterChef(),
                address(this)
            );
            uint256 profit = total.sub(debt);
            exitPoolExactToken(profit);
            // put remaining bpt back into masterchef
            masterChef.deposit(masterChefPoolId, balanceOfBpt(), address(this));
        }
    }

    function balanceOfWant() public view returns (uint256 _amount) {
        return want.balanceOf(address(this));
    }

    function balanceOfBpt() public view returns (uint256 _amount) {
        return bpt.balanceOf(address(this));
    }

    function balanceOfBptInMasterChef() public view returns (uint256 _amount) {
        (_amount, ) = masterChef.userInfo(masterChefPoolId, address(this));
    }

    function balanceOfStakeBptInMasterChef()
        public
        view
        returns (uint256 _amount)
    {
        (_amount, ) = masterChef.userInfo(masterChefStakePoolId, address(this));
    }

    function balanceOfReward() public view returns (uint256 _amount) {
        return rewardToken.balanceOf(address(this));
    }

    function balanceOfPooled() public view returns (uint256 _amount) {
        uint256 totalWantPooled;
        (
            IERC20[] memory tokens,
            uint256[] memory totalBalances,
            uint256 lastChangeBlock
        ) = balancerVault.getPoolTokens(balancerPoolId);
        for (uint8 i = 0; i < numTokens; i++) {
            uint256 tokenPooled =
                totalBalances[i]
                    .mul(balanceOfBpt().add(balanceOfBptInMasterChef()))
                    .div(bpt.totalSupply());
            if (tokenPooled > 0) {
                IERC20 token = tokens[i];
                if (token != want) {
                    IBalancerPool.SwapRequest memory request =
                        _getSwapRequest(token, tokenPooled, lastChangeBlock);
                    // now denominated in want
                    tokenPooled = bpt.onSwap(
                        request,
                        totalBalances,
                        i,
                        tokenIndex
                    );
                }
                totalWantPooled += tokenPooled;
            }
        }
        return totalWantPooled;
    }

    function _getSwapRequest(
        IERC20 token,
        uint256 amount,
        uint256 lastChangeBlock
    ) internal view returns (IBalancerPool.SwapRequest memory request) {
        return
            IBalancerPool.SwapRequest(
                IBalancerPool.SwapKind.GIVEN_IN,
                token,
                want,
                amount,
                balancerPoolId,
                lastChangeBlock,
                address(this),
                address(this),
                abi.encode(0)
            );
    }

    // exit a pool given exact bpt amount
    function exitPoolExactBpt(
        uint256 _bpts,
        IAsset[] memory _assets,
        uint256 _tokenIndex,
        bytes32 _balancerPoolId,
        uint256[] memory _minAmountsOut
    ) internal {
        if (_bpts > 0) {
            // exit entire position for single token. Could revert due to single exit limit enforced by balancer
            bytes memory userData =
                abi.encode(
                    IBalancerVault.ExitKind.EXACT_BPT_IN_FOR_ONE_TOKEN_OUT,
                    _bpts,
                    _tokenIndex
                );
            IBalancerVault.ExitPoolRequest memory request =
                IBalancerVault.ExitPoolRequest(
                    _assets,
                    _minAmountsOut,
                    userData,
                    false
                );
            balancerVault.exitPool(
                _balancerPoolId,
                address(this),
                address(this),
                request
            );
        }
    }

    // exit a pool given exact token amount
    function exitPoolExactToken(uint256 _amountTokenOut) internal {
        uint256[] memory amountsOut = new uint256[](numTokens);
        amountsOut[tokenIndex] = _amountTokenOut;
        bytes memory userData =
            abi.encode(
                IBalancerVault.ExitKind.BPT_IN_FOR_EXACT_TOKENS_OUT,
                amountsOut,
                balanceOfBpt()
            );
        IBalancerVault.ExitPoolRequest memory request =
            IBalancerVault.ExitPoolRequest(
                assets,
                minAmountsOut,
                userData,
                false
            );
        balancerVault.exitPool(
            balancerPoolId,
            address(this),
            address(this),
            request
        );
    }

    // join pool given exact token in
    function joinPool(
        uint256 _amountIn,
        IAsset[] memory _assets,
        uint256 _numTokens,
        uint256 _tokenIndex,
        bytes32 _poolId
    ) internal returns (bool _joined) {
        uint256[] memory maxAmountsIn = new uint256[](_numTokens);
        maxAmountsIn[_tokenIndex] = _amountIn;
        if (_amountIn > 0) {
            bytes memory userData =
                abi.encode(
                    IBalancerVault.JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT,
                    maxAmountsIn,
                    0
                );
            IBalancerVault.JoinPoolRequest memory request =
                IBalancerVault.JoinPoolRequest(
                    _assets,
                    maxAmountsIn,
                    userData,
                    false
                );
            balancerVault.joinPool(
                _poolId,
                address(this),
                address(this),
                request
            );
            return true;
        }
        return false;
    }

    function whitelistReward(address _rewardToken, SwapSteps memory _steps)
        public
        onlyVaultManagers
    {
        rewardToken = IERC20(_rewardToken);
        rewardToken.approve(address(balancerVault), max);
        swapSteps = _steps;
    }

    function setParams(
        uint256 _maxSlippageIn,
        uint256 _maxSlippageOut,
        uint256 _maxSingleDeposit,
        uint256 _minDepositPeriod
    ) public onlyVaultManagers {
        require(_maxSlippageIn <= basisOne);
        maxSlippageIn = _maxSlippageIn;

        require(_maxSlippageOut <= basisOne);
        maxSlippageOut = _maxSlippageOut;

        maxSingleDeposit = _maxSingleDeposit;
        minDepositPeriod = _minDepositPeriod;
    }

    // revert if slippage out exceeds our requirement
    function _enforceSlippageOut(uint256 _intended, uint256 _actual)
        internal
        view
    {
        // enforce that amount exited didn't slip beyond our tolerance
        // just in case there's positive slippage
        uint256 exitSlipped = _intended > _actual ? _intended.sub(_actual) : 0;
        uint256 maxLoss = _intended.mul(maxSlippageOut).div(basisOne);
        require(exitSlipped <= maxLoss, "Slipped Out!");
    }

    // swap step contains information on multihop sells
    function getSwapSteps() public view returns (SwapSteps memory) {
        return swapSteps;
    }

    // masterchef contract in case of masterchef migration
    function setMasterChef(address _masterChef) public onlyGovernance {
        _withdrawFromMasterChef(address(this));

        bpt.approve(address(masterChef), 0);
        stakeBpt.approve(address(masterChef), 0);
        masterChef = IBeethovenxChef(_masterChef);
        bpt.approve(address(masterChef), max);
        stakeBpt.approve(address(masterChef), max);
    }

    // calculate how much beets to unstake and stake
    function consolidate() internal {
        // pre-calc amount beets to stake
        uint256 toStake = balanceOfReward().mul(stakePercentage).div(basisOne);
        // unstake a % of staked beets
        unstake();
        // stake pre-calc amount of beets for higher apy
        stake(toStake);
    }

    // stake all beets
    function stakeAllRewards() internal {
        stake(balanceOfReward());
    }

    // stake beets into beets-lp, then beets-lp into masterchef
    function stake(uint256 _amount) internal {
        if (
            joinPool(
                _amount,
                stakeAssets,
                stakeAssets.length,
                stakeTokenIndex,
                stakeBpt.getPoolId()
            )
        ) {
            masterChef.deposit(
                masterChefStakePoolId,
                stakeBpt.balanceOf(address(this)),
                address(this)
            );
        }
    }

    // unstake a % beets-lp from masterchef, single sided withdraw beets from beets-lp
    function unstake() internal {
        uint256 bpts =
            balanceOfStakeBptInMasterChef().mul(unstakePercentage).div(
                basisOne
            );
        masterChef.withdrawAndHarvest(
            masterChefStakePoolId,
            bpts,
            address(this)
        );
        exitPoolExactBpt(
            bpts,
            stakeAssets,
            stakeTokenIndex,
            stakeBpt.getPoolId(),
            new uint256[](stakeAssets.length)
        );
    }

    // set params for staking %
    function setStakeParams(
        uint256 _stakePercentageBips,
        uint256 _unstakePercentageBips
    ) public onlyVaultManagers {
        stakePercentage = _stakePercentageBips;
        unstakePercentage = _unstakePercentageBips;
    }

    // set info of where to stake the beets. Managers can change this to follow optimal yield
    function setStakeInfo(
        IAsset[] memory _stakeAssets,
        address _stakePool,
        uint256 _stakeTokenIndex,
        uint256 _masterChefStakePoolId
    ) public onlyVaultManagers {
        stakeAssets = _stakeAssets;
        masterChefStakePoolId = _masterChefStakePoolId;
        stakeBpt = IBalancerPool(_stakePool);
        stakeBpt.approve(address(masterChef), max);
        stakeTokenIndex = _stakeTokenIndex;
    }

    // toggle for whether to abandon rewards or not on emergency withdraws from masterchef
    function setAbandonRewards(bool abandon) external onlyVaultManagers {
        abandonRewards = abandon;
    }

    receive() external payable {}
}
