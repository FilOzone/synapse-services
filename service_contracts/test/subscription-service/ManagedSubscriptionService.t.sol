// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {ManagedSubscriptionService} from "../../src/subscription-service/ManagedSubscriptionService.sol";
import {MyERC1967Proxy} from "@pdp/ERC1967Proxy.sol";
import {Payments, IArbiter} from "@fws-payments/Payments.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

// Mock implementation of the USDFC token
contract MockERC20 is IERC20, IERC20Metadata {
    string private _name = "USD Filecoin";
    string private _symbol = "USDFC";
    uint8 private _decimals = 6;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;

    constructor() {
        _mint(msg.sender, 1000000 * 10 ** _decimals); // Mint 1 million tokens to deployer
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        _transfer(sender, recipient, amount);

        uint256 currentAllowance = _allowances[sender][msg.sender];
        require(currentAllowance >= amount, "ERC20: transfer amount exceeds allowance");
        _approve(sender, msg.sender, currentAllowance - amount);

        return true;
    }

    function _transfer(address sender, address recipient, uint256 amount) internal {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");

        uint256 senderBalance = _balances[sender];
        require(senderBalance >= amount, "ERC20: transfer amount exceeds balance");
        _balances[sender] = senderBalance - amount;
        _balances[recipient] += amount;

        emit Transfer(sender, recipient, amount);
    }

    function _mint(address account, uint256 amount) internal {
        require(account != address(0), "ERC20: mint to the zero address");

        _totalSupply += amount;
        _balances[account] += amount;
        emit Transfer(address(0), account, amount);
    }

    function _approve(address owner, address spender, uint256 amount) internal {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }
}

