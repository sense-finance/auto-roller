// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.11;

import { Vm } from "forge-std/Vm.sol";
import { stdCheats } from "forge-std/stdlib.sol";
import { console } from "forge-std/console.sol";

import { ERC20 } from "solmate/tokens/ERC20.sol";
import { MockERC20 } from "solmate/test/utils/mocks/MockERC20.sol";
import { DSTestPlus } from "solmate/test/utils/DSTestPlus.sol";
import { FixedPointMathLib } from "solmate/utils/FixedPointMathLib.sol";
import { SafeCastLib } from "solmate/utils/SafeCastLib.sol";
import { CREATE3 } from "solmate/utils/CREATE3.sol";

import { Divider, TokenHandler } from "sense-v1-core/Divider.sol";
import { Periphery } from "sense-v1-core/Periphery.sol";
import { BaseAdapter } from "sense-v1-core/adapters/BaseAdapter.sol";
import { Errors } from "sense-v1-utils/libs/Errors.sol";

import { Space } from "../interfaces/Space.sol";
import { BalancerVault } from "../interfaces/BalancerVault.sol";

import { AddressBook } from "./utils/AddressBook.sol";
import { AutoRoller, SpaceFactoryLike, OwnableAdapter } from "../AutoRoller.sol";

interface Opener {
    function onSponsorWindowOpened() external;
}

contract MockAdapter is OwnableAdapter {
    uint256 public override scale = 1.1e18;
    uint256 internal open = 1;
    address public immutable owner;
    
    error OnlyOwner();

    constructor(
        address _owner,
        address _divider,
        address _target,
        address _underlying,
        AdapterParams memory _adapterParams
    ) BaseAdapter(_divider, _target, _underlying, 0 /* no issuance fee */, _adapterParams) {
        owner = _owner;
    }

    function scaleStored() external view virtual override returns (uint256 _scale) {
        _scale = scale;
    }

    function wrapUnderlying(uint256 uBal) external virtual override returns (uint256 amountOut) {
        MockERC20 target = MockERC20(target);
        MockERC20 underlying = MockERC20(underlying);

        uint256 tDecimals = target.decimals();
        uint256 uDecimals = underlying.decimals();

        underlying.transferFrom(msg.sender, address(this), uBal);
        amountOut = uDecimals < tDecimals ? 
            uBal * 1e18 / scale * (tDecimals - uDecimals) ** 10 :
            uBal * 1e18 / scale / (uDecimals - tDecimals) ** 10;

        target.mint(msg.sender, amountOut);
    }

    function unwrapTarget(uint256 tBal) external virtual override returns (uint256 amountOut) {
        MockERC20 target = MockERC20(target);
        MockERC20 underlying = MockERC20(underlying);

        uint256 tDecimals = target.decimals();
        uint256 uDecimals = underlying.decimals();

        target.transferFrom(msg.sender, address(this), tBal);
        amountOut = uDecimals < tDecimals ? 
            tBal * scale / 1e18 / (tDecimals - uDecimals) ** 10 :
            tBal * scale / 1e18 * (uDecimals - tDecimals) ** 10;
            
        underlying.mint(msg.sender, amountOut);
    }

    function getUnderlyingPrice() external view virtual override returns (uint256) {
        return 1e18;
    }

    function setScale(uint256 _scale) external {
        scale = _scale;
    }

    function openSponsorWindow() external override {
        if(msg.sender != owner) revert OnlyOwner();
        open = 2;
        Opener(msg.sender).onSponsorWindowOpened();
        open = 1;
    }

    function getMaturityBounds() external view override returns (uint256, uint256) {
        return open == 2 ? (0, type(uint64).max / 2) : (0, 0);
    }
}

