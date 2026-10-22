// Compile-time configuration for the Thunderbolt Displays HAL plugin.
// Included ahead of vendor/BlackHole/BlackHole/BlackHole.c via -include.
#define kDriver_Name                "Thunderbolt Displays"
#define kDevice_Name                "Thunderbolt Displays"
#define kPlugIn_BundleID            "com.andresurena.ThunderboltDisplays"
#define kPlugIn_Icon                "BlackHole.icns"
#define kManufacturer_Name          "AU DEV"
#define kHas_Driver_Name_Format     false
#define kNumber_Of_Channels         2
#define kSampleRates                48000
// Keep the volume/mute controls (so the keyboard keys drive this device) but do not
// attenuate the audio in software: the helper mirrors the level to the displays' own
// hardware volume instead.
#define kEnableVolumeControl        false
#define kCanBeDefaultDevice         true
#define kCanBeDefaultSystemDevice   true
