pragma solidity 0.8.10;
pragma experimental ABIEncoderV2;

import {IERC20_Extended} from "./IERC20_Extended.sol";
import {IBridge} from "../../contracts/l1/interfaces/IBridge.sol";
import "./IBridge_L2.sol";

contract BridgeL2Harness is IBridge_L2 {
    mapping(address => address) public AtokenToStaticAToken_L2;
    IBridge public BRIDGE_L1;
    uint256 public l2RewardsIndex;
    bool public toUnderlyingAsset;
    IERC20_Extended public REW_AAVE;

    /**
     * @dev Sets the `l2RewardsIndex`
     * @param value the value to be assigned to `l2RewardsIndex`
     **/
    function l2RewardsIndexSetter(uint256 value) public {
        require(msg.sender == address(BRIDGE_L1));
        l2RewardsIndex = value;
    }


    /**
     * @dev retrieves the address of the StaticAToken on L2
     * @param AToken address of AToken on L1
     **/
    function getStaticATokenAddress(address AToken)
    public view returns(address) {
        return AtokenToStaticAToken_L2[AToken];
    }

    /**
     * @dev deposit on L2
     * @param asset The Atoken sent by the L1 bridge, to which staticAtoken shall be minted and connected
     * @param amount The amount of Atokens sent by the bridge
     * @param onBehalfOf The recipient of the minted staticAtokens
     **/
    function deposit(
        address asset,
        uint256 amount,
        address onBehalfOf
    ) external {
        IERC20_Extended(AtokenToStaticAToken_L2[asset]).mint(
            onBehalfOf,
            amount
        );
    }

    /**
     * @dev Initiates a withdraw from the L2 side and gets all the way to the L1 side to withdraw Atokens/underlying for the users.
     * @param asset The L1 Atoken that is desired to be withdrawn
     * @param amount The amount of StaticAtokens desired to be withdrawn
     * @param caller Represents the caller on L2.
     * @param to The recipient of the minted staticAtokens on the L1 side
     * @return The amount that is being withdrawn
     **/
    function initiateWithdraw(
        address asset,
        uint256 amount,
        address caller,
        address to
    ) external returns (uint256) {
        IERC20_Extended(AtokenToStaticAToken_L2[asset]).burn(
            caller,
            amount
        );

        BRIDGE_L1.withdraw(
            asset,
            uint256(uint160(caller)),
            to,
            amount,
            l2RewardsIndex,
            toUnderlyingAsset
        );
        return amount;
    }

    function getRewTokenAddress() external view returns(address) {
        return address(REW_AAVE);
    }

    /**
     * @dev Burns the reward tokens on the L2 side and initiate a withdraw of reward tokens on the L1 side
     * @param recipient The L1 user address that withdraws the reward
     * @param amount The amount of reward token desired to be withdrawn
     **/
    function bridgeRewards(address recipient, address caller, uint256 amount) external {
        IERC20_Extended(REW_AAVE).transfer(address(BRIDGE_L1), amount);
        BRIDGE_L1.receiveRewards(
            uint256(uint160(caller)),
            recipient,
            amount
        );
    }

    function mintRewards(address recipient, uint256 amount) external {
        require (msg.sender == address(BRIDGE_L1), "only Bridge can mint");
        IERC20_Extended(REW_AAVE).mint(recipient, amount);
    }
}