contract AutoRollerTest is DSTestPlus, stdCheats {
    using FixedPointMathLib for uint256;
    using FixedPointMathLib for int128;

    Vm internal constant vm = Vm(HEVM_ADDRESS);

    address alice = address(0x1337);
    address bob = address(0x133701);

    MockERC20 target;
    MockERC20 underlying;
    MockAdapter mockAdapter;

    SpaceFactoryLike spaceFactory;
    BalancerVault balancerVault;
    Divider divider;
    ERC20 pt;
    ERC20 yt;

    AutoRoller autoRoller;

    function setUp() public {
        target     = new MockERC20("TestTarget", "TT0", 18);
        underlying = new MockERC20("TestUnderlying", "TU0", 18);

        (balancerVault, spaceFactory) = (
            BalancerVault(AddressBook.BALANCER_VAULT),
            SpaceFactoryLike(AddressBook.SPACE_FACTORY_1_3_0)
        );
        Periphery periphery = Periphery(AddressBook.PERIPHERY_1_3_0);
        divider = Divider(spaceFactory.divider());

        // TokenHandler tokenHandler = new TokenHandler();
        // Divider dividerOverride = new Divider(address(this), address(tokenHandler));
        // dividerOverride.setPeriphery(address(this));
        // tokenHandler.init(address(dividerOverride));
        // vm.etch(address(divider), address(dividerOverride).code);

        vm.label(address(spaceFactory), "SpaceFactory");
        vm.label(address(divider), "Divider");
        vm.label(address(periphery), "Periphery");
        vm.label(address(balancerVault), "BalancerVault");
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");

        bytes32 autoRollerSalt = keccak256(bytes("AUTO ROLLER"));
        address previewedAutoRoller = CREATE3.getDeployed(autoRollerSalt);

        BaseAdapter.AdapterParams memory mockAdapterParams = BaseAdapter.AdapterParams({
            oracle: address(0),
            stake: address(new MockERC20("Stake", "ST", 18)), // stake size is 0, so the we don't actually need any stake token
            stakeSize: 0,
            minm: 0, // 0 minm, so there's not lower bound on future maturity
            maxm: type(uint64).max, // large maxm, so there's not upper bound on future maturity
            mode: 0, // monthly maturities
            tilt: 0, // no principal reserved for YTs
            level: 31 // default level, everything is allowed except for the redemption cb
        });

        mockAdapter = new MockAdapter(
            previewedAutoRoller,
            address(divider),
            address(target),
            address(underlying),
            mockAdapterParams
        );

        autoRoller = AutoRoller(
            CREATE3.deploy(
                autoRollerSalt,
                abi.encodePacked(type(AutoRoller).creationCode, abi.encode(
                    target, divider, periphery, spaceFactory, balancerVault, mockAdapter
                )), 
                0
            )
        );

        // Start multisig (admin) prank calls   
        vm.startPrank(AddressBook.SENSE_MULTISIG);
        periphery.onboardAdapter(address(mockAdapter), true);
        divider.setGuard(address(mockAdapter), type(uint256).max);
        vm.stopPrank();

        target.mint(address(this), 2e18);
        target.approve(address(autoRoller), 2e18);
    }


    // Sanity checks ----
    // function testFuzzDividerRestrictedIssuance(address lad) public {
    //     vm.assume(lad != address(mockAdapter));
    //     target.mint(lad, 1e18);

    //     vm.startPrank(lad);
    //     target.approve(address(divider), 1e18);

    //     vm.expectRevert(Errors.IssuanceRestricted.selector);
    //     divider.issue(address(mockAdapter), MATURITY, 1e18);
    // }
    // function testFuzzAdapterIssuerAuth(address lad) public {
    //     vm.assume(lad != address(mockAdapter) && lad != address(autoRoller));
    //     target.mint(lad, 1e18);

    //     vm.startPrank(lad);
    //     target.approve(address(mockAdapter), 1e18);

    //     vm.expectRevert(MockAdapter.OnlyIssuer.selector);
    //     mockAdapter.issue(MATURITY, 1e18);
    // }
    // function testAdapterIssue() public {
    //     target.mint(address(autoRoller), 1e18);

    //     vm.startPrank(address(autoRoller));
    //     target.approve(address(mockAdapter), 1e18);
    //     uint256 ytPTBalances = mockAdapter.issue(MATURITY, 1e18);
    //     uint256 expectedytPTOut = (uint256(1e18) - mockAdapter.ifee()).mulWadDown(mockAdapter.scale());
    //     assertEq(ytPTBalances, expectedytPTOut);
    // }

    // TODO: admin function tests all together
    // Auto Roller auth ----
    // event SpaceFactoryChanged(address oldSpaceFactory, address newSpaceFactory);
    // function testUpdateSpaceFactory() public {
    //     address oldSpaceFactory = address(autoRoller.spaceFactory());

    //     hevm.record();
    //     address NEW_SPACE_FACTORY = address(0xbabe);

    //     // Expect the new Space Factory to be set, and for a "change" event to be emitted
    //     hevm.expectEmit(false, false, false, true);
    //     emit SpaceFactoryChanged(oldSpaceFactory, NEW_SPACE_FACTORY);

    //     // 1. Update the Space Factory address
    //     autoRoller.setSpaceFactory(NEW_SPACE_FACTORY);
    //     (, bytes32[] memory writes) = hevm.accesses(address(autoRoller));
    //     // Check that the storage slot was updated correctly
    //     assertEq(address(autoRoller.spaceFactory()), NEW_SPACE_FACTORY);
    //     // Check that only one storage slot was written to
    //     assertEq(writes.length, 1);
    // }
    // function testFuzzUpdateSpaceFactory(address lad) public {
    //     hevm.record();
    //     hevm.assume(lad != address(this)); // For any address other than the testing contract
    //     address NEW_SPACE_FACTORY = address(0xbabe);
    //     // 1. Impersonate the fuzzed address and try to update the Space Factory address
    //     hevm.prank(lad);
    //     hevm.expectRevert("UNTRUSTED");
    //     autoRoller.setSpaceFactory(NEW_SPACE_FACTORY);
    //     (, bytes32[] memory writes) = hevm.accesses(address(autoRoller));
    //     // Check that only no storage slots were written to
    //     assertEq(writes.length, 0);
    // }

    function testDepositWithdraw() public {
        // 1. Deposit during the initial cooldown phase.
        autoRoller.deposit(0.2e18, address(this));
        assertEq(autoRoller.balanceOf(address(this)), 0.2e18);

        // 2. Deposit again, this time minting the Vault shares to alice.
        autoRoller.deposit(0.2e18, alice);
        assertEq(autoRoller.balanceOf(alice), 0.2e18);

        vm.prank(alice);
        autoRoller.withdraw(0.2e18, alice, alice);
        assertEq(autoRoller.balanceOf(alice), 0);
        assertEq(target.balanceOf(alice), 0.2e18);

        // 3. Roll the Target into the first Series.
        autoRoller.roll();

        // 4. Deposit during the first active phase.
        autoRoller.deposit(0.3e18, address(this));
        assertRelApproxEq(autoRoller.balanceOf(address(this)), 0.5e18, 0.000001e18 /* 0.01% */);

        autoRoller.withdraw(0.2e18, address(this), address(this));
        assertTrue(false);
    }

    // test eject

    function testRoll() public {
        autoRoller.deposit(2e18, address(this));

        autoRoller.roll();

        // Sanity checks
        assertEq(address(autoRoller.space()), address(spaceFactory.pools(address(mockAdapter), autoRoller.maturity())));
        assertLt(autoRoller.maturity(), autoRoller.MATURITY_NOT_SET());
        emit log_uint(block.timestamp);
        emit log_uint(block.number);

        Space space = autoRoller.space();


        (, uint256[] memory balances, ) = balancerVault.getPoolTokens(space.getPoolId());

        // todo: check duration.


        emit log_uint(balances[space.pti()]);
        emit log_uint(balances[1 - space.pti()]);

        // Space space = autoRoller.space();
        // uint256 pti = space.pti();
        // uint256 initScale = mockAdapter.scale();


        // Combine 

        // uint256 ONE = 1e18;

        // uint256 impliedRateRaw = 0.12e18;
        // emit log_named_uint("ts", space.ts());

        // emit log_named_uint("supply pt", ONE.divWadDown(space.ts().mulWadDown(31536000 * 1e18)));
        // uint256 impliedRate = powDown(impliedRateRaw + ONE, ONE.divWadDown(space.ts().mulWadDown(31536000 * 1e18))) - ONE;

        // // (balances[pti] + space.totalSupply()) .divWadDown(balances[1 - pti].mulWadDown(initScale)) - ONE;

        // emit log_named_uint("implied rate", impliedRate);

        // int128 num = int128(int256(impliedRate) + 1e18);
        // int128 denom = int128(int256(uint256(1e18).divWadDown(12e18)));
        // emit log_named_uint("num", uint256(int256(num)));
        // emit log_named_uint("exp", uint256(int256(denom)));
        // emit log_named_uint("exp", uint256(int256(num.powWad(denom) - 1e18)));

        // // uint256 ttm = maturity > block.timestamp ? uint256(maturity - block.timestamp) * FixedPoint.ONE : 0;

        // // Time shifted partial `t` from the yieldspace paper (`ttm` adjusted by some factor `ts`)
        // // uint256 t = ts.mulDown(ttm);

        // // Full `t` with fees baked in
        // // uint256 a = (pTIn ? g2 : g1).mulUp(t).complement();


        // uint256 ttm = space.maturity() > block.timestamp ? uint256(space.maturity() - block.timestamp) * 1e18 : 0;
        // uint256 a = 1e18 - space.ts().mulWadDown(ttm);

        // uint256 k = powDown(1.1e18, a) + powDown(1.1e18, a);

        // uint256 equilibriumPTReservesPartial = powDown(k.divWadDown(
        //     ONE.divWadDown(powDown(ONE + impliedRate, a)) + ONE
        // ), ONE.divWadDown(a));

        // uint256 equilibriumTargetReserves = equilibriumPTReservesPartial
        //     .divWadDown(initScale.mulWadDown(ONE + impliedRate));

        // emit log_named_uint("a", a);
        // // emit log_named_uint("impliedRate", uint256(space.maturity() - block.timestamp));

        // emit log_named_uint("equilibriumPTReservesPartial", equilibriumPTReservesPartial - space.totalSupply());
        // emit log_named_uint("equilibriumTargetReserves", equilibriumTargetReserves);

        // fairBptPriceInTarget = equilibriumTargetReserves
        //     // Complete the equilibrium PT reserve calc
        //     .add(equilibriumPTReservesPartial.sub(totalSupply())
        //     .mulDown(pTPriceInTarget)).divDown(totalSupply());

        // {
        //     int128 tr = int128(int128(int256(balances[1 - pti].mulWadDown(initScale))).powWad(int128(int256(a))));
        //     int128 pr = int128(int128(int256(balances[pti] + space.totalSupply())).powWad(int128(int256(a))));
        //     uint256 ad = uint256(int256(tr + pr));
        //     int128 ba = int128(int256(ad.divWadDown(uint256(1e18)
        //         .divWadDown(uint256(int256((1e18 + int128(int256(impliedRate))).powWad(int128(int256(a)))))) + 1e18)
        //     ));
        //     uint256 fair = uint256(int256(
        //         ba.powWad(int128(int256(uint256(1e18).divWadDown(a))))))
        //             .divWadDown(1e18 + impliedRate);

        //     emit log_named_uint("fair", fair);
        // }




        //  (1 / ( (1 + sir) ^ a) + 1) ) ^ (1 / a) / (1+sir)

        // emit log_named_uint("price", space.getPriceFromImpliedRate(impliedRate));

    }

    // fuzz very little left after rolling
    // max sell is actually sellable
    // max withdraw

    function _powWad(uint256 x, uint256 y) internal pure returns (uint256) {
        require(x < 1 << 255);
        require(y < 1 << 255);

        return uint256(FixedPointMathLib.powWad(int256(x), int256(y))); // Assumption: x cannot be negative so this result will never be.
    }
}