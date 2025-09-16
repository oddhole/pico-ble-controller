import bluetooth
from machine import Pin
import time

# Setup pins
led = Pin("LED", Pin.OUT)
led.off()
relay_pin = Pin(2, Pin.OUT)
buzzer_pin = Pin(3, Pin.OUT)

# Initialize Bluetooth
ble = bluetooth.BLE()
ble.active(True)

# Device tracking
connected_devices = {}
rssi_blink_active = False
current_rssi = -60  # Default moderate signal

# BLE Service and Characteristics
SERVICE_UUID = bluetooth.UUID('12345678-1234-5678-1234-123456789abc')
LED_CHAR_UUID = bluetooth.UUID('87654321-1234-5678-1234-cba987654321')

# Register service
service_def = (
    SERVICE_UUID,
    (
        (LED_CHAR_UUID, bluetooth.FLAG_READ | bluetooth.FLAG_WRITE | bluetooth.FLAG_NOTIFY),
    )
)

((led_handle,),) = ble.gatts_register_services((service_def,))
ble.gatts_write(led_handle, b'ready')

def rssi_to_blink_interval(rssi):
    """Convert RSSI to blink interval in milliseconds"""
    # RSSI thresholds with precise blink intervals
    rssi_map = {
        -30: 25,    # Excellent signal - very fast blink
        -35: 50,    # Very strong signal
        -40: 75,    # Strong signal
        -45: 100,   # Good signal
        -50: 150,   # Moderate signal
        -60: 300,   # Fair signal
        -70: 600,   # Weak signal
        -80: 1000,  # Poor signal
        -90: 1500   # Very poor signal
    }
    
    # Find the appropriate interval based on RSSI value
    # Use the threshold that the RSSI is greater than or equal to
    for threshold in sorted(rssi_map.keys(), reverse=True):
        if rssi >= threshold:
            return rssi_map[threshold]
    
    # If RSSI is worse than -90, use slowest blink
    return 1500

def update_rssi(new_rssi):
    """Update current RSSI value from Flutter app"""
    global current_rssi
    current_rssi = new_rssi
    print(f"📶 RSSI updated: {current_rssi} dBm")

def start_rssi_monitoring():
    """Start RSSI-based LED blinking"""
    global rssi_blink_active
    rssi_blink_active = True
    print("📶 Started RSSI monitoring and LED blinking")

def stop_rssi_monitoring():
    """Stop RSSI-based LED blinking"""
    global rssi_blink_active
    rssi_blink_active = False
    led.off()
    print("📶 Stopped RSSI monitoring")

def update_rssi_blink():
    """Update LED blinking based on current RSSI"""
    if not rssi_blink_active:
        return 400  # Default interval in ms
    
    interval_ms = rssi_to_blink_interval(current_rssi)
    
    # Just toggle the LED - don't use blocking sleep here
    led.toggle()
    
    print(f"📶 RSSI: {current_rssi} dBm, Blink interval: {interval_ms}ms, LED: {'ON' if led.value() else 'OFF'}")
    
    return interval_ms

def get_device_addr_string(addr_bytes):
    """Convert address bytes to string"""
    return ':'.join(['%02x' % b for b in addr_bytes])

def welcome_sequence():
    """LED welcome sequence when device connects"""
    print("🎯 Device connected - playing welcome sequence!")
    
    # LED welcome sequence
    for i in range(5):
        led.on()
        time.sleep(0.15)
        led.off()
        time.sleep(0.1)
    
    print("✅ Welcome sequence completed")

