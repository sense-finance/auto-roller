// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.11;

import { Vm } from "forge-std/Vm.sol";
import { stdCheats } from "forge-std/stdlib.sol";
import { console } from "forge-std/console.sol";

import { ERC20 } from "solmate/tokens/ERC20.sol";
import { MockERC20 } from "solmate/test/utils/mocks/MockERC20.sol";
import { DSTestPlus } from "solmate/test/utils/DSTestPlus.sol";
import { FixedPointMathLib } from "solmate/utils/FixedPointMathLib.sol";
import { SafeTransferLib } from "solmate/utils/SafeTransferLib.sol";

import { Divider, TokenHandler } from "sense-v1-core/Divider.sol";
import { Periphery } from "sense-v1-core/Periphery.sol";
import { BaseAdapter } from "sense-v1-core/adapters/BaseAdapter.sol";
import { Errors } from "sense-v1-utils/libs/Errors.sol";

import { AddressBook } from "./utils/AddressBook.sol";
import { Space } from "../interfaces/Space.sol";
import { AutoRoller, SpaceFactoryLike, OwnableAdapter } from "../AutoRoller.sol";

interface Opener {
    function onSponsorWindowOpened() external;
}

contract MockAdapter is OwnableAdapter {
    using SafeTransferLib for ERC20;
    uint256 public override scale = 1.1e18;
    uint256 internal open = 1;
    address public immutable owner;
    
    error OnlyOwner();

    constructor(
        address _owner,
        address _divider,
        address _target,
        address _underlying,
        uint128 _ifee,
        AdapterParams memory _adapterParams
    )
        BaseAdapter(_divider, _target, _underlying, _ifee, _adapterParams)
    {
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
        // Open to any maturity
        return open == 2 ? (0, type(uint64).max / 2) : (0, 0);
    }
}

contract AutoRollerTest is DSTestPlus, stdCheats {
    using FixedPointMathLib for uint256;

    Vm internal constant vm = Vm(HEVM_ADDRESS);

    /// Sat Apr 30 2022 20:00:00 GMT-0400 (GMT-04:00)
    /// @dev This maturity will only work if the fork block number is set to a block before this date
    uint256 internal constant MATURITY = 1651363200;

    address alice = address(0x1337);
    address bob = address(0x133701);

    MockERC20 target;
    MockERC20 underlying;
    MockAdapter mockAdapter;

    Divider divider;
    ERC20 pt;
    ERC20 yt;

    AutoRoller autoRoller;

    function setUp() public {
        target     = new MockERC20("TestTarget", "TT0", 18);
        underlying = new MockERC20("TestUnderlying", "TU0", 18);

        (address vault, SpaceFactoryLike spaceFactory) = (
            AddressBook.BALANCER_VAULT,
            SpaceFactoryLike(AddressBook.SPACE_FACTORY_1_2_0)
        );
        Periphery periphery = Periphery(AddressBook.PERIPHERY_1_2_1);
        divider = Divider(spaceFactory.divider());

        // TokenHandler tokenHandler = new TokenHandler();
        // Divider dividerOverride = new Divider(address(this), address(tokenHandler));
        // dividerOverride.setPeriphery(address(this));
        // tokenHandler.init(address(dividerOverride));

        // vm.etch(address(divider), address(dividerOverride).code);

        vm.label(address(spaceFactory), "SpaceFactory");
        vm.label(address(divider), "Divider");
        vm.label(address(periphery), "Periphery");
        vm.label(vault, "BalancerVault");
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");

        autoRoller = new AutoRoller(target, address(spaceFactory), address(periphery), "Auto Roller", "AR");

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
            address(autoRoller),
            address(divider),
            address(target),
            address(underlying),
            0, // no issuance fees
            mockAdapterParams
        );

        target.mint(address(this), 2e18);

        // Start multisig (admin) prank calls   
        vm.startPrank(AddressBook.SENSE_MULTISIG);
        periphery.onboardAdapter(address(mockAdapter), true);
        divider.setGuard(address(mockAdapter), type(uint256).max);
        vm.stopPrank();
        // Stop pranking calls

        // (address _pt, address _yt) = periphery.sponsorSeries(address(mockAdapter), MATURITY, true);
        // pt = ERC20(_pt);
        // yt = ERC20(_yt);

        // vm.label(_pt, pt.name());
        // vm.label(_yt, yt.name());
        // vm.label(spaceFactory.pools(address(mockAdapter), MATURITY), "SpacePool");
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

    // Auto Roller auth ----
    event SpaceFactoryChanged(address oldSpaceFactory, address newSpaceFactory);
    function testUpdateSpaceFactory() public {
        address oldSpaceFactory = address(autoRoller.spaceFactory());

        hevm.record();
        address NEW_SPACE_FACTORY = address(0xbabe);

        // Expect the new Space Factory to be set, and for a "change" event to be emitted
        hevm.expectEmit(false, false, false, true);
        emit SpaceFactoryChanged(oldSpaceFactory, NEW_SPACE_FACTORY);

        // 1. Update the Space Factory address
        autoRoller.setSpaceFactory(NEW_SPACE_FACTORY);
        (, bytes32[] memory writes) = hevm.accesses(address(autoRoller));
        // Check that the storage slot was updated correctly
        assertEq(address(autoRoller.spaceFactory()), NEW_SPACE_FACTORY);
        // Check that only one storage slot was written to
        assertEq(writes.length, 1);
    }
    function testFuzzUpdateSpaceFactory(address lad) public {
        hevm.record();
        hevm.assume(lad != address(this)); // For any address other than the testing contract
        address NEW_SPACE_FACTORY = address(0xbabe);
        // 1. Impersonate the fuzzed address and try to update the Space Factory address
        hevm.prank(lad);
        hevm.expectRevert("UNTRUSTED");
        autoRoller.setSpaceFactory(NEW_SPACE_FACTORY);
        (, bytes32[] memory writes) = hevm.accesses(address(autoRoller));
        // Check that only no storage slots were written to
        assertEq(writes.length, 0);
    }

    function testRoll() public {
        // 1. Mint some tokens to Alice
        autoRoller.init(mockAdapter);
        autoRoller.roll();
        // revert();
    }

    function testDeploy() public {
        emit log_address(address(autoRoller));
    }
}