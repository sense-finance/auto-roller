// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.15;

import { ERC20 } from "solmate/tokens/ERC20.sol";
import { ERC4626 } from "solmate/mixins/ERC4626.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";

import { Trust } from "sense-v1-utils/Trust.sol";

import { AutoRoller } from "./AutoRoller.sol";

// Inspired by https://github.com/fei-protocol/ERC4626/blob/main/src/ERC4626Router.sol
contract RollerPeriphery is Trust {
    using SafeTransferLib for ERC20;

    /// @notice thrown when amount of assets received is below the min set by caller.
    error MinAssetError();

    /// @notice thrown when amount of shares received is below the min set by caller.
    error MinSharesError();

    /// @notice thrown when amount of assets received is above the max set by caller.
    error MaxAssetError();

    /// @notice thrown when amount of shares received is above the max set by caller.
    error MaxSharesError();

    /// @notice thrown when amount of assets or excess received is below the max set by caller.
    error MinAssetsOrExcessError();

    constructor() Trust(msg.sender) {}

    /// @notice Redeem vault shares with slippage protection 
    /// @param vault ERC4626 vault
    /// @param shares Number of shares to redeem
    /// @param receiver Destination address for the returned assets
    /// @param minAmountOut Minimum amount of assets returned
    /// @return assets Amount of asset redeemable by the given number of shares
    function redeem(ERC4626 vault, uint256 shares, address receiver, uint256 minAmountOut) external returns (uint256 assets) {
        if ((assets = vault.redeem(shares, receiver, msg.sender)) < minAmountOut) {
            revert MinAssetError();
        }
    }

    /// @notice Withdraw underlying asset from vault with slippage protection 
    /// @param vault ERC4626 vault
    /// @param assets Amount of asset requested for withdrawal
    /// @param receiver Destination address for the returned assets
    /// @param maxSharesOut Maximum amount of shares burned
    /// @return shares Number of shares to redeem
    function withdraw(ERC4626 vault, uint256 assets, address receiver, uint256 maxSharesOut) external returns (uint256 shares) {
        if ((shares = vault.withdraw(assets, receiver, msg.sender)) > maxSharesOut) {
            revert MaxSharesError();
        }
    }

    /// @notice Mint vault shares with slippage protection 
    /// @param vault ERC4626 vault
    /// @param shares Number of shares to mint
    /// @param receiver Destination address for the returned shares
    /// @param maxAmountIn Maximum amount of assets pulled from msg.sender
    /// @return assets Amount of asset pulled from msg.sender and used to mint vault shares
    function mint(ERC4626 vault, uint256 shares, address receiver, uint256 maxAmountIn) external returns (uint256 assets) {
        ERC20(vault.asset()).safeTransferFrom(msg.sender, address(this), vault.previewMint(shares));

        if ((assets = vault.mint(shares, receiver)) > maxAmountIn) {
            revert MaxAssetError();
        }
    }

    /// @notice Deposit underlying asset into vault with slippage protection 
    /// @param vault ERC4626 vault
    /// @param assets Amount of asset pulled from msg.sender and used to mint vault shares
    /// @param receiver Destination address for the returned shares
    /// @param minSharesOut Minimum amount of returned shares
    /// @return shares Number of shares minted by the vault and returned to msg.sender
    function deposit(ERC4626 vault, uint256 assets, address receiver, uint256 minSharesOut) external returns (uint256 shares) {
        ERC20(vault.asset()).safeTransferFrom(msg.sender, address(this), assets);

        if ((shares = vault.deposit(assets, receiver)) < minSharesOut) {
            revert MinSharesError();
        }
    }

    /// @notice Quick exit into the constituent assets with slippage protection
    /// @param vault ERC4626 vault.
    /// @param shares Number of shares to eject with.
    /// @param receiver Destination address for the constituent assets.
    /// @param minAssetsOut Minimum amount of assets returned
    /// @param minExcessOut Minimum excess PT/YT returned 
    /// @return assets Amount of asset redeemable by the given number of shares.
    /// @return excessBal Amount of excess PT or YT redeemable by the given number of shares.
    /// @return isExcessPTs Whether the excess token is a YT or PT.
    function eject(ERC4626 vault, uint256 shares, address receiver, uint256 minAssetsOut, uint256 minExcessOut)
        external returns (uint256 assets, uint256 excessBal, bool isExcessPTs)
    {
        (assets, excessBal, isExcessPTs) = AutoRoller(address(vault)).eject(shares, receiver, msg.sender);

        if (assets < minAssetsOut || excessBal < minExcessOut) {
            revert MinAssetsOrExcessError();
        }
    }

    function approve(ERC20 token, address to) public payable requiresTrust {
        token.safeApprove(to, type(uint256).max);
    }
}