def ble_handler(event, data):
    global connected_devices
    
    if event == 1:  # Device connected
        conn_handle, addr_type, addr = data
        addr_str = get_device_addr_string(addr)
        
        connected_devices[conn_handle] = {
            'addr': addr_str,
            'name': 'Phone'
        }
        
        print(f"📱 Device connected: {addr_str}")
        
        # Play welcome sequence
        welcome_sequence()
        
        # Send ready notification
        try:
            ble.gatts_notify(conn_handle, led_handle, b'connected')
        except:
            pass
            
    elif event == 2:  # Device disconnected
        conn_handle, addr_type, addr = data
        if conn_handle in connected_devices:
            device_info = connected_devices[conn_handle]
            print(f"📱 Device disconnected: {device_info['addr']}")
            
            # Stop RSSI monitoring when device disconnects
            stop_rssi_monitoring()
            
            del connected_devices[conn_handle]
            
    elif event == 3:  # Data written
        conn_handle, value_handle = data
        
        if conn_handle not in connected_devices:
            return
            
        device_info = connected_devices[conn_handle]
        
        if value_handle == led_handle:
            # LED control
            value = ble.gatts_read(led_handle)
            command = value.decode('utf-8').strip().lower()
            
            print(f"📝 Command from {device_info['addr']}: {command}")
            
            if command in ['1', 'on']:
                # Turn off RSSI blinking and turn LED on solid
                stop_rssi_monitoring()
                led.on()
                status = 'on'
            elif command in ['0', 'off']:
                # Turn off RSSI blinking and turn LED off
                stop_rssi_monitoring()
                led.off()
                status = 'off'
            elif command == 'toggle':
                # Turn off RSSI blinking and toggle LED
                stop_rssi_monitoring()
                led.toggle()
                status = 'on' if led.value() else 'off'
            elif command == 'unlock':
                relay_pin.on()
                status = 'unlocked'
            elif command == 'lock':
                relay_pin.off()
                status = 'locked'
            elif command == 'start_rssi':
                # Start RSSI monitoring mode
                start_rssi_monitoring()
                status = 'rssi_started'
            elif command == 'stop_rssi':
                # Stop RSSI monitoring mode
                stop_rssi_monitoring()
                status = 'rssi_stopped'
            elif command.startswith('rssi:'):
                # Receive RSSI data from Flutter app
                try:
                    rssi_value = int(command.split(':')[1])
                    update_rssi(rssi_value)
                    status = f'rssi_updated:{rssi_value}'
                except:
                    status = 'rssi_error'
            else:
                status = 'unknown'
            
            # Send status back
            try:
                ble.gatts_notify(conn_handle, led_handle, status.encode())
            except:
                pass

# Set event handler
ble.irq(ble_handler)

def start_advertising():
    """Start BLE advertising as a discoverable device"""
    name = b'Gate'  # Device name for pairing
    
    # Build advertising data
    adv_data = bytearray()
    
    # Flags - General discoverable mode
    adv_data += bytes([2, 0x01, 0x06])  # General discoverable, BR/EDR not supported
    
    # Complete Local Name
    adv_data += bytes([len(name) + 1, 0x09]) + name
    
    # Service UUID (128-bit)
    service_bytes = bytes(SERVICE_UUID)
    adv_data += bytes([len(service_bytes) + 1, 0x07]) + service_bytes
    
    print(f"📡 Advertising data: {len(adv_data)} bytes")
    
    # Set device name in GAP
    try:
        ble.config(gap_name=name.decode())
        print(f"🏷️ GAP name: {name.decode()}")
    except Exception as e:
        print(f"⚠️ GAP name error: {e}")
    
    # Start advertising (100ms interval = discoverable)
    ble.gap_advertise(100, adv_data)
    print(f"📡 Advertising as: {name.decode()}")
    print(f"✅ Device ready for pairing - look for '{name.decode()}' in Bluetooth settings")

# Start advertising
start_advertising()

print("="*50)
print("🚪 SIMPLIFIED PICO W GATE CONTROLLER")
print("="*50)
print("📱 Ready for pairing!")
print("🔍 Look for 'Gate' in your phone's Bluetooth settings")
print("🔗 No password required - just pair and connect")
print("="*50)

# Main loop
last_blink_time_ms = 0
current_blink_interval_ms = 400

try:
    while True:
        # Use millisecond precision timing
        current_time_ms = time.ticks_ms()
        
        # Handle RSSI-based blinking
        if rssi_blink_active and connected_devices:
            # Update blink interval based on current RSSI
            current_blink_interval_ms = rssi_to_blink_interval(current_rssi)
            
            # Check if it's time to toggle the LED
            if time.ticks_diff(current_time_ms, last_blink_time_ms) >= current_blink_interval_ms:
                update_rssi_blink()
                last_blink_time_ms = current_time_ms
        
        # Show periodic status
        if int(time.time()) % 10 == 0 and connected_devices:
            if rssi_blink_active:
                print(f"💚 Status: RSSI {current_rssi} dBm, Blink: {current_blink_interval_ms}ms")
            else:
                print(f"💙 Status: Connected, RSSI monitoring off")
        
        time.sleep_ms(20)  # 20ms sleep for responsive timing
            
except KeyboardInterrupt:
    print("\n👋 Stopping...")
    stop_rssi_monitoring()
    led.off()
    relay_pin.off()
    buzzer_pin.off()
    ble.active(False)
