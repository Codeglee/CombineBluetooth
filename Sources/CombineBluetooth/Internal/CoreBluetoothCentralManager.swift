import Combine
import CoreBluetooth

public class CoreBluetoothCentralManager: NSObject {
    private var kvoDelegate: AnyCancellable?
    private let centralManager: CBCentralManager
    // This is required to avoid returning different instances of CoreBluetoothPeripheral every time we discover a device previously discovered.
    // There should not be different instances because CoreBluetoothPeripheral holds the delegate for the CBPeripheral, which is expected to be
    // unique.
    private var cachedPeripherals: [UUID: CoreBluetoothPeripheral] = [:]
    private let cachedPeripheralsAccess = NSRecursiveLock()

    init(centralManager: CBCentralManager) {
        self.centralManager = centralManager
        super.init()
        restoreDelegation()
    }

    private var _state: CurrentValueSubject<CBManagerState, BluetoothError> = .init(.unknown)
    private var _stateRestoration: PassthroughSubject<StateRestorationEvent, BluetoothError> = .init()
    private var _scanPublisher: PassthroughSubject<AdvertisingPeripheral, BluetoothError> = .init()

    private var _didConnectPeripheral: PassthroughSubject<CBPeripheral, Never> = .init()
    private var _didFailToConnectPeripheral: PassthroughSubject<(peripheral: CBPeripheral, error: Error?), Never> = .init()
    private var _didDisconnectPeripheral: PassthroughSubject<(peripheral: CBPeripheral, error: Error?), Never> = .init()

    func restoreDelegation() {
        _state = .init(centralManager.state)
        _stateRestoration = .init()
        _scanPublisher = .init()
        centralManager.delegate = self
        kvoDelegate = centralManager.publisher(for: \.delegate).sink { [weak self] value in
            guard let self = self else { return }
            guard value !== self else { return }

            self._state.send(completion: .failure(.noLongerDelegate))
            self._stateRestoration.send(completion: .failure(.noLongerDelegate))
            self._scanPublisher.send(completion: .failure(.noLongerDelegate))
            self.kvoDelegate = nil
        }
    }
}

extension CoreBluetoothCentralManager: CentralManager {
    private func peripheral(for cbPeripheral: CBPeripheral) -> CoreBluetoothPeripheral {
        cachedPeripheralsAccess.lock()
        defer { cachedPeripheralsAccess.unlock() }
        if let instance = cachedPeripherals[cbPeripheral.identifier] { return instance }
        let newInstance = CoreBluetoothPeripheral.from(peripheral: cbPeripheral)
        cachedPeripherals[cbPeripheral.identifier] = newInstance
        return newInstance
    }

    public var isScanning: AnyPublisher<Bool, Never> {
        centralManager
            .publisher(for: \.isScanning)
            .prepend(centralManager.isScanning)
            .removeDuplicates()
            .eraseToAnyPublisher()
    }
    public var state: AnyPublisher<CBManagerState, BluetoothError> { _state.eraseToAnyPublisher() }
    public var stateRestoration: AnyPublisher<StateRestorationEvent, BluetoothError> { _stateRestoration.eraseToAnyPublisher() }

