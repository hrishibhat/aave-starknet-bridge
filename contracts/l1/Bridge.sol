// SPDX-License-Identifier: Apache-2.0.
pragma solidity ^0.6.12;

import "./libraries/helpers/Cairo.sol";
import "./interfaces/IStarknetMessaging.sol";
import {WadRayMath} from "@aave/protocol-v2/contracts/protocol/libraries/math/WadRayMath.sol";
import {SafeERC20} from "@aave/protocol-v2/contracts/dependencies/openzeppelin/contracts/SafeERC20.sol";
import {IERC20} from "@aave/protocol-v2/contracts/dependencies/openzeppelin/contracts/IERC20.sol";
import {SafeMath} from "@aave/protocol-v2/contracts/dependencies/openzeppelin/contracts/SafeMath.sol";
import {RayMathNoRounding} from "./libraries/math/RayMathNoRounding.sol";
import {ILendingPool} from "@aave/protocol-v2/contracts/interfaces/ILendingPool.sol";
import {IAaveIncentivesController} from "./interfaces/IAaveIncentivesController.sol";
import {IATokenWithPool} from "./interfaces/IATokenWithPool.sol";
import {IScaledBalanceToken} from "@aave/protocol-v2/contracts/interfaces/IScaledBalanceToken.sol";
import {VersionedInitializable} from "@aave/protocol-v2/contracts/protocol/libraries/aave-upgradeability/VersionedInitializable.sol";

