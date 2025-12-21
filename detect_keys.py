import evdev
from evdev import ecodes

# Keys to look for
target_keys = {
    'KEY_BRIGHTNESSUP': ecodes.KEY_BRIGHTNESSUP, # 225
    'KEY_BRIGHTNESSDOWN': ecodes.KEY_BRIGHTNESSDOWN, # 224
    'KEY_VOLUMEUP': ecodes.KEY_VOLUMEUP, # 115
    'KEY_VOLUMEDOWN': ecodes.KEY_VOLUMEDOWN, # 114
    'KEY_MUTE': ecodes.KEY_MUTE, # 113
    'KEY_MICMUTE': ecodes.KEY_MICMUTE, # 248? Depends on kernel, usually KEY_MICMUTE or KEY_F20
    'KEY_PLAYPAUSE': ecodes.KEY_PLAYPAUSE, # 164
    'KEY_NEXTSONG': ecodes.KEY_NEXTSONG, # 163
    'KEY_PREVIOUSSONG': ecodes.KEY_PREVIOUSSONG, # 165
    'KEY_PRINT': ecodes.KEY_PRINT, # 99 (SysRq/PrintScreen)
    'KEY_RFKILL': ecodes.KEY_RFKILL, # 247
    'KEY_WLAN': ecodes.KEY_WLAN, # 238
}

# Some keys might be named differently or I want to be robust
# Check for alternates just in case? Usually these standard names are good.
# KEY_MICMUTE might be tricky, checking ecodes directly logic

found_keys = set()
found_devices = []

try:
    devices = [evdev.InputDevice(path) for path in evdev.list_devices()]
except Exception as e:
    print(f"Error listing devices: {e}")
    exit(1)

print(f"Scanning {len(devices)} devices...")

for device in devices:
    caps = device.capabilities()
    if ecodes.EV_KEY in caps:
        supported_keys = caps[ecodes.EV_KEY]
        # supported_keys is a list of integers (keycodes)
        
        device_has_target = False
        print(f"Checking device: {device.name} at {device.path}")
        
        for name, code in target_keys.items():
            if code in supported_keys:
                if name not in found_keys:
                    print(f"  FOUND {name}")
                    found_keys.add(name)
                    device_has_target = True
        
        if device_has_target:
            found_devices.append(device.name)

print("-" * 20)
print("FINAL DETECTED KEYS:")
for key in sorted(found_keys):
    print(key)
print("-" * 20)
