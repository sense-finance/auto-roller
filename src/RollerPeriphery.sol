// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.11;

import { ERC20 } from "solmate/tokens/ERC20.sol";
import { ERC4626 } from "solmate/mixins/ERC4626.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";

// Inspired by https://github.com/fei-protocol/ERC4626/blob/main/src/ERC4626Router.sol
contract RollerPeriphery {
    using SafeTransferLib for ERC20;

    /// @notice thrown when amount of assets received is below the min set by caller
    error MinAssetError();

    /// @notice thrown when amount of shares received is below the min set by caller
    error MinSharesError();

    /// @notice thrown when amount of assets received is above the max set by caller
    error MaxAssetError();

    /// @notice thrown when amount of shares received is above the max set by caller
    error MaxSharesError();

    function redeem(ERC4626 vault, uint256 shares, address receiver, uint256 minAmountOut) external returns (uint256 assets) {
        if ((assets = vault.redeem(shares, receiver, msg.sender)) < minAmountOut) {
            revert MinAssetError();
        }
    }

    function withdraw(ERC4626 vault, uint256 assets, address receiver, uint256 maxSharesOut) external returns (uint256 shares) {
        if ((shares = vault.withdraw(assets, receiver, msg.sender)) > maxSharesOut) {
            revert MaxSharesError();
        }
    }

    function mint(ERC4626 vault, uint256 shares, address receiver, uint256 maxAmountIn) external returns (uint256 assets) {
        ERC20(vault.asset()).safeTransferFrom(msg.sender, address(this), vault.previewMint(shares));

        if ((assets = vault.mint(shares, receiver)) > maxAmountIn) {
            revert MaxAssetError();
        }
    }

    function depoist(ERC4626 vault, uint256 assets, address receiver, uint256 minSharesOut) external returns (uint256 shares) {
        ERC20(vault.asset()).safeTransferFrom(msg.sender, address(this), assets);

        if ((shares = vault.deposit(assets, receiver)) < minSharesOut) {
            revert MinSharesError();
        }
    }

    function approve(ERC20 token, address to, uint256 amount) public payable {
        token.safeApprove(to, amount);
    }
}