contract Bridge is VersionedInitializable {
    IStarknetMessaging public messagingContract;
    uint256 public l2Bridge;
    address[] public approvedL1Tokens;
    IERC20 public rewardToken;
    IAaveIncentivesController public incentivesController;
    // The selector of the "handle_deposit" l1_handler on L2.
    uint256 constant DEPOSIT_HANDLER =
        1285101517810983806491589552491143496277809242732141897358598292095611420389;
    // The selector of the "handle_index_update" l1_handler on L2.
    uint256 constant INDEX_UPDATE_HANDLER =
        309177621854413231845513563663819170511421561802461396722380275428414897390;
    uint256 constant TRANSFER_FROM_STARKNET = 0;
    uint256 constant BRIDGE_REWARD_MESSAGE = 1;
    uint256 constant UINT256_PART_SIZE_BITS = 128;
    uint256 constant UINT256_PART_SIZE = 2**UINT256_PART_SIZE_BITS;
    uint256 public constant BRIDGE_REVISION = 0x1;
    address internal admin;

    struct ATokenData {
        uint256 l2TokenAddress;
        IERC20 underlyingAsset;
        ILendingPool lendingPool;
    }
    mapping(address => ATokenData) public aTokenData;

    using SafeERC20 for IERC20;
    using WadRayMath for uint256;
    using RayMathNoRounding for uint256;
    using SafeMath for uint256;

    /**
     * @dev Only valid l2 token addresses will can be approved if the function is marked by this modifier.
     **/
    modifier onlyValidL2Address(uint256 l2Address) {
        require(Cairo.isValidL2Address(l2Address), "L2_ADDRESS_OUT_OF_RANGE");
        _;
    }

    /**
     * @dev Only bridge admin can call functions marked by this modifier.
     **/
    modifier onlyAdmin() {
        require(msg.sender == admin, "ONLY BRIDGE ADMIN");
        _;
    }

    event LogDeposit(
        address sender,
        address token,
        uint256 amount,
        uint256 l2Recipient,
        uint256 blockNumber,
        uint256 rewardsIndex
    );
    event LogWithdrawal(
        address token,
        uint256 l2sender,
        address recipient,
        uint256 amount
    );
    event LogBridgeReward(uint256 l2sender, address recipient, uint256 amount);
    event LogTokenAdded(address l1Token, uint256 l2Token);

    constructor() public {}

    function getRevision() internal pure virtual override returns (uint256) {
        return BRIDGE_REVISION;
    }

    /**
     * @notice Initializes the Bridge.
     * @dev Function is invoked by the proxy contract when the bridge contract is added, takes the following byte encoded input arguments:
     *  L2 bridge address
     *  Starknet messaging contract address
     *  Address of Aave IncentivesController
     *  admin of the bridge
     **/
    function initialize(bytes calldata data) external virtual initializer {
        (
            uint256 l2Bridge_,
            IStarknetMessaging messagingContract_,
            IAaveIncentivesController incentivesController_,
            address admin_
        ) = abi.decode(
                data,
                (
                    uint256,
                    IStarknetMessaging,
                    IAaveIncentivesController,
                    address
                )
            );

        require(Cairo.isValidL2Address(l2Bridge_), "L2_ADDRESS_OUT_OF_RANGE");
        require(
            address(incentivesController_) != address(0x0),
            "INVALID ADDRESS FOR INCENTIVE CONTROLLER"
        );

        messagingContract = messagingContract_;
        l2Bridge = l2Bridge_;
        incentivesController = incentivesController_;
        rewardToken = IERC20(incentivesController.REWARD_TOKEN());
        admin = admin_;
    }

    /**
     * @notice Approves a new L1<->L2 token bridge.
     * @dev Function is invoked only by bridge admin
     * @param l1AToken token address
     * @param l2Token token address
     **/
    function approveToken(address l1AToken, uint256 l2Token)
        external
        onlyAdmin
        onlyValidL2Address(l2Token)
    {
        require(l1AToken != address(0x0), "l1Token address cannot be 0x0");

        require(
            aTokenData[l1AToken].l2TokenAddress == 0,
            "l2Token already set"
        );

        require(
            IATokenWithPool(l1AToken).getIncentivesController() ==
                incentivesController,
            "L1 TOKEN CONFIGURED WITH DIFFERENT INCENTIVES CONTROLLER THAN BRIDGE'S"
        );

        IERC20 underlyingAsset = IERC20(
            IATokenWithPool(l1AToken).UNDERLYING_ASSET_ADDRESS()
        );
        ILendingPool lendingPool = IATokenWithPool(l1AToken).POOL();
        underlyingAsset.safeApprove(address(lendingPool), type(uint256).max);

        aTokenData[l1AToken] = ATokenData(
            l2Token,
            underlyingAsset,
            lendingPool
        );
        approvedL1Tokens.push(l1AToken);
        emit LogTokenAdded(l1AToken, l2Token);
    }

    /**
     * @notice allows deposits of aTokens or their underlying assets on L2
     * @param l1AToken aToken address
     * @param l2Recipient recipient address
     * @param amount to be minted on l2
     * @param referralCode of asset
     * @param fromUnderlyingAsset if set to true will accept deposit from underlying assets
     **/
    function deposit(
        address l1AToken,
        uint256 l2Recipient,
        uint256 amount,
        uint16 referralCode,
        bool fromUnderlyingAsset
    ) external onlyValidL2Address(l2Recipient) returns (uint256) {
        IERC20 underlyingAsset = aTokenData[l1AToken].underlyingAsset;
        ILendingPool lendingPool = aTokenData[l1AToken].lendingPool;
        require(
            (underlyingAsset != IERC20(0x0)) &&
                (lendingPool != ILendingPool(0x0)),
            "This aToken has not been approved yet."
        );

        // deposit aToken or underlying asset

        if (fromUnderlyingAsset) {
            underlyingAsset.safeTransferFrom(msg.sender, address(this), amount);
            lendingPool.deposit(
                address(underlyingAsset),
                amount,
                address(this),
                referralCode
            );
        } else {
            IERC20(l1AToken).safeTransferFrom(
                msg.sender,
                address(this),
                amount
            );
        }

        // update L2 state and emit deposit event

        uint256 rewardsIndex = getCurrentRewardsIndex(l1AToken);

        uint256 staticAmount = _dynamicToStaticAmount(
            amount,
            address(underlyingAsset),
            lendingPool
        );

        sendDepositMessage(
            l1AToken,
            msg.sender,
            l2Recipient,
            staticAmount,
            block.number,
            rewardsIndex
        );

        return staticAmount;
    }

    /**
     * @notice allows withdraw of aTokens or their underlying assets from L2
     * @param l1AToken aToken address
     * @param l2sender sender address
     * @param recipient l1 recipient
     * @param staticAmount amount to be withdraw
     * @param toUnderlyingAsset if set to true will withdraw underlying asset tokens from pool and transfer them to recipient
     **/
    function withdraw(
        address l1AToken,
        uint256 l2sender,
        address recipient,
        uint256 staticAmount,
        uint256 l2RewardsIndex,
        bool toUnderlyingAsset
    ) external {
        // check that the function call is valid and emit withdraw event

        consumeMessage(
            l1AToken,
            l2sender,
            recipient,
            staticAmount,
            l2RewardsIndex
        );
        require(recipient != address(0x0), "INVALID_RECIPIENT");

        // withdraw tokens

        address underlyingAsset = address(aTokenData[l1AToken].underlyingAsset);
        ILendingPool lendingPool = aTokenData[l1AToken].lendingPool;
        uint256 amount = _staticToDynamicAmount(
            staticAmount,
            underlyingAsset,
            lendingPool
        );

        if (toUnderlyingAsset) {
            lendingPool.withdraw(underlyingAsset, amount, recipient);
        } else {
            IERC20(l1AToken).safeTransfer(recipient, amount);
        }

        // update L2 state

        uint256 l1CurrentRewardsIndex = getCurrentRewardsIndex(l1AToken);

        sendIndexUpdateMessage(
            l1AToken,
            msg.sender,
            block.number,
            l1CurrentRewardsIndex
        );

        // transfer rewards

        uint256 rewardsAmount = computeRewardsDiff(
            staticAmount,
            l2RewardsIndex,
            l1CurrentRewardsIndex
        );
        transferRewards(recipient, rewardsAmount);
    }

    /**
     * @notice allows bridge admin to manually update the rewards index of tokens on l2
     * @param l1AToken aToken address
     **/
    function updateL2State(address l1AToken) external onlyAdmin {
        uint256 rewardsIndex = getCurrentRewardsIndex(l1AToken);

        sendIndexUpdateMessage(
            l1AToken,
            msg.sender,
            block.number,
            rewardsIndex
        );
    }

    function sendDepositMessage(
        address l1Token,
        address from,
        uint256 l2Recipient,
        uint256 amount,
        uint256 blockNumber,
        uint256 currentRewardsIndex
    ) internal {
        uint256[] memory payload = new uint256[](9);
        payload[0] = uint256(from);
        payload[1] = l2Recipient;
        payload[2] = aTokenData[l1Token].l2TokenAddress;
        (payload[3], payload[4]) = Cairo.toSplitUint(amount);
        (payload[5], payload[6]) = Cairo.toSplitUint(blockNumber);
        (payload[7], payload[8]) = Cairo.toSplitUint(currentRewardsIndex);

        messagingContract.sendMessageToL2(l2Bridge, DEPOSIT_HANDLER, payload);

        emit LogDeposit(
            from,
            l1Token,
            amount,
            l2Recipient,
            blockNumber,
            currentRewardsIndex
        );
    }

    function sendIndexUpdateMessage(
        address l1Token,
        address from,
        uint256 blockNumber,
        uint256 currentRewardsIndex
    ) internal {
        uint256[] memory payload = new uint256[](6);
        payload[0] = uint256(from);
        payload[1] = aTokenData[l1Token].l2TokenAddress;
        (payload[2], payload[3]) = Cairo.toSplitUint(blockNumber);
        (payload[4], payload[5]) = Cairo.toSplitUint(currentRewardsIndex);

        messagingContract.sendMessageToL2(
            l2Bridge,
            INDEX_UPDATE_HANDLER,
            payload
        );
    }

    function consumeMessage(
        address l1Token,
        uint256 l2sender,
        address recipient,
        uint256 amount,
        uint256 l2RewardsIndex
    ) internal {
        emit LogWithdrawal(l1Token, l2sender, recipient, amount);

        uint256[] memory payload = new uint256[](8);
        payload[0] = TRANSFER_FROM_STARKNET;
        payload[1] = uint256(address(l1Token));
        payload[2] = l2sender;
        payload[3] = uint256(recipient);
        (payload[4], payload[5]) = Cairo.toSplitUint(amount);
        (payload[6], payload[7]) = Cairo.toSplitUint(l2RewardsIndex);

        // Consume the message from the StarkNet core contract.
        // This will revert the (Ethereum) transaction if the message does not exist.
        messagingContract.consumeMessageFromL2(l2Bridge, payload);
    }

    function _dynamicToStaticAmount(
        uint256 amount,
        address asset,
        ILendingPool lendingPool
    ) internal view returns (uint256) {
        return amount.rayDiv(lendingPool.getReserveNormalizedIncome(asset));
    }

    function _staticToDynamicAmount(
        uint256 amount,
        address asset,
        ILendingPool lendingPool
    ) internal view returns (uint256) {
        return amount.rayMul(lendingPool.getReserveNormalizedIncome(asset));
    }

    /**
     * @notice gets the latest rewards index of the given aToken on L1.
     **/

    function getCurrentRewardsIndex(address l1AToken)
        internal
        view
        returns (uint256)
    {
        (
            uint256 index,
            uint256 emissionPerSecond,
            uint256 lastUpdateTimestamp
        ) = incentivesController.getAssetData(l1AToken);
        uint256 distributionEnd = incentivesController.DISTRIBUTION_END();
        uint256 totalSupply = IScaledBalanceToken(l1AToken).scaledTotalSupply();

        if (
            emissionPerSecond == 0 ||
            totalSupply == 0 ||
            lastUpdateTimestamp == block.timestamp ||
            lastUpdateTimestamp >= distributionEnd
        ) {
            return index;
        }

        uint256 currentTimestamp = block.timestamp > distributionEnd
            ? distributionEnd
            : block.timestamp;
        uint256 timeDelta = currentTimestamp.sub(lastUpdateTimestamp);
        return
            emissionPerSecond
                .mul(timeDelta)
                .mul(10**uint256(18))
                .div(totalSupply)
                .add(index); // 18- precision, should be loaded
    }

    function computeRewardsDiff(
        uint256 amount,
        uint256 l2RewardsIndex,
        uint256 l1RewardsIndex
    ) internal pure returns (uint256) {
        uint256 rayAmount = amount.wadToRay();
        return
            (rayAmount.rayMulNoRounding(l1RewardsIndex.sub(l2RewardsIndex)))
                .rayToWad();
    }

    function consumeBridgeRewardMessage(
        uint256 l2sender,
        address recipient,
        uint256 amount
    ) internal {
        emit LogBridgeReward(l2sender, recipient, amount);

        uint256[] memory payload = new uint256[](5);
        payload[0] = BRIDGE_REWARD_MESSAGE;
        payload[1] = l2sender;
        payload[2] = uint256(recipient);
        (payload[3], payload[4]) = Cairo.toSplitUint(amount);

        messagingContract.consumeMessageFromL2(l2Bridge, payload);
    }

    /**
     * @notice called to transfer the bridged rewards tokens to the l1 recipient
     * @param l2sender sender on l2
     * @param recipient on l1
     * @param amount of tokens to be claimed to user on l1
     **/
    function receiveRewards(
        uint256 l2sender,
        address recipient,
        uint256 amount
    ) external {
        consumeBridgeRewardMessage(l2sender, recipient, amount);
        require(recipient != address(0x0), "INVALID_RECIPIENT");
        transferRewards(recipient, amount);
    }

    /**
     * @notice claims pending rewards of the l1 bridge by calling the aave Incentives Controller and transfers them back to the l1 recipient
     * @param recipient of rewards tokens
     * @param rewardsAmount to be transferred to recipient
     **/
    function transferRewards(address recipient, uint256 rewardsAmount)
        internal
    {
        address self = address(this);

        uint256 rewardBalance = rewardToken.balanceOf(self);

        if (rewardBalance < rewardsAmount) {
            rewardBalance += incentivesController.claimRewards(
                approvedL1Tokens,
                rewardsAmount - rewardBalance,
                self
            );
        }

        if (rewardBalance >= rewardsAmount) {
            rewardToken.transfer(recipient, rewardsAmount);
            return;
        }
        revert("NOT ENOUGH REWARDS");
    }
}
