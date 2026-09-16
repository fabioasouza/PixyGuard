#include <CoreMediaIO/CoreMediaIO.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int get_name(CMIOObjectID id, char *out, size_t outSize) {
    CMIOObjectPropertyAddress addr = {
        kCMIOObjectPropertyName,
        kCMIOObjectPropertyScopeGlobal,
        kCMIOObjectPropertyElementMain
    };
    CFStringRef name = NULL;
    UInt32 used = 0;
    OSStatus st = CMIOObjectGetPropertyData(id, &addr, 0, NULL, sizeof(name), &used, &name);
    if (st != noErr || name == NULL) return 0;
    Boolean ok = CFStringGetCString(name, out, outSize, kCFStringEncodingUTF8);
    CFRelease(name);
    return ok ? 1 : 0;
}

static int get_running(CMIOObjectID id, UInt32 *running) {
    CMIOObjectPropertyAddress addr = {
        kCMIODevicePropertyDeviceIsRunningSomewhere,
        kCMIOObjectPropertyScopeGlobal,
        kCMIOObjectPropertyElementMain
    };
    if (!CMIOObjectHasProperty(id, &addr)) return 0;
    UInt32 used = 0;
    *running = 0;
    OSStatus st = CMIOObjectGetPropertyData(id, &addr, 0, NULL, sizeof(*running), &used, running);
    return st == noErr;
}

int main(void) {
    CMIOObjectPropertyAddress addr = {
        kCMIOHardwarePropertyDevices,
        kCMIOObjectPropertyScopeGlobal,
        kCMIOObjectPropertyElementMain
    };
    UInt32 size = 0;
    if (CMIOObjectGetPropertyDataSize(kCMIOObjectSystemObject, &addr, 0, NULL, &size) != noErr) return 2;
    CMIOObjectID *devices = malloc(size);
    if (!devices) return 2;
    UInt32 used = 0;
    if (CMIOObjectGetPropertyData(kCMIOObjectSystemObject, &addr, 0, NULL, size, &used, devices) != noErr) {
        free(devices); return 2;
    }
    size_t count = used / sizeof(CMIOObjectID);
    int found = 0;
    int active = 0;
    for (size_t i = 0; i < count; i++) {
        char name[256] = {0};
        if (!get_name(devices[i], name, sizeof(name))) continue;
        if (strcasestr(name, "pixy") == NULL && strcasestr(name, "emeet") == NULL) continue;
        found = 1;
        UInt32 running = 0;
        if (get_running(devices[i], &running) && running != 0) { active = 1; break; }
    }
    free(devices);
    if (!found) return 2;
    return active ? 0 : 1;
}
