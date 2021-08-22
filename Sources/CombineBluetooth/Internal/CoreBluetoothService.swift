import CoreBluetooth
import Combine

public struct CoreBluetoothService: Identifiable {
    var id: CBUUID { service.id }
    let service: CBService

    init(service: CBService) {
        self.service = service
    }
}

extension CoreBluetoothService: BluetoothService {
    var peripheral: UUID? { service.peripheral?.identifier }
    var isPrimary: Bool { service.isPrimary }
    var includedServices: [BluetoothService]? { service.includedServices?.map(CoreBluetoothService.init) }
    var characteristics: [BluetoothCharacteristic]? { service.characteristics?.map(CoreBluetoothCharacteristic.init) }
}