contract ManagedSubscriptionServiceTest is Test {
    // Testing Constants
    bytes constant FAKE_SIGNATURE = abi.encodePacked(
        bytes32(0xc0ffee7890abcdef1234567890abcdef1234567890abcdef1234567890abcdef), // r
        bytes32(0x9999997890abcdef1234567890abcdef1234567890abcdef1234567890abcdef), // s
        uint8(27) // v
    );

    // Contracts
    ManagedSubscriptionService public managedService;
    Payments public payments;
    MockERC20 public mockUSDFC;
    address public mockUptimeVerifier;

    // Test accounts
    address public deployer;
    address public client;
    address public serviceProvider;
    
    // Additional test accounts for registry tests
    address public sp1;
    address public sp2;
    address public sp3;

    // Test parameters
    string public testServiceName = "Titan";
    string public testServiceDescription = "{\"description\":\"Titan CDN and Storage Service\",\"website\":\"https://www.titannet.io\",\"version\":\"1.0.0\",\"type\":\"storage\"}";
    uint256 public testMonthlyRate = 10; // 10 USDFC per month
    uint256 public serviceId;
    bytes public extraData;
    
    // Test URLs removed - no longer needed

    // Events to verify
    event FilecoinServiceCreated(string indexed serviceName);
    event ServiceProviderActivated(uint256 indexed serviceId, uint256 railId, address serviceProvider);
    event ServiceProviderDeactivated(uint256 indexed serviceId, uint256 railId);
    event ServiceProviderStatusChanged(address indexed serviceProvider, bool online, uint256 epoch);
    event ServiceProviderPaid(address indexed serviceProvider, uint256 amount, uint256 fromEpoch, uint256 toEpoch);
    event UsagePaymentSent(address indexed serviceProvider, uint256 amount, string reason);
    
    // Registry events to verify
    event ProviderRegistered(address indexed provider);
    event ProviderApproved(address indexed provider, uint256 indexed providerId);
    event ProviderRejected(address indexed provider);
    event ProviderRemoved(address indexed provider, uint256 indexed providerId);

    function setUp() public {
        // Setup test accounts
        deployer = address(this);
        client = address(0xf1);
        serviceProvider = address(0xf2);
        
        // Additional accounts for registry tests
        sp1 = address(0xf3);
        sp2 = address(0xf4);
        sp3 = address(0xf5);

        // Fund test accounts
        vm.deal(deployer, 100 ether);
        vm.deal(client, 100 ether);
        vm.deal(serviceProvider, 100 ether);
        vm.deal(sp1, 100 ether);
        vm.deal(sp2, 100 ether);
        vm.deal(sp3, 100 ether);

        // Deploy mock contracts
        mockUSDFC = new MockERC20();

        // Deploy actual Payments contract
        Payments paymentsImpl = new Payments();
        bytes memory paymentsInitData = abi.encodeWithSelector(Payments.initialize.selector);
        MyERC1967Proxy paymentsProxy = new MyERC1967Proxy(address(paymentsImpl), paymentsInitData);
        payments = Payments(address(paymentsProxy));
        
        // Create mock uptime verifier (for testing we'll use a simple address)
        mockUptimeVerifier = address(0x1234);

        // Transfer tokens to client for payment
        mockUSDFC.transfer(client, 10000 * 10 ** mockUSDFC.decimals());

        // Deploy ManagedSubscriptionService with proxy
        ManagedSubscriptionService managedServiceImpl = new ManagedSubscriptionService();
        
        bytes memory initializeData = abi.encodeWithSelector(
            ManagedSubscriptionService.initialize.selector,
            address(payments),
            address(mockUSDFC),
            mockUptimeVerifier,
            testServiceName,
            testServiceDescription,
            testMonthlyRate
        );

        // Expect the FilecoinServiceCreated event during initialization
        vm.expectEmit(true, false, false, false);
        emit FilecoinServiceCreated(testServiceName);
        
        MyERC1967Proxy managedServiceProxy = new MyERC1967Proxy(address(managedServiceImpl), initializeData);
        managedService = ManagedSubscriptionService(address(managedServiceProxy));
    }

    function makeSignaturePass(address signer) public {
        vm.mockCall(
            address(0x01), // ecrecover precompile address
            bytes(hex""),  // wildcard matching of all inputs requires precisely no bytes
            abi.encode(signer)
        );
    }

    function testInitialState() public view {
        assertEq(
            managedService.paymentsContractAddress(),
            address(payments),
            "Payments contract address should be set correctly"
        );
        assertEq(
            managedService.usdfcTokenAddress(),
            address(mockUSDFC),
            "USDFC token address should be set correctly"
        );
        assertEq(managedService.tokenDecimals(), mockUSDFC.decimals(), "Token decimals should be correct");

        assertEq(managedService.nextProviderId(), 1, "Next provider ID should be 1");
        
        // Check monthly service rate
        assertEq(managedService.monthlyServiceRate(), testMonthlyRate, "Monthly service rate should match configured value");
        
        // Check service configuration
        assertEq(managedService.getServiceName(), testServiceName, "Service name should be set correctly");
        assertEq(managedService.getServiceDescription(), testServiceDescription, "Service description should be set correctly");
        
        // Check description size limit constant
        assertEq(managedService.MAX_SERVICE_DESCRIPTION_SIZE(), 1024, "Service description size limit should be 1024 bytes");
    }

    function testFilecoinServiceCreatedEventEmitted() public {
        // This test verifies that the FilecoinServiceCreated event was emitted during deployment
        // The event is already tested in setUp() via vm.expectEmit, but this test documents the behavior
        
        // Deploy a new instance to verify the event again
        ManagedSubscriptionService newManagedServiceImpl = new ManagedSubscriptionService();
        
        string memory altServiceName = "TestService";
        string memory altDescription = "{\"type\":\"test\"}";
        uint256 altRate = 15;
        
        bytes memory newInitializeData = abi.encodeWithSelector(
            ManagedSubscriptionService.initialize.selector,
            address(payments),
            address(mockUSDFC),
            altServiceName,
            altDescription,
            altRate
        );

        // Expect the FilecoinServiceCreated event with configured service name
        vm.expectEmit(true, false, false, false);
        emit FilecoinServiceCreated(altServiceName);
        
        // Deploy new proxy - this should emit the event
        MyERC1967Proxy newManagedServiceProxy = new MyERC1967Proxy(address(newManagedServiceImpl), newInitializeData);
        ManagedSubscriptionService newManagedService = ManagedSubscriptionService(address(newManagedServiceProxy));
        
        // Verify the service is properly initialized with configured values
        assertEq(newManagedService.monthlyServiceRate(), altRate, "New service should have correct monthly rate");
        assertEq(newManagedService.getServiceName(), altServiceName, "Service name should match configured value");
        assertEq(newManagedService.getServiceDescription(), altDescription, "Service description should match configured value");
    }
    
    function testUpdateServiceDescription() public {
        string memory newDescription = "{\"description\":\"Updated service description\",\"version\":\"2.0.0\"}";
        
        // Only owner can update description
        managedService.updateServiceDescription(newDescription);
        
        assertEq(managedService.getServiceDescription(), newDescription, "Service description should be updated");
        
        // Test non-owner cannot update
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, client));
        managedService.updateServiceDescription("unauthorized update");
    }
    
    function testServiceDescriptionSizeLimit() public {
        // Create description that exceeds the limit
        string memory oversizedDescription = new string(1025); // 1025 bytes > 1024 limit
        
        vm.expectRevert("Service description too large");
        managedService.updateServiceDescription(oversizedDescription);
    }
    
    function testConfigurableServiceParameters() public {
        // Test that different services can be deployed with different configurations
        
        // Deploy a different service configuration
        ManagedSubscriptionService customServiceImpl = new ManagedSubscriptionService();
        string memory customName = "CustomCDN";
        string memory customDesc = "{\"description\":\"Custom CDN Service\",\"pricing\":\"premium\"}";
        uint256 customRate = 25; // 25 USDFC per month
        
        bytes memory customInitData = abi.encodeWithSelector(
            ManagedSubscriptionService.initialize.selector,
            address(payments),
            address(mockUSDFC),
            customName,
            customDesc,
            customRate
        );

        vm.expectEmit(true, false, false, false);
        emit FilecoinServiceCreated(customName);
        
        MyERC1967Proxy customProxy = new MyERC1967Proxy(address(customServiceImpl), customInitData);
        ManagedSubscriptionService customService = ManagedSubscriptionService(address(customProxy));
        
        // Verify all parameters were set correctly
        assertEq(customService.getServiceName(), customName, "Custom service name should be set");
        assertEq(customService.getServiceDescription(), customDesc, "Custom description should be set");
        assertEq(customService.monthlyServiceRate(), customRate, "Custom rate should be set");
    }
    
    function testInvalidInitializationParameters() public {
        ManagedSubscriptionService testServiceImpl = new ManagedSubscriptionService();
        
        // Test empty service name
        bytes memory invalidInitData1 = abi.encodeWithSelector(
            ManagedSubscriptionService.initialize.selector,
            address(payments),
            address(mockUSDFC),
            "", // empty name
            "valid description",
            10
        );
        
        vm.expectRevert("Service name cannot be empty");
        new MyERC1967Proxy(address(testServiceImpl), invalidInitData1);
        
        // Test oversized description during initialization
        string memory oversizedDesc = new string(1025);
        bytes memory invalidInitData2 = abi.encodeWithSelector(
            ManagedSubscriptionService.initialize.selector,
            address(payments),
            address(mockUSDFC),
            "ValidName",
            oversizedDesc,
            10
        );
        
        vm.expectRevert("Service description too large");
        new MyERC1967Proxy(address(testServiceImpl), invalidInitData2);
        
        // Test zero monthly rate
        bytes memory invalidInitData3 = abi.encodeWithSelector(
            ManagedSubscriptionService.initialize.selector,
            address(payments),
            address(mockUSDFC),
            "ValidName",
            "valid description",
            0 // zero rate
        );
        
        vm.expectRevert("Monthly rate must be greater than 0");
        new MyERC1967Proxy(address(testServiceImpl), invalidInitData3);
        
    }
    
    function testSendUsagePayment() public {
        // Setup: Create a service provider, approve them, and activate their service
        vm.prank(serviceProvider);
        managedService.registerServiceProvider();
        managedService.approveServiceProvider(serviceProvider);
        
        // Fund the service contract and deposit into payments contract
        uint256 fundAmount = 1000e6; // 1000 USDFC
        mockUSDFC.approve(address(managedService), fundAmount);
        managedService.depositFunds(fundAmount);
        
        // Activate service provider (creates the rail)
        managedService.activateServiceProvider(serviceProvider, "Test Service");
        
        uint256 paymentAmount = 50e6; // 50 USDFC
        string memory reason = "High usage period";
        
        // Check service provider's account balance in payments contract before
        (uint256 spFundsBefore,) = getAccountInfo(address(mockUSDFC), serviceProvider);
        uint256 availableFundsBefore = managedService.getAvailableUsagePaymentFunds(serviceProvider);
        
        // Expect the UsagePaymentSent event
        vm.expectEmit(true, false, false, true);
        emit UsagePaymentSent(serviceProvider, paymentAmount, reason);
        
        // Send usage payment
        managedService.sendUsagePayment(serviceProvider, paymentAmount, reason);
        
        // Check service provider's account balance in payments contract after
        (uint256 spFundsAfter,) = getAccountInfo(address(mockUSDFC), serviceProvider);
        uint256 availableFundsAfter = managedService.getAvailableUsagePaymentFunds(serviceProvider);
        
        // Verify results - SP should receive net amount (after platform fees)
        uint256 expectedNetAmount = paymentAmount - (paymentAmount * 10 / 10000); // 0.1% platform fee
        assertEq(spFundsAfter, spFundsBefore + expectedNetAmount, "SP should receive net amount after fees");
        assertEq(availableFundsAfter, availableFundsBefore, "Available lockup funds should be consumed");
    }
    
    function testSendUsagePaymentMultiple() public {
        // Setup: Create service providers and activate their services
        vm.prank(serviceProvider);
        managedService.registerServiceProvider();
        managedService.approveServiceProvider(serviceProvider);
        
        vm.prank(sp1);
        managedService.registerServiceProvider();
        managedService.approveServiceProvider(sp1);
        
        // Fund the service contract
        uint256 fundAmount = 1000e6;
        mockUSDFC.approve(address(managedService), fundAmount);
        managedService.depositFunds(fundAmount);
        
        // Activate service providers (creates the rails)
        managedService.activateServiceProvider(serviceProvider, "Test Service 1");
        managedService.activateServiceProvider(sp1, "Test Service 2");
        
        // Check balances before payments
        (uint256 sp1FundsBefore,) = getAccountInfo(address(mockUSDFC), serviceProvider);
        (uint256 sp2FundsBefore,) = getAccountInfo(address(mockUSDFC), sp1);
        
        // Send multiple payments
        managedService.sendUsagePayment(serviceProvider, 30e6, "High usage period");
        managedService.sendUsagePayment(sp1, 20e6, "Premium service");
        managedService.sendUsagePayment(serviceProvider, 10e6, "Additional usage");
        
        // Check balances after payments
        (uint256 sp1FundsAfter,) = getAccountInfo(address(mockUSDFC), serviceProvider);
        (uint256 sp2FundsAfter,) = getAccountInfo(address(mockUSDFC), sp1);
        
        // Calculate expected net amounts (after 0.1% platform fee)
        uint256 sp1ExpectedNet = (30e6 + 10e6) - ((30e6 + 10e6) * 10 / 10000);
        uint256 sp2ExpectedNet = 20e6 - (20e6 * 10 / 10000);
        
        // Verify results
        assertEq(sp1FundsAfter, sp1FundsBefore + sp1ExpectedNet, "SP1 should receive correct net amount");
        assertEq(sp2FundsAfter, sp2FundsBefore + sp2ExpectedNet, "SP2 should receive correct net amount");
    }
    
    function testSendUsagePaymentOnlyOwner() public {
        // Setup: Create, approve and activate service provider
        vm.prank(serviceProvider);
        managedService.registerServiceProvider();
        managedService.approveServiceProvider(serviceProvider);
        
        // Fund the contract
        mockUSDFC.approve(address(managedService), 100e6);
        managedService.depositFunds(100e6);
        
        // Activate service provider (creates the rail)
        managedService.activateServiceProvider(serviceProvider, "Test Service");
        
        // Try to send usage payment as non-owner
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, client));
        managedService.sendUsagePayment(serviceProvider, 10e6, "Unauthorized payment");
    }
    
    function testSendUsagePaymentValidation() public {
        // Setup: Create, approve and activate service provider
        vm.prank(serviceProvider);
        managedService.registerServiceProvider();
        managedService.approveServiceProvider(serviceProvider);
        
        // Fund the contract
        mockUSDFC.approve(address(managedService), 100e6);
        managedService.depositFunds(100e6);
        
        // Activate service provider (creates the rail)
        managedService.activateServiceProvider(serviceProvider, "Test Service");
        
        // Test zero amount
        vm.expectRevert("Amount must be greater than 0");
        managedService.sendUsagePayment(serviceProvider, 0, "Zero amount");
        
        // Test unapproved provider
        vm.expectRevert("Service provider not approved");
        managedService.sendUsagePayment(sp1, 10e6, "Unapproved provider");
        
        // Test provider with no active service
        vm.prank(sp1);
        managedService.registerServiceProvider();
        managedService.approveServiceProvider(sp1);
        vm.expectRevert("Service provider has no active service");
        managedService.sendUsagePayment(sp1, 10e6, "No active service");
        
        // Test empty reason
        vm.expectRevert("Reason cannot be empty");
        managedService.sendUsagePayment(serviceProvider, 10e6, "");
        
        // Test reason too long
        string memory longReason = new string(257); // Over 256 character limit
        vm.expectRevert("Reason too long");
        managedService.sendUsagePayment(serviceProvider, 10e6, longReason);
    }
    
    function testGetAvailableUsagePaymentFunds() public {
        // Test with no service
        uint256 availableFunds = managedService.getAvailableUsagePaymentFunds(serviceProvider);
        assertEq(availableFunds, 0, "Should return 0 for provider with no service");
        
        // Setup: Create, approve and activate service provider
        vm.prank(serviceProvider);
        managedService.registerServiceProvider();
        managedService.approveServiceProvider(serviceProvider);
        
        // Fund the contract and activate service
        uint256 fundAmount = 1000e6;
        mockUSDFC.approve(address(managedService), fundAmount);
        managedService.depositFunds(fundAmount);
        
        managedService.activateServiceProvider(serviceProvider, "Test Service");
        
        // Check available funds (should be 0 initially - no fixed lockup)
        availableFunds = managedService.getAvailableUsagePaymentFunds(serviceProvider);
        assertEq(availableFunds, 0, "Should return 0 initially (no fixed lockup)");
        
        // Send a usage payment (this will add lockup dynamically)
        uint256 paymentAmount = 50e6;
        managedService.sendUsagePayment(serviceProvider, paymentAmount, "Test payment");
        
        // Check available funds after payment (should be 0 as payment consumed the lockup)
        availableFunds = managedService.getAvailableUsagePaymentFunds(serviceProvider);
        assertEq(availableFunds, 0, "Should return 0 after payment consumed lockup");
        
        // Test with inactive service
        managedService.deactivateServiceProvider(1); // Assuming serviceId 1
        availableFunds = managedService.getAvailableUsagePaymentFunds(serviceProvider);
        assertEq(availableFunds, 0, "Should return 0 for inactive service");
    }
    
    function testGetServiceProviderStartTime() public {
        // Test with no service
        uint256 startTime = managedService.getServiceProviderStartTime(serviceProvider);
        assertEq(startTime, 0, "Start time should be 0 for provider with no service");
        
        // Create a service
        vm.prank(serviceProvider);
        managedService.registerServiceProvider();
        managedService.approveServiceProvider(serviceProvider);
        
        uint256 depositAmount = 1000e6;
        mockUSDFC.approve(address(managedService), depositAmount);
        managedService.depositFunds(depositAmount);
        
        uint256 creationBlock = block.number;
        managedService.activateServiceProvider(serviceProvider, "Test Service");
        
        // Check start time
        startTime = managedService.getServiceProviderStartTime(serviceProvider);
        assertEq(startTime, creationBlock, "Start time should match service creation block");
    }
    
    function testGetServiceProviderUptimeNewService() public {
        // Create a service
        vm.prank(serviceProvider);
        managedService.registerServiceProvider();
        managedService.approveServiceProvider(serviceProvider);
        
        uint256 depositAmount = 1000e6;
        mockUSDFC.approve(address(managedService), depositAmount);
        managedService.depositFunds(depositAmount);
        
        managedService.activateServiceProvider(serviceProvider, "Test Service");
        
        // Check uptime immediately after creation
        (uint256 uptimePercentage, uint256 totalServiceTime, uint256 totalOnlineEpochs) = 
            managedService.getServiceProviderUptime(serviceProvider);
            
        assertEq(uptimePercentage, 10000, "New service should have 100% uptime");
        assertEq(totalServiceTime, 0, "Total service time should be 0 at creation");
        assertEq(totalOnlineEpochs, 0, "Total online epochs should be 0 at creation");
    }
    
    function testServiceProviderUptimeAfterTimeProgression() public {
        // Create a service
        vm.prank(serviceProvider);
        managedService.registerServiceProvider();
        managedService.approveServiceProvider(serviceProvider);
        
        uint256 depositAmount = 1000e6;
        mockUSDFC.approve(address(managedService), depositAmount);
        managedService.depositFunds(depositAmount);
        
        managedService.activateServiceProvider(serviceProvider, "Test Service");
        
        // Advance time by 100 blocks while online
        vm.roll(block.number + 100);
        
        (uint256 uptimePercentage, uint256 totalServiceTime, uint256 totalOnlineEpochs) = 
            managedService.getServiceProviderUptime(serviceProvider);
            
        assertEq(uptimePercentage, 10000, "Should have 100% uptime while always online");
        assertEq(totalServiceTime, 100, "Total service time should be 100 epochs");
        assertEq(totalOnlineEpochs, 100, "Total online epochs should be 100");
    }
    
    function testServiceProviderUptimeWithOfflinePeriod() public {
        // Create a service
        vm.prank(serviceProvider);
        managedService.registerServiceProvider();
        managedService.approveServiceProvider(serviceProvider);
        
        uint256 depositAmount = 1000e6;
        mockUSDFC.approve(address(managedService), depositAmount);
        managedService.depositFunds(depositAmount);
        
        managedService.activateServiceProvider(serviceProvider, "Test Service");
        
        // Advance time by 50 blocks while online
        vm.roll(block.number + 50);
        
        // Set provider offline
        managedService.setServiceProviderOffline(serviceProvider);
        
        // Advance time by 50 more blocks while offline
        vm.roll(block.number + 50);
        
        (uint256 uptimePercentage, uint256 totalServiceTime, uint256 totalOnlineEpochs) = 
            managedService.getServiceProviderUptime(serviceProvider);
            
        assertEq(totalServiceTime, 100, "Total service time should be 100 epochs");
        assertEq(totalOnlineEpochs, 50, "Total online epochs should be 50");
        assertEq(uptimePercentage, 5000, "Should have 50% uptime (50/100 * 10000)");
    }
    
    function testServiceProviderUptimeBackOnline() public {
        // Create a service
        vm.prank(serviceProvider);
        managedService.registerServiceProvider();
        managedService.approveServiceProvider(serviceProvider);
        
        uint256 depositAmount = 1000e6;
        mockUSDFC.approve(address(managedService), depositAmount);
        managedService.depositFunds(depositAmount);
        
        managedService.activateServiceProvider(serviceProvider, "Test Service");
        
        // Advance time by 40 blocks while online
        vm.roll(block.number + 40);
        
        // Set provider offline
        managedService.setServiceProviderOffline(serviceProvider);
        
        // Advance time by 20 blocks while offline  
        vm.roll(block.number + 20);
        
        // Set provider back online
        managedService.setServiceProviderOnline(serviceProvider);
        
        // Advance time by 40 more blocks while online
        vm.roll(block.number + 40);
        
        (uint256 uptimePercentage, uint256 totalServiceTime, uint256 totalOnlineEpochs) = 
            managedService.getServiceProviderUptime(serviceProvider);
            
        assertEq(totalServiceTime, 100, "Total service time should be 100 epochs");
        assertEq(totalOnlineEpochs, 80, "Total online epochs should be 80 (40 + 40)");
        assertEq(uptimePercentage, 8000, "Should have 80% uptime (80/100 * 10000)");
    }
    
    function testServiceProviderUptimeNoService() public {
        // Test uptime for provider with no service
        (uint256 uptimePercentage, uint256 totalServiceTime, uint256 totalOnlineEpochs) = 
            managedService.getServiceProviderUptime(serviceProvider);
            
        assertEq(uptimePercentage, 0, "Should have 0% uptime with no service");
        assertEq(totalServiceTime, 0, "Total service time should be 0 with no service");
        assertEq(totalOnlineEpochs, 0, "Total online epochs should be 0 with no service");
    }

    function testCreateServiceCreatesRailAndSetsRate() public {
        // First approve the service provider
        vm.prank(serviceProvider);
        managedService.registerServiceProvider();
        managedService.approveServiceProvider(serviceProvider);
        
        string memory metadata = "Test Service";

        // Contract needs to have funds to pay service providers
        uint256 depositAmount = 1000e6; // 1000 USDFC
        mockUSDFC.approve(address(managedService), depositAmount);
        managedService.depositFunds(depositAmount);

        // Expect ServiceProviderActivated event when activating the service provider
        vm.expectEmit(true, true, true, true);
        emit ServiceProviderActivated(1, 1, serviceProvider);
        
        // Expect ServiceProviderStatusChanged event
        vm.expectEmit(true, false, false, true);
        emit ServiceProviderStatusChanged(serviceProvider, true, block.number);

        // Activate a service provider as the contract owner
        uint256 newServiceId = managedService.activateServiceProvider(serviceProvider, metadata);

        // Verify service provider was activated with correct ID
        assertEq(newServiceId, 1, "Service ID should be 1");

        // Verify service info was stored correctly
        ManagedSubscriptionService.ServiceInfo memory service = managedService.getService(newServiceId);
        assertEq(service.serviceProvider, serviceProvider, "Service provider should be set correctly");
        assertEq(service.metadata, metadata, "Metadata should be stored correctly");
        assertTrue(service.active, "Service should be active");
        assertGt(service.railId, 0, "Rail ID should be set");
        
        // Calculate expected rate based on configured monthly rate
        uint256 monthlyRate = testMonthlyRate * (10 ** mockUSDFC.decimals());
        uint256 expectedRatePerEpoch = monthlyRate / managedService.EPOCHS_PER_MONTH();
        assertEq(service.ratePerEpoch, expectedRatePerEpoch, "Rate per epoch should be calculated correctly");

        // Verify the rail in the actual Payments contract
        Payments.RailView memory rail = payments.getRail(service.railId);

        assertEq(rail.token, address(mockUSDFC), "Token should be USDFC");
        assertEq(rail.from, address(managedService), "From address should be the contract itself");
        assertEq(rail.to, serviceProvider, "To address should be service provider");
        assertEq(rail.operator, address(managedService), "Operator should be the managed service");
        assertEq(rail.arbiter, address(managedService), "Arbiter should be the managed service");
        assertEq(rail.commissionRateBps, 0, "Commission rate should be 0");

        // Verify payment rate is set correctly
        assertEq(rail.paymentRate, expectedRatePerEpoch, "Payment rate should be set correctly");
        
        // Verify service provider status
        (bool online, uint256 lastChange) = managedService.getServiceProviderStatus(serviceProvider);
        assertTrue(online, "Service provider should be online");
        assertEq(lastChange, block.number, "Last change epoch should be current block");
    }

    function testDeactivateServiceProvider() public {
        // First activate a service provider
        vm.prank(serviceProvider);
        managedService.registerServiceProvider();
        managedService.approveServiceProvider(serviceProvider);
        
        string memory metadata = "Test Service";
        uint256 depositAmount = 1000e6;
        mockUSDFC.approve(address(managedService), depositAmount);
        managedService.depositFunds(depositAmount);
        
        uint256 newServiceId = managedService.activateServiceProvider(serviceProvider, metadata);

        // Verify service is active
        ManagedSubscriptionService.ServiceInfo memory serviceBefore = managedService.getService(newServiceId);
        assertTrue(serviceBefore.active, "Service should be active before deactivation");
        
        // Verify SP is online
        (bool onlineBefore,) = managedService.getServiceProviderStatus(serviceProvider);
        assertTrue(onlineBefore, "Service provider should be online before deactivation");

        // Deactivate the service provider
        vm.expectEmit(true, true, false, false);
        emit ServiceProviderDeactivated(newServiceId, serviceBefore.railId);
        
        vm.expectEmit(true, false, false, true);
        emit ServiceProviderStatusChanged(serviceProvider, false, block.number);
        
        managedService.deactivateServiceProvider(newServiceId);

        // Verify service is now inactive
        ManagedSubscriptionService.ServiceInfo memory serviceAfter = managedService.getService(newServiceId);
        assertFalse(serviceAfter.active, "Service should be inactive after deactivation");

        // Verify payment rate was set to 0
        Payments.RailView memory rail = payments.getRail(serviceAfter.railId);
        assertEq(rail.paymentRate, 0, "Payment rate should be 0 after deactivation");
        
        // Verify SP is now offline
        (bool onlineAfter,) = managedService.getServiceProviderStatus(serviceProvider);
        assertFalse(onlineAfter, "Service provider should be offline after deactivation");
    }

    function testSetServiceProviderOffline() public {
        // First create a service
        vm.prank(serviceProvider);
        managedService.registerServiceProvider();
        managedService.approveServiceProvider(serviceProvider);
        
        string memory metadata = "Test Service";
        uint256 depositAmount = 1000e6;
        mockUSDFC.approve(address(managedService), depositAmount);
        managedService.depositFunds(depositAmount);
        
        managedService.activateServiceProvider(serviceProvider, metadata);
        
        // Verify SP is online initially
        (bool onlineBefore,) = managedService.getServiceProviderStatus(serviceProvider);
        assertTrue(onlineBefore, "Service provider should be online initially");

        // Set service provider offline
        vm.expectEmit(true, false, false, true);
        emit ServiceProviderStatusChanged(serviceProvider, false, block.number);
        
        managedService.setServiceProviderOffline(serviceProvider);

        // Verify SP is now offline
        (bool onlineAfter, uint256 lastChange) = managedService.getServiceProviderStatus(serviceProvider);
        assertFalse(onlineAfter, "Service provider should be offline");
        assertEq(lastChange, block.number, "Last change epoch should be current block");
    }
    
    function testSetServiceProviderOnline() public {
        // First create a service and set offline
        vm.prank(serviceProvider);
        managedService.registerServiceProvider();
        managedService.approveServiceProvider(serviceProvider);
        
        string memory metadata = "Test Service";
        uint256 depositAmount = 1000e6;
        mockUSDFC.approve(address(managedService), depositAmount);
        managedService.depositFunds(depositAmount);
        
        managedService.activateServiceProvider(serviceProvider, metadata);
        managedService.setServiceProviderOffline(serviceProvider);
        
        // Verify SP is offline
        (bool offlineBefore,) = managedService.getServiceProviderStatus(serviceProvider);
        assertFalse(offlineBefore, "Service provider should be offline");

        // Set service provider back online
        vm.expectEmit(true, false, false, true);
        emit ServiceProviderStatusChanged(serviceProvider, true, block.number);
        
        managedService.setServiceProviderOnline(serviceProvider);

        // Verify SP is now online
        (bool onlineAfter, uint256 lastChange) = managedService.getServiceProviderStatus(serviceProvider);
        assertTrue(onlineAfter, "Service provider should be online");
        assertEq(lastChange, block.number, "Last change epoch should be current block");
    }

    function testOnlyOwnerCanSetServiceProviderStatus() public {
        // First create a service
        vm.prank(serviceProvider);
        managedService.registerServiceProvider();
        managedService.approveServiceProvider(serviceProvider);
        
        string memory metadata = "Test Service";
        uint256 depositAmount = 1000e6;
        mockUSDFC.approve(address(managedService), depositAmount);
        managedService.depositFunds(depositAmount);
        
        managedService.activateServiceProvider(serviceProvider, metadata);

        // Try to set offline as non-owner
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, client));
        managedService.setServiceProviderOffline(serviceProvider);
        
        // Try to set online as non-owner
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, client));
        managedService.setServiceProviderOnline(serviceProvider);
    }

    // Helper function to get account info from the Payments contract
    function getAccountInfo(address token, address owner)
        internal
        view
        returns (uint256 funds, uint256 lockupCurrent)
    {
        (funds, lockupCurrent,,) = payments.accounts(token, owner);
        return (funds, lockupCurrent);
    }

    // ===== Service Provider Registry Tests =====

    function testRegisterServiceProvider() public {
        vm.startPrank(sp1);
        
        vm.expectEmit(true, false, false, false);
        emit ProviderRegistered(sp1);
        
        managedService.registerServiceProvider();
        
        vm.stopPrank();
        
        // Verify pending registration
        ManagedSubscriptionService.PendingProviderInfo memory pending = managedService.getPendingProvider(sp1);
        assertEq(pending.registeredAt, block.number, "Registration epoch should match");
    }

    function testCannotRegisterTwiceWhilePending() public {
        vm.startPrank(sp1);
        
        // First registration
        managedService.registerServiceProvider();
        
        // Try to register again
        vm.expectRevert("Registration already pending");
        managedService.registerServiceProvider();
        
        vm.stopPrank();
    }

    function testCannotRegisterIfAlreadyApproved() public {
        // Register and approve SP1
        vm.prank(sp1);
        managedService.registerServiceProvider();
        
        managedService.approveServiceProvider(sp1);
        
        // Try to register again
        vm.prank(sp1);
        vm.expectRevert("Provider already approved");
        managedService.registerServiceProvider();
    }

    function testApproveServiceProvider() public {
        // SP registers
        vm.prank(sp1);
        managedService.registerServiceProvider();
        
        // Get the registration block from pending info
        ManagedSubscriptionService.PendingProviderInfo memory pendingInfo = managedService.getPendingProvider(sp1);
        uint256 registrationBlock = pendingInfo.registeredAt;
        
        vm.roll(block.number + 10); // Advance blocks
        uint256 approvalBlock = block.number;
        
        // Owner approves
        vm.expectEmit(true, true, false, false);
        emit ProviderApproved(sp1, 1);
        
        managedService.approveServiceProvider(sp1);
        
        // Verify approval
        assertTrue(managedService.isProviderApproved(sp1), "SP should be approved");
        assertEq(managedService.getProviderIdByAddress(sp1), 1, "SP should have ID 1");
        
        // Verify SP info
        ManagedSubscriptionService.ApprovedProviderInfo memory info = managedService.getApprovedProvider(1);
        assertEq(info.owner, sp1, "Owner should match");
        assertEq(info.registeredAt, registrationBlock, "Registration epoch should match");
        assertEq(info.approvedAt, approvalBlock, "Approval epoch should match");
        
        // Verify pending registration cleared
        ManagedSubscriptionService.PendingProviderInfo memory pending = managedService.getPendingProvider(sp1);
        assertEq(pending.registeredAt, 0, "Pending registration should be cleared");
    }

    function testRejectServiceProvider() public {
        // SP registers
        vm.prank(sp1);
        managedService.registerServiceProvider();
        
        // Owner rejects
        vm.expectEmit(true, false, false, false);
        emit ProviderRejected(sp1);
        
        managedService.rejectServiceProvider(sp1);
        
        // Verify not approved
        assertFalse(managedService.isProviderApproved(sp1), "SP should not be approved");
        assertEq(managedService.getProviderIdByAddress(sp1), 0, "SP should have no ID");
        
        // Verify pending registration cleared
        ManagedSubscriptionService.PendingProviderInfo memory pending = managedService.getPendingProvider(sp1);
        assertEq(pending.registeredAt, 0, "Pending registration should be cleared");
    }

    function testRemoveServiceProvider() public {
        // Register and approve SP
        vm.prank(sp1);
        managedService.registerServiceProvider();
        managedService.approveServiceProvider(sp1);
        
        // Verify SP is approved
        assertTrue(managedService.isProviderApproved(sp1), "SP should be approved");
        assertEq(managedService.getProviderIdByAddress(sp1), 1, "SP should have ID 1");
        
        // Owner removes the provider
        vm.expectEmit(true, true, false, false);
        emit ProviderRemoved(sp1, 1);
        
        managedService.removeServiceProvider(1);
        
        // Verify SP is no longer approved
        assertFalse(managedService.isProviderApproved(sp1), "SP should not be approved");
        assertEq(managedService.getProviderIdByAddress(sp1), 0, "SP should have no ID");
    }

    function testOnlyOwnerCanApprove() public {
        vm.prank(sp1);
        managedService.registerServiceProvider();
        
        vm.prank(sp2);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, sp2));
        managedService.approveServiceProvider(sp1);
    }

    function testOnlyOwnerCanReject() public {
        vm.prank(sp1);
        managedService.registerServiceProvider();
        
        vm.prank(sp2);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, sp2));
        managedService.rejectServiceProvider(sp1);
    }

    function testOnlyOwnerCanRemove() public {
        // Register and approve SP
        vm.prank(sp1);
        managedService.registerServiceProvider();
        managedService.approveServiceProvider(sp1);
        
        // Try to remove as non-owner
        vm.prank(sp2);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, sp2));
        managedService.removeServiceProvider(1);
    }

    function testGetAllApprovedProviders() public {
        // No providers initially
        ManagedSubscriptionService.ApprovedProviderInfo[] memory providers = managedService.getAllApprovedProviders();
        assertEq(providers.length, 0, "Should return empty array initially");

        // Register and approve multiple providers
        vm.prank(sp1);
        managedService.registerServiceProvider();
        managedService.approveServiceProvider(sp1);

        vm.prank(sp2);
        managedService.registerServiceProvider();
        managedService.approveServiceProvider(sp2);

        // Get all approved providers
        providers = managedService.getAllApprovedProviders();
        assertEq(providers.length, 2, "Should have two approved providers");
        assertEq(providers[0].owner, sp1, "First provider should be sp1");
        assertEq(providers[1].owner, sp2, "Second provider should be sp2");
    }

    function testGetProviderService() public {
        // No service initially
        ManagedSubscriptionService.ServiceInfo memory service = managedService.getProviderService(serviceProvider);
        assertEq(service.serviceProvider, address(0), "Should return empty service initially");
        assertFalse(service.active, "Should not be active initially");

        // Create a service
        vm.prank(serviceProvider);
        managedService.registerServiceProvider();
        managedService.approveServiceProvider(serviceProvider);
        
        string memory metadata = "Test Service";
        uint256 depositAmount = 1000e6;
        mockUSDFC.approve(address(managedService), depositAmount);
        managedService.depositFunds(depositAmount);
        
        managedService.activateServiceProvider(serviceProvider, metadata);

        // Get provider service
        service = managedService.getProviderService(serviceProvider);
        assertEq(service.serviceProvider, serviceProvider, "Service provider should match");
        assertEq(service.metadata, metadata, "Metadata should match");
        assertTrue(service.active, "Service should be active");
    }

    function testArbitratePaymentOnlineProvider() public {
        // Create a service first
        vm.prank(serviceProvider);
        managedService.registerServiceProvider();
        managedService.approveServiceProvider(serviceProvider);
        
        string memory metadata = "Test Service";
        uint256 depositAmount = 1000e6;
        mockUSDFC.approve(address(managedService), depositAmount);
        managedService.depositFunds(depositAmount);
        
        uint256 newServiceId = managedService.activateServiceProvider(serviceProvider, metadata);
        ManagedSubscriptionService.ServiceInfo memory service = managedService.getService(newServiceId);

        // Service provider is online, so should get full payment
        uint256 fromEpoch = 100;
        uint256 toEpoch = 200;
        uint256 totalEpochs = toEpoch - fromEpoch;
        uint256 expectedPayment = service.ratePerEpoch * totalEpochs;

        // Test arbitration with online provider
        IArbiter.ArbitrationResult memory result = managedService.arbitratePayment(
            service.railId,
            expectedPayment, // proposed amount
            fromEpoch,  // from epoch
            toEpoch,  // to epoch
            service.ratePerEpoch // rate
        );

        assertEq(result.modifiedAmount, expectedPayment, "Should approve payment for online time");
        assertEq(result.settleUpto, toEpoch, "Should settle up to end epoch");
        assertEq(result.note, "Payment calculated based on online time", "Should have correct note");
    }
    
    function testArbitratePaymentOfflineProvider() public {
        // Create a service first
        vm.prank(serviceProvider);
        managedService.registerServiceProvider();
        managedService.approveServiceProvider(serviceProvider);
        
        string memory metadata = "Test Service";
        uint256 depositAmount = 1000e6;
        mockUSDFC.approve(address(managedService), depositAmount);
        managedService.depositFunds(depositAmount);
        
        uint256 newServiceId = managedService.activateServiceProvider(serviceProvider, metadata);
        ManagedSubscriptionService.ServiceInfo memory service = managedService.getService(newServiceId);
        
        // Set service provider offline
        managedService.setServiceProviderOffline(serviceProvider);

        // Service provider is offline, so should get no payment
        uint256 fromEpoch = 100;
        uint256 toEpoch = 200;
        uint256 proposedAmount = service.ratePerEpoch * (toEpoch - fromEpoch);

        // Test arbitration with offline provider
        IArbiter.ArbitrationResult memory result = managedService.arbitratePayment(
            service.railId,
            proposedAmount, // proposed amount
            fromEpoch,  // from epoch
            toEpoch,  // to epoch
            service.ratePerEpoch // rate
        );

        assertEq(result.modifiedAmount, 0, "Should approve no payment for offline provider");
        assertEq(result.settleUpto, toEpoch, "Should settle up to end epoch");
        assertEq(result.note, "Payment calculated based on online time", "Should have correct note");
    }

    function testDepositAndWithdrawFunds() public {
        uint256 depositAmount = 1000e6; // 1000 USDFC
        
        // Get initial balance
        uint256 initialBalance = mockUSDFC.balanceOf(address(this));
        
        // Deposit funds
        mockUSDFC.approve(address(managedService), depositAmount);
        managedService.depositFunds(depositAmount);
        
        // Check balance decreased
        uint256 balanceAfterDeposit = mockUSDFC.balanceOf(address(this));
        assertEq(balanceAfterDeposit, initialBalance - depositAmount, "Balance should decrease after deposit");
        
        // Withdraw funds
        managedService.withdrawFunds(depositAmount);
        
        // Check balance restored
        uint256 balanceAfterWithdraw = mockUSDFC.balanceOf(address(this));
        assertEq(balanceAfterWithdraw, initialBalance, "Balance should be restored after withdraw");
    }
    

    
    function testOnlyOwnerCanDepositFunds() public {
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, client));
        managedService.depositFunds(1000e6);
    }
    
    function testOnlyOwnerCanWithdrawFunds() public {
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, client));
        managedService.withdrawFunds(1000e6);
    }
    
    function testCannotCreateMultipleActiveServices() public {
        // Register and approve service provider
        vm.prank(serviceProvider);
        managedService.registerServiceProvider();
        managedService.approveServiceProvider(serviceProvider);
        
        // Fund the contract
        uint256 depositAmount = 1000e6;
        mockUSDFC.approve(address(managedService), depositAmount);
        managedService.depositFunds(depositAmount);
        
        // Create first service
        managedService.activateServiceProvider(serviceProvider, "Service 1");
        
        // Try to activate second service for same provider
        vm.expectRevert("Service provider already has an active service");
        managedService.activateServiceProvider(serviceProvider, "Service 2");
    }

    
    function testCalculatePaymentForPeriod() public {
        // Create a service first
        vm.prank(serviceProvider);
        managedService.registerServiceProvider();
        managedService.approveServiceProvider(serviceProvider);
        
        string memory metadata = "Test Service";
        uint256 depositAmount = 1000e6;
        mockUSDFC.approve(address(managedService), depositAmount);
        managedService.depositFunds(depositAmount);
        
        uint256 newServiceId = managedService.activateServiceProvider(serviceProvider, metadata);
        ManagedSubscriptionService.ServiceInfo memory service = managedService.getService(newServiceId);
        
        uint256 fromEpoch = 100;
        uint256 toEpoch = 200;
        uint256 totalEpochs = toEpoch - fromEpoch;
        
        // Test with online provider
        uint256 paymentOnline = managedService.calculatePaymentForPeriod(serviceProvider, fromEpoch, toEpoch);
        uint256 expectedPayment = service.ratePerEpoch * totalEpochs;
        assertEq(paymentOnline, expectedPayment, "Should calculate full payment for online provider");
        
        // Set provider offline and test again
        managedService.setServiceProviderOffline(serviceProvider);
        uint256 paymentOffline = managedService.calculatePaymentForPeriod(serviceProvider, fromEpoch, toEpoch);
        assertEq(paymentOffline, 0, "Should calculate no payment for offline provider");
    }

    function testPartialPaymentWhenServiceStoppedOnDay3() public {
        // Create a service first
        vm.prank(serviceProvider);
        managedService.registerServiceProvider();
        managedService.approveServiceProvider(serviceProvider);
        
        string memory metadata = "Test Service";
        uint256 depositAmount = 1000e6;
        mockUSDFC.approve(address(managedService), depositAmount);
        managedService.depositFunds(depositAmount);
        
        uint256 newServiceId = managedService.activateServiceProvider(serviceProvider, metadata);
        ManagedSubscriptionService.ServiceInfo memory service = managedService.getService(newServiceId);
        
        // Simulate 6 days of service where:
        // Days 1-3: Service provider is online and providing service
        // Days 4-6: Service owner informed verifier that SP stopped providing service
        
        uint256 epochsPerDay = 2880; // As defined in constants
        uint256 startEpoch = block.number;
        
        // Day 1: Service is online (already set by activateServiceProvider)
        vm.roll(startEpoch + epochsPerDay);
        
        // Day 2: Service remains online (no change needed)
        vm.roll(startEpoch + (2 * epochsPerDay));
        
        // Day 3: Service owner discovers service stopped providing service
        // Service owner informs verifier that service provider is offline
        vm.roll(startEpoch + (3 * epochsPerDay));
        managedService.setServiceProviderOffline(serviceProvider);
        
        // Days 4-6: Service provider remains offline
        vm.roll(startEpoch + (6 * epochsPerDay));
        
        // Now SP tries to settle payment for all 6 days
        uint256 fromEpoch = startEpoch;
        uint256 toEpoch = startEpoch + (6 * epochsPerDay);
        uint256 totalEpochs = 6 * epochsPerDay;
        uint256 onlineEpochs = 3 * epochsPerDay; // Only first 3 days
        
        // Test arbitration - SP requests payment for all 6 days but should only get 3 days
        uint256 proposedAmount = service.ratePerEpoch * totalEpochs;
        uint256 expectedPayment = service.ratePerEpoch * onlineEpochs;
        
        IArbiter.ArbitrationResult memory result = managedService.arbitratePayment(
            service.railId,
            proposedAmount,
            fromEpoch,
            toEpoch,
            service.ratePerEpoch
        );
        
        // Verify SP only gets paid for 3 days worth of service
        assertEq(result.modifiedAmount, expectedPayment, "SP should only get paid for 3 days when service stopped on day 3");
        assertEq(result.settleUpto, toEpoch, "Should settle up to the requested end epoch");
        assertEq(result.note, "Payment calculated based on uptime percentage from verifier", "Should have correct arbitration note");
        
        // Verify the payment amount is exactly 50% of the requested amount (3 out of 6 days)
        assertEq(result.modifiedAmount * 2, proposedAmount, "Modified amount should be exactly half of proposed amount");
    }
}

