import CoreBluetooth
import Combine

public struct CoreBluetoothService: Identifiable {
    public var id: CBUUID { service.id }
    let service: CBService

    init(service: CBService) {
        self.service = service
    }
}

extension CoreBluetoothService: BluetoothService {
    public var peripheral: UUID? { service.peripheral?.identifier }
    public var isPrimary: Bool { service.isPrimary }
    public var includedServices: [BluetoothService]? { service.includedServices?.map(CoreBluetoothService.init) }
    public var characteristics: [BluetoothCharacteristic]? { service.characteristics?.map(CoreBluetoothCharacteristic.init) }
}