    public func scanForPeripherals() -> AnyPublisher<AdvertisingPeripheral, BluetoothError> {
        _scanForPeripherals(withServices: nil, options: nil)
    }
    public func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?) -> AnyPublisher<AdvertisingPeripheral, BluetoothError> {
        _scanForPeripherals(withServices: serviceUUIDs, options: nil)
    }
    public func scanForPeripherals(options: [String : Any]) -> AnyPublisher<AdvertisingPeripheral, BluetoothError> {
        _scanForPeripherals(withServices: nil, options: options)
    }
    public func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?, options: [String : Any]) -> AnyPublisher<AdvertisingPeripheral, BluetoothError> {
        _scanForPeripherals(withServices: serviceUUIDs, options: options)
    }

    private func _scanForPeripherals(withServices serviceUUIDs: [CBUUID]?, options: [String: Any]?) -> AnyPublisher<AdvertisingPeripheral, BluetoothError> {
        _scanPublisher = .init()
        let cm = self.centralManager
        return _scanPublisher
            .handleEvents(
                receiveCancel: { cm.stopScan() },
                receiveRequest: { demand in
                    guard demand > .none else { return }
                    cm.scanForPeripherals(withServices: serviceUUIDs, options: options)
                }
            )
            .eraseToAnyPublisher()
    }

    public var peripheralConnection: AnyPublisher<PeripheralConnectionEvent, Never> {
        Publishers.Merge3(
            _didConnectPeripheral
                .map(peripheral(for:))
                .map(PeripheralConnectionEvent.didConnect),
            _didDisconnectPeripheral
                .map { PeripheralConnectionEvent.didDisconnect(peripheral: self.peripheral(for: $0.peripheral), error: $0.error) },
            _didFailToConnectPeripheral
                .map { PeripheralConnectionEvent.didFailToConnect(peripheral: self.peripheral(for: $0.peripheral), error: $0.error) }
        )
        .eraseToAnyPublisher()
    }

    public func connect(_ peripheral: BluetoothPeripheral) -> AnyPublisher<BluetoothPeripheral, BluetoothError> {
        _connect(peripheral, options: nil)
    }

    public func connect(_ peripheral: BluetoothPeripheral, options: [String : Any]) -> AnyPublisher<BluetoothPeripheral, BluetoothError> {
        _connect(peripheral, options: options)
    }

    private func _connect(_ peripheral: BluetoothPeripheral, options: [String : Any]?) -> AnyPublisher<BluetoothPeripheral, BluetoothError> {
        guard let coreBluetoothPeripheral = peripheral as? CoreBluetoothPeripheral else { return Fail(error: BluetoothError.unknownWrapperType).eraseToAnyPublisher() }
        let cm = centralManager
        return Publishers.Merge3(
            _didConnectPeripheral
                .filter { $0.identifier == coreBluetoothPeripheral.peripheral.identifier }
                .map(peripheral(for:))
                .mapError { never -> BluetoothError in },
            _didDisconnectPeripheral
                .filter { $0.peripheral.identifier == coreBluetoothPeripheral.peripheral.identifier }
                .tryMap { disconnection -> BluetoothPeripheral in
                    throw BluetoothError.lostConnection(peripheral: self.peripheral(for: disconnection.peripheral), error: disconnection.error)
                }
                .mapError { $0 as! BluetoothError },
            _didFailToConnectPeripheral
                .filter { $0.peripheral.identifier == coreBluetoothPeripheral.peripheral.identifier }
                .tryMap { disconnection -> BluetoothPeripheral in
                    throw BluetoothError.failOnConnect(peripheral: self.peripheral(for: disconnection.peripheral), error: disconnection.error)
                }
                .mapError { $0 as! BluetoothError }
        )
        .handleEvents(
            receiveSubscription: { _ in
                cm.connect(coreBluetoothPeripheral.peripheral, options: options)
            },
            receiveCancel: {
                cm.cancelPeripheralConnection(coreBluetoothPeripheral.peripheral)
            }
        )
        .eraseToAnyPublisher()
    }

    public func retrievePeripherals(withIdentifiers identifiers: [UUID]) -> [BluetoothPeripheral] {
        centralManager.retrievePeripherals(withIdentifiers: identifiers).map(peripheral(for:))
    }

    public func retrieveConnectedPeripherals(withServices serviceUUIDs: [CBUUID]) -> [BluetoothPeripheral] {
        centralManager.retrieveConnectedPeripherals(withServices: serviceUUIDs).map(peripheral(for:))
    }
}

extension CoreBluetoothCentralManager: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        _state.send(central.state)
    }

    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        _stateRestoration.send(.willRestoreState(dict))
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        _scanPublisher.send(
            CoreBluetoothAdvertisingPeripheral(
                advertisementData: advertisementData,
                rssi: RSSI,
                peripheral: self.peripheral(for: peripheral)
            )
        )
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        _didConnectPeripheral.send(peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        _didFailToConnectPeripheral.send((peripheral: peripheral, error: error))
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        _didDisconnectPeripheral.send((peripheral: peripheral, error: error))
    }
}