// Helper contract for testing signature verification
contract SignatureCheckingManagedSubscriptionService is ManagedSubscriptionService {
    constructor() {
    }
    
    function doRecoverSigner(bytes32 messageHash, bytes memory signature) public pure returns (address) { 
        return recoverSigner(messageHash, signature);
    }
}

contract ManagedSubscriptionServiceSignatureTest is Test {
    // Contracts
    SignatureCheckingManagedSubscriptionService public managedService;
    Payments public payments;
    MockERC20 public mockUSDFC;

    // Test accounts with known private keys
    address public signer;
    uint256 public signerPrivateKey;
    address public serviceProvider;
    address public wrongSigner;
    uint256 public wrongSignerPrivateKey;
    
    function setUp() public {
        // Set up test accounts with known private keys
        signerPrivateKey = 0x1234567890123456789012345678901234567890123456789012345678901234;
        signer = vm.addr(signerPrivateKey);
        
        wrongSignerPrivateKey = 0x9876543210987654321098765432109876543210987654321098765432109876;
        wrongSigner = vm.addr(wrongSignerPrivateKey);
        
        serviceProvider = address(0xf2);
        
        // Deploy mock contracts
        mockUSDFC = new MockERC20();
        
        // Deploy actual Payments contract
        Payments paymentsImpl = new Payments();
        bytes memory paymentsInitData = abi.encodeWithSelector(Payments.initialize.selector);
        MyERC1967Proxy paymentsProxy = new MyERC1967Proxy(address(paymentsImpl), paymentsInitData);
        payments = Payments(address(paymentsProxy));
        
        // Deploy and initialize the service
        SignatureCheckingManagedSubscriptionService serviceImpl = new SignatureCheckingManagedSubscriptionService();
        bytes memory initData = abi.encodeWithSelector(
            ManagedSubscriptionService.initialize.selector,
            address(payments),
            address(mockUSDFC),
            "TestService",
            "Test Description",
            10
        );
        
        MyERC1967Proxy serviceProxy = new MyERC1967Proxy(address(serviceImpl), initData);
        managedService = SignatureCheckingManagedSubscriptionService(address(serviceProxy));
        
        // Fund the signer
        mockUSDFC.transfer(signer, 1000 * 10**6); // 1000 USDFC
    }    

    // Test the recoverSigner function
    function testRecoverSignerWithValidSignature() public view {
        // Create the message hash that should be signed
        bytes32 messageHash = keccak256(abi.encode(42));
        
        // Sign the message hash with the signer's private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, messageHash);
        bytes memory validSignature = abi.encodePacked(r, s, v);
        
        // Test that the signature verifies correctly
        address recoveredSigner = managedService.doRecoverSigner(messageHash, validSignature);
        assertEq(recoveredSigner, signer, "Should recover the correct signer address");
    }

    function testRecoverSignerWithWrongSigner() public view {
        // Create the message hash
        bytes32 messageHash = keccak256(abi.encode(42));
        
        // Sign with wrong signer's private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongSignerPrivateKey, messageHash);
        bytes memory wrongSignature = abi.encodePacked(r, s, v);
        
        // Test that the signature recovers the wrong signer (not the expected signer)
        address recoveredSigner = managedService.doRecoverSigner(messageHash, wrongSignature);
        assertEq(recoveredSigner, wrongSigner, "Should recover the wrong signer address");
        assertTrue(recoveredSigner != signer, "Should not recover the expected signer address");
    }
    
    function testRecoverSignerInvalidLength() public {
        bytes32 messageHash = keccak256(abi.encode(42));
        bytes memory invalidSignature = abi.encodePacked(bytes32(0), bytes16(0)); // Wrong length (48 bytes instead of 65)
        
        vm.expectRevert("Invalid signature length");
        managedService.doRecoverSigner(messageHash, invalidSignature);
    }

    function testRecoverSignerInvalidVValue() public {
        bytes32 messageHash = keccak256(abi.encode(42));
        
        // Create signature with invalid v value
        bytes32 r = bytes32(uint256(1));
        bytes32 s = bytes32(uint256(2));
        uint8 v = 25; // Invalid v value (should be 27 or 28)
        bytes memory invalidSignature = abi.encodePacked(r, s, v);
        
        vm.expectRevert("Unsupported signature 'v' value");
        managedService.doRecoverSigner(messageHash, invalidSignature);
    }

    function testRecoverSignerWithZeroSignature() public view {
        bytes32 messageHash = keccak256(abi.encode(42));
        
        // Create signature with all zeros
        bytes32 r = bytes32(0);
        bytes32 s = bytes32(0);
        uint8 v = 27;
        bytes memory zeroSignature = abi.encodePacked(r, s, v);
        
        // This should not revert but should return address(0) (ecrecover returns address(0) for invalid signatures)
        address recoveredSigner = managedService.doRecoverSigner(messageHash, zeroSignature);
        assertEq(recoveredSigner, address(0), "Should return zero address for invalid signature");
    }
}