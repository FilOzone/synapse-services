// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @title ServiceUptimeListener
/// @notice Interface for contracts that want to receive uptime verification callbacks
interface ServiceUptimeListener {
    function serviceRegistered(uint256 serviceId, address provider, bytes calldata extraData) external;
    function uptimeReported(uint256 serviceId, uint256 epoch, bool online, bytes calldata extraData) external;
    function serviceDeregistered(uint256 serviceId, bytes calldata extraData) external;
}

/// @title ServiceUptimeVerifier
/// @notice Service Level Indicator (SLI) contract that tracks and verifies service provider uptime
/// @dev This contract is responsible for collecting uptime data and notifying listeners.
/// Payment arbitration and business logic should be handled in separate Service Level Agreement (SLA) contracts.
contract ServiceUptimeVerifier is Initializable, UUPSUpgradeable, OwnableUpgradeable {

    // Events for uptime tracking
    event ServiceRegistered(uint256 indexed serviceId, address indexed provider, address indexed listener);
    event UptimeReported(uint256 indexed serviceId, uint256 indexed epoch, bool online, address reporter);
    event ServiceDeregistered(uint256 indexed serviceId, address indexed provider);
    event ListenerUpdated(uint256 indexed serviceId, address oldListener, address newListener);

    // Service tracking
    struct ServiceInfo {
        address provider;        // Service provider address
        address listener;        // Contract to notify of uptime events
        uint256 registeredAt;    // Block number when service was registered
        bool active;            // Whether the service is currently active
        uint256 lastReportEpoch; // Last epoch when uptime was reported
    }

    // Uptime tracking
    struct UptimeRecord {
        bool online;            // Whether service was online
        uint256 reportedAt;     // Block number when status was reported
        address reporter;       // Who reported the status
    }

    // State variables
    uint256 public nextServiceInstanceId = 1;
    mapping(uint256 => ServiceInfo) public services;
    mapping(address => uint256) public providerToServiceId; // One service per provider
    
    // Uptime data: serviceId => epoch => UptimeRecord
    mapping(uint256 => mapping(uint256 => UptimeRecord)) public uptimeRecords;
    
    // Service activation tracking
    mapping(uint256 => uint256) public serviceActivationEpoch;

    // Constants for uptime calculation
    uint256 public constant EPOCHS_PER_DAY = 2880;
    uint256 public constant EPOCHS_PER_MONTH = 2880 * 30;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize() public initializer {
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        nextServiceInstanceId = 1;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /**
     * @notice Register a new service for uptime tracking
     * @dev Can only be called by the service provider
     * @param listener The contract address that will receive uptime callbacks
     * @param extraData Additional data to pass to the listener
     * @return serviceId The ID of the newly registered service
     */
    function registerService(address listener, bytes calldata extraData) external returns (uint256) {
        require(listener != address(0), "Listener cannot be zero address");
        require(providerToServiceId[msg.sender] == 0, "Provider already has a service registered");

        uint256 serviceId = nextServiceInstanceId++;
        
        services[serviceId] = ServiceInfo({
            provider: msg.sender,
            listener: listener,
            registeredAt: block.number,
            active: true,
            lastReportEpoch: block.number
        });

        providerToServiceId[msg.sender] = serviceId;
        serviceActivationEpoch[serviceId] = block.number;

        emit ServiceRegistered(serviceId, msg.sender, listener);

        // Notify the listener
        ServiceUptimeListener(listener).serviceRegistered(serviceId, msg.sender, extraData);

        return serviceId;
    }

    /**
     * @notice Report uptime status for a service
     * @dev Can be called by service provider, service owner, or authorized reporters
     * @param serviceId The ID of the service
     * @param online Whether the service is currently online
     * @param extraData Additional data to pass to the listener
     */
    function reportUptime(uint256 serviceId, bool online, bytes calldata extraData) external {
        ServiceInfo storage service = services[serviceId];
        require(service.active, "Service is not active");
        require(service.provider != address(0), "Service does not exist");
        
        // Allow service provider, listener contract, or owner to report
        require(
            msg.sender == service.provider || 
            msg.sender == service.listener || 
            msg.sender == owner(),
            "Not authorized to report uptime"
        );

        uint256 currentEpoch = block.number;
        
        // Store the uptime record
        uptimeRecords[serviceId][currentEpoch] = UptimeRecord({
            online: online,
            reportedAt: currentEpoch,
            reporter: msg.sender
        });

        service.lastReportEpoch = currentEpoch;

        emit UptimeReported(serviceId, currentEpoch, online, msg.sender);

        // Notify the listener
        ServiceUptimeListener(service.listener).uptimeReported(serviceId, currentEpoch, online, extraData);
    }

    /**
     * @notice Deregister a service from uptime tracking
     * @dev Can only be called by the service provider or owner
     * @param serviceId The ID of the service to deregister
     * @param extraData Additional data to pass to the listener
     */
    function deregisterService(uint256 serviceId, bytes calldata extraData) external {
        ServiceInfo storage service = services[serviceId];
        require(service.provider != address(0), "Service does not exist");
        require(
            msg.sender == service.provider || msg.sender == owner(),
            "Not authorized to deregister service"
        );

        address provider = service.provider;
        address listener = service.listener;

        // Mark service as inactive
        service.active = false;
        
        // Clear provider mapping
        delete providerToServiceId[provider];

        emit ServiceDeregistered(serviceId, provider);

        // Notify the listener
        ServiceUptimeListener(listener).serviceDeregistered(serviceId, extraData);
    }

    /**
     * @notice Update the listener contract for a service
     * @dev Can only be called by the service provider or owner
     * @param serviceId The ID of the service
     * @param newListener The new listener contract address
     */
    function updateListener(uint256 serviceId, address newListener) external {
        ServiceInfo storage service = services[serviceId];
        require(service.provider != address(0), "Service does not exist");
        require(
            msg.sender == service.provider || msg.sender == owner(),
            "Not authorized to update listener"
        );
        require(newListener != address(0), "Listener cannot be zero address");

        address oldListener = service.listener;
        service.listener = newListener;

        emit ListenerUpdated(serviceId, oldListener, newListener);
    }

    // ========== View Functions ==========

    /**
     * @notice Get service information
     * @param serviceId The ID of the service
     * @return The service information
     */
    function getService(uint256 serviceId) external view returns (ServiceInfo memory) {
        return services[serviceId];
    }

    /**
     * @notice Get service ID for a provider
     * @param provider The provider address
     * @return The service ID, or 0 if not found
     */
    function getServiceIdForProvider(address provider) external view returns (uint256) {
        return providerToServiceId[provider];
    }

    /**
     * @notice Get uptime record for a specific epoch
     * @param serviceId The ID of the service
     * @param epoch The epoch to check
     * @return The uptime record
     */
    function getUptimeRecord(uint256 serviceId, uint256 epoch) external view returns (UptimeRecord memory) {
        return uptimeRecords[serviceId][epoch];
    }

    /**
     * @notice Check if a service was online at a specific epoch
     * @param serviceId The ID of the service
     * @param epoch The epoch to check
     * @return True if service was online, false otherwise
     */
    function isServiceOnline(uint256 serviceId, uint256 epoch) external view returns (bool) {
        ServiceInfo memory service = services[serviceId];
        
        // Service must exist and be registered before the epoch
        if (service.provider == address(0) || epoch < service.registeredAt) {
            return false;
        }

        // Check if we have a specific record for this epoch
        UptimeRecord memory record = uptimeRecords[serviceId][epoch];
        if (record.reportedAt > 0) {
            return record.online;
        }

        // If no specific record, look for the most recent status before this epoch
        // This assumes service stays in the same state until explicitly changed
        for (uint256 i = epoch; i >= service.registeredAt && i > 0; i--) {
            UptimeRecord memory pastRecord = uptimeRecords[serviceId][i];
            if (pastRecord.reportedAt > 0) {
                return pastRecord.online;
            }
            
            // Prevent infinite loop for very old epochs
            if (epoch - i > EPOCHS_PER_MONTH) {
                break;
            }
        }

        // Default to online if no status has been reported (assume service starts online)
        return true;
    }

    /**
     * @notice Calculate uptime percentage for a service over a period
     * @param serviceId The ID of the service
     * @param fromEpoch Starting epoch (exclusive)
     * @param toEpoch Ending epoch (inclusive)
     * @return uptimePercentage Uptime as a percentage (0-10000, where 10000 = 100%)
     */
    function getUptimePercentage(
        uint256 serviceId,
        uint256 fromEpoch,
        uint256 toEpoch
    ) external view returns (uint256 uptimePercentage) {
        require(toEpoch > fromEpoch, "Invalid epoch range");
        
        ServiceInfo memory service = services[serviceId];
        if (service.provider == address(0)) {
            return 0; // Service doesn't exist
        }

        uint256 totalEpochs = toEpoch - fromEpoch;
        uint256 onlineEpochs = 0;

        // Count online epochs in the range
        for (uint256 epoch = fromEpoch + 1; epoch <= toEpoch; epoch++) {
            if (this.isServiceOnline(serviceId, epoch)) {
                onlineEpochs++;
            }
        }

        // Calculate percentage in basis points (0-10000)
        uptimePercentage = (onlineEpochs * 10000) / totalEpochs;
        return uptimePercentage;
    }

    /**
     * @notice Get the most recent uptime status for a service
     * @param serviceId The ID of the service
     * @return online Whether the service is currently online
     * @return lastReported The epoch when status was last reported
     */
    function getCurrentStatus(uint256 serviceId) external view returns (bool online, uint256 lastReported) {
        ServiceInfo memory service = services[serviceId];
        if (service.provider == address(0)) {
            return (false, 0);
        }

        // Look for the most recent report
        uint256 currentEpoch = block.number;
        for (uint256 i = currentEpoch; i >= service.registeredAt && i > 0; i--) {
            UptimeRecord memory record = uptimeRecords[serviceId][i];
            if (record.reportedAt > 0) {
                return (record.online, i);
            }
            
            // Prevent searching too far back
            if (currentEpoch - i > EPOCHS_PER_MONTH) {
                break;
            }
        }

        // Default to online if no reports found
        return (true, service.registeredAt);
    }
}