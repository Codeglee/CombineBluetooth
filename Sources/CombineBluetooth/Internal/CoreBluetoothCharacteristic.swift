import Combine
import CoreBluetooth

struct CoreBluetoothCharacteristic: Identifiable {
    var id: CBUUID { characteristic.id }
    let characteristic: CBCharacteristic

    init(characteristic: CBCharacteristic) {
        self.characteristic = characteristic
    }
}

extension CoreBluetoothCharacteristic: BluetoothCharacteristic {
    var service: BluetoothService? { characteristic.service != nil ? CoreBluetoothService(service: characteristic.service!) : nil }
    var properties: CBCharacteristicProperties { characteristic.properties }
    var value: Data? { characteristic.value }
    var descriptors: [BluetoothDescriptor]? { characteristic.descriptors?.map(CoreBluetoothDescriptor.init) }
    var isNotifying: Bool { characteristic.isNotifying }
    var permissions: CBAttributePermissions? { (characteristic as? CBMutableCharacteristic)?.permissions }
    var subscribedCentrals: [BluetoothCentral]? { (characteristic as? CBMutableCharacteristic)?.subscribedCentrals }
}
