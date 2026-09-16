#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDLib.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define PIXY_VID 12943
#define PIXY_PID 192
#define REPORT_SIZE 32
#define PAYLOAD_PER_REPORT 24

typedef struct {
    IOHIDManagerRef manager;
    IOHIDDeviceRef device;
    CFRunLoopRef run_loop;
    uint8_t input_report[REPORT_SIZE];
    uint8_t pending_response[REPORT_SIZE];
    CFIndex pending_length;
    int has_pending_response;
} PixyHid;

static const uint8_t HEAD_SET_MODE[4] = {0x09, 0x01, 0x01, 0x00};
static const uint8_t HEAD_GET_MODE[4] = {0x09, 0x01, 0x01, 0x01};
static const uint8_t HEAD_SET_TARGET_TRACK[4] = {0x09, 0x04, 0x01, 0x00};
static const uint8_t HEAD_GET_TARGET_TRACK[4] = {0x09, 0x04, 0x01, 0x01};
static const uint8_t HEAD_MOTOR_ABSOLUTE[4] = {0x09, 0x03, 0x01, 0x18};
static const uint8_t HEAD_MOTOR_RELATIVE[4] = {0x09, 0x03, 0x01, 0x19};

static void usage(FILE *stream) {
    fprintf(stream, "Usage:\n");
    fprintf(stream, "  pixyctl status\n");
    fprintf(stream, "  pixyctl list\n");
    fprintf(stream, "  pixyctl get-mode\n");
    fprintf(stream, "  pixyctl get-track\n");
    fprintf(stream, "  pixyctl mode normal|tracking|privacy\n");
    fprintf(stream, "  pixyctl track on|off|face|half|full|<mode-number>\n");
    fprintf(stream, "  pixyctl move up|down|left|right [degrees]\n");
    fprintf(stream, "  pixyctl recenter\n");
    fprintf(stream, "  pixyctl position <pan-degrees> <tilt-degrees>\n");
}

static CFNumberRef cf_number(int value) {
    return CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &value);
}

static CFMutableDictionaryRef create_matching_dictionary(void) {
    CFMutableDictionaryRef dictionary = CFDictionaryCreateMutable(
        kCFAllocatorDefault,
        0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    if (dictionary == NULL) {
        return NULL;
    }

    CFNumberRef vendor = cf_number(PIXY_VID);
    CFNumberRef product = cf_number(PIXY_PID);
    if (vendor == NULL || product == NULL) {
        if (vendor != NULL) {
            CFRelease(vendor);
        }
        if (product != NULL) {
            CFRelease(product);
        }
        CFRelease(dictionary);
        return NULL;
    }

    CFDictionarySetValue(dictionary, CFSTR("VendorID"), vendor);
    CFDictionarySetValue(dictionary, CFSTR("ProductID"), product);
    CFRelease(vendor);
    CFRelease(product);
    return dictionary;
}

static int int_property(IOHIDDeviceRef device, CFStringRef key, int fallback) {
    CFTypeRef value = IOHIDDeviceGetProperty(device, key);
    if (value == NULL || CFGetTypeID(value) != CFNumberGetTypeID()) {
        return fallback;
    }

    int out = fallback;
    CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &out);
    return out;
}

static void string_property(IOHIDDeviceRef device, CFStringRef key, char *buffer, size_t buffer_size) {
    if (buffer_size == 0) {
        return;
    }

    buffer[0] = '\0';
    CFTypeRef value = IOHIDDeviceGetProperty(device, key);
    if (value == NULL || CFGetTypeID(value) != CFStringGetTypeID()) {
        return;
    }

    CFStringGetCString((CFStringRef)value, buffer, buffer_size, kCFStringEncodingUTF8);
}

static IOHIDManagerRef create_open_manager(void) {
    IOHIDManagerRef manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (manager == NULL) {
        fprintf(stderr, "Could not create HID manager.\n");
        return NULL;
    }

    CFMutableDictionaryRef matching = create_matching_dictionary();
    if (matching == NULL) {
        fprintf(stderr, "Could not create PIXY HID matching dictionary.\n");
        CFRelease(manager);
        return NULL;
    }

    IOHIDManagerSetDeviceMatching(manager, matching);
    CFRelease(matching);

    IOReturn result = IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone);
    if (result != kIOReturnSuccess) {
        fprintf(stderr, "Could not open HID manager: 0x%08x\n", result);
        CFRelease(manager);
        return NULL;
    }

    return manager;
}

static IOHIDDeviceRef choose_pixy_device(CFSetRef devices) {
    if (devices == NULL || CFSetGetCount(devices) == 0) {
        return NULL;
    }

    CFIndex count = CFSetGetCount(devices);
    IOHIDDeviceRef *values = calloc((size_t)count, sizeof(*values));
    if (values == NULL) {
        return NULL;
    }

    CFSetGetValues(devices, (const void **)values);
    IOHIDDeviceRef first = NULL;
    IOHIDDeviceRef best = NULL;
    for (CFIndex i = 0; i < count; i++) {
        IOHIDDeviceRef device = values[i];
        if (first == NULL) {
            first = device;
        }

        int usage_page = int_property(device, CFSTR("PrimaryUsagePage"), -1);
        int usage = int_property(device, CFSTR("PrimaryUsage"), -1);
        if (usage_page == 0x83 && usage == 0x83) {
            best = device;
            break;
        }
    }

    IOHIDDeviceRef chosen = best != NULL ? best : first;
    if (chosen != NULL) {
        CFRetain(chosen);
    }
    free(values);
    return chosen;
}

static void input_report_callback(void *context, IOReturn result, void *sender, IOHIDReportType type, uint32_t report_id, uint8_t *report, CFIndex report_length) {
    (void)sender;
    (void)type;

    PixyHid *pixy = (PixyHid *)context;
    if (pixy == NULL || result != kIOReturnSuccess || report == NULL || report_length <= 0) {
        return;
    }

    memset(pixy->pending_response, 0, sizeof(pixy->pending_response));
    if (report_id != 0 && (report_length == REPORT_SIZE - 1 || report[0] != (uint8_t)report_id)) {
        pixy->pending_response[0] = (uint8_t)report_id;
        CFIndex copy_length = report_length > REPORT_SIZE - 1 ? REPORT_SIZE - 1 : report_length;
        memcpy(pixy->pending_response + 1, report, (size_t)copy_length);
        pixy->pending_length = copy_length + 1;
    } else {
        CFIndex copy_length = report_length > REPORT_SIZE ? REPORT_SIZE : report_length;
        memcpy(pixy->pending_response, report, (size_t)copy_length);
        pixy->pending_length = copy_length;
    }

    pixy->has_pending_response = 1;
    if (pixy->run_loop != NULL) {
        CFRunLoopStop(pixy->run_loop);
    }
}

static int open_pixy(PixyHid *pixy) {
    memset(pixy, 0, sizeof(*pixy));
    pixy->run_loop = CFRunLoopGetCurrent();

    pixy->manager = create_open_manager();
    if (pixy->manager == NULL) {
        return 2;
    }

    CFSetRef devices = IOHIDManagerCopyDevices(pixy->manager);
    pixy->device = choose_pixy_device(devices);
    if (devices != NULL) {
        CFRelease(devices);
    }

    if (pixy->device == NULL) {
        fprintf(stderr, "EMEET PIXY HID interface was not found.\n");
        IOHIDManagerClose(pixy->manager, kIOHIDOptionsTypeNone);
        CFRelease(pixy->manager);
        memset(pixy, 0, sizeof(*pixy));
        return 2;
    }

    IOHIDDeviceRegisterInputReportCallback(
        pixy->device,
        pixy->input_report,
        sizeof(pixy->input_report),
        input_report_callback,
        pixy);
    IOHIDDeviceScheduleWithRunLoop(pixy->device, pixy->run_loop, kCFRunLoopDefaultMode);

    return 0;
}

static void close_pixy(PixyHid *pixy) {
    if (pixy->device != NULL && pixy->run_loop != NULL) {
        IOHIDDeviceUnscheduleFromRunLoop(pixy->device, pixy->run_loop, kCFRunLoopDefaultMode);
    }
    if (pixy->device != NULL) {
        CFRelease(pixy->device);
    }
    if (pixy->manager != NULL) {
        IOHIDManagerClose(pixy->manager, kIOHIDOptionsTypeNone);
        CFRelease(pixy->manager);
    }
    memset(pixy, 0, sizeof(*pixy));
}

static const char *mode_name(uint8_t mode) {
    switch (mode) {
    case 0:
        return "normal";
    case 1:
        return "tracking";
    case 2:
        return "privacy";
    case 3:
        return "startup";
    default:
        return "unknown";
    }
}

static const char *track_name(uint8_t mode) {
    switch (mode) {
    case 0:
        return "off";
    case 1:
        return "face";
    case 2:
        return "half-body";
    case 3:
        return "full-body";
    default:
        return "custom";
    }
}

static void put_float_le(uint8_t *out, float value) {
    uint32_t bits;
    memcpy(&bits, &value, sizeof(bits));
    out[0] = (uint8_t)(bits & 0xff);
    out[1] = (uint8_t)((bits >> 8) & 0xff);
    out[2] = (uint8_t)((bits >> 16) & 0xff);
    out[3] = (uint8_t)((bits >> 24) & 0xff);
}

static float get_float_le(const uint8_t *in) {
    uint32_t bits = ((uint32_t)in[0]) |
                    ((uint32_t)in[1] << 8) |
                    ((uint32_t)in[2] << 16) |
                    ((uint32_t)in[3] << 24);
    float value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

static void debug_dump_response(const uint8_t *response) {
    if (getenv("PIXYCTL_DEBUG") == NULL || response == NULL) {
        return;
    }

    fprintf(stderr, "response:");
    for (int i = 0; i < REPORT_SIZE; i++) {
        fprintf(stderr, " %02x", response[i]);
    }
    fprintf(stderr, "\n");
}

static int read_response(PixyHid *pixy, uint8_t *response, int timeout_ms) {
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + ((double)timeout_ms / 1000.0);
    while (!pixy->has_pending_response) {
        CFAbsoluteTime remaining = deadline - CFAbsoluteTimeGetCurrent();
        if (remaining <= 0.0) {
            return 0;
        }
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, remaining, true);
    }

    memset(response, 0, REPORT_SIZE);
    CFIndex copy_length = pixy->pending_length > REPORT_SIZE ? REPORT_SIZE : pixy->pending_length;
    memcpy(response, pixy->pending_response, (size_t)copy_length);
    pixy->has_pending_response = 0;
    pixy->pending_length = 0;
    memset(pixy->pending_response, 0, sizeof(pixy->pending_response));
    return (int)copy_length;
}

static int write_report(PixyHid *pixy, const uint8_t *frame, size_t frame_length) {
    pixy->has_pending_response = 0;
    pixy->pending_length = 0;
    memset(pixy->pending_response, 0, sizeof(pixy->pending_response));

    IOReturn result = IOHIDDeviceSetReport(
        pixy->device,
        kIOHIDReportTypeOutput,
        frame[0],
        frame,
        frame_length);

    if (result == kIOReturnUnsupported || result == kIOReturnBadArgument) {
        result = IOHIDDeviceSetReport(
            pixy->device,
            kIOHIDReportTypeFeature,
            frame[0],
            frame,
            frame_length);
    }

    if (result != kIOReturnSuccess) {
        fprintf(stderr, "HID write failed: 0x%08x\n", result);
        fprintf(stderr, "If another camera app is actively using the PIXY HID controls, close it and try again.\n");
        return 1;
    }

    return 0;
}

static int send_frame(PixyHid *pixy, const uint8_t header[4], const uint8_t *payload, uint16_t payload_length, int wait_for_response, uint8_t *response) {
    uint8_t frame[REPORT_SIZE];
    memset(frame, 0, sizeof(frame));
    memcpy(frame, header, 4);
    frame[4] = 0;
    frame[5] = (uint8_t)(payload_length & 0xff);
    frame[6] = (uint8_t)((payload_length >> 8) & 0xff);
    frame[7] = payload_length > PAYLOAD_PER_REPORT ? PAYLOAD_PER_REPORT : (uint8_t)payload_length;

    if (payload_length > 0 && payload != NULL) {
        memcpy(frame + 8, payload, frame[7]);
    }

    if (write_report(pixy, frame, sizeof(frame)) != 0) {
        return 1;
    }

    if (wait_for_response && response != NULL) {
        int matched = 0;
        for (int attempt = 0; attempt < 4; attempt++) {
            int read_count = read_response(pixy, response, attempt == 0 ? 350 : 150);
            if (read_count <= 0) {
                if (attempt == 0) {
                    fprintf(stderr, "Command was written, but no response arrived before timeout.\n");
                }
                break;
            }
            debug_dump_response(response);
            if (response[0] == header[0] &&
                (response[1] & 0x1f) == header[1] &&
                response[2] == header[2] &&
                response[3] == header[3]) {
                matched = 1;
                break;
            }
        }
        if (!matched && getenv("PIXYCTL_DEBUG") != NULL) {
            fprintf(stderr, "No matching response header arrived for %02x %02x %02x %02x.\n",
                    header[0], header[1], header[2], header[3]);
        }
    }

    return 0;
}

static int command_status(void) {
    PixyHid pixy;
    int open_result = open_pixy(&pixy);
    if (open_result != 0) {
        return open_result;
    }

    printf("EMEET PIXY connected via macOS IOKit HID\n");
    close_pixy(&pixy);
    return 0;
}

static int command_list(void) {
    IOHIDManagerRef manager = create_open_manager();
    if (manager == NULL) {
        return 2;
    }

    CFSetRef devices = IOHIDManagerCopyDevices(manager);
    if (devices == NULL || CFSetGetCount(devices) == 0) {
        fprintf(stderr, "No EMEET PIXY HID interfaces were found.\n");
        if (devices != NULL) {
            CFRelease(devices);
        }
        IOHIDManagerClose(manager, kIOHIDOptionsTypeNone);
        CFRelease(manager);
        return 2;
    }

    CFIndex count = CFSetGetCount(devices);
    IOHIDDeviceRef *values = calloc((size_t)count, sizeof(*values));
    if (values == NULL) {
        fprintf(stderr, "Could not allocate HID device list.\n");
        CFRelease(devices);
        IOHIDManagerClose(manager, kIOHIDOptionsTypeNone);
        CFRelease(manager);
        return 2;
    }

    CFSetGetValues(devices, (const void **)values);
    for (CFIndex i = 0; i < count; i++) {
        IOHIDDeviceRef device = values[i];
        char manufacturer[256];
        char product[256];
        char serial[256];
        string_property(device, CFSTR("Manufacturer"), manufacturer, sizeof(manufacturer));
        string_property(device, CFSTR("Product"), product, sizeof(product));
        string_property(device, CFSTR("SerialNumber"), serial, sizeof(serial));

        printf("[%ld] interface usage_page: 0x%04x usage: 0x%04x release: 0x%04x input: %d output: %d\n",
               (long)i,
               int_property(device, CFSTR("PrimaryUsagePage"), 0),
               int_property(device, CFSTR("PrimaryUsage"), 0),
               int_property(device, CFSTR("VersionNumber"), 0),
               int_property(device, CFSTR("MaxInputReportSize"), 0),
               int_property(device, CFSTR("MaxOutputReportSize"), 0));
        printf("    manufacturer: %s\n", manufacturer);
        printf("    product: %s\n", product);
        printf("    serial: %s\n", serial);
    }

    free(values);
    CFRelease(devices);
    IOHIDManagerClose(manager, kIOHIDOptionsTypeNone);
    CFRelease(manager);
    return 0;
}

static int command_get_mode(void) {
    PixyHid pixy;
    int open_result = open_pixy(&pixy);
    if (open_result != 0) {
        return open_result;
    }

    uint8_t response[REPORT_SIZE];
    int result = send_frame(&pixy, HEAD_GET_MODE, NULL, 0, 1, response);
    if (result == 0 && response[0] == 0x09 && (response[1] & 0x1f) == 0x01 && response[2] == 0x01 && response[3] == 0x01) {
        uint8_t mode = response[8];
        printf("Mode: %s\n", mode_name(mode));
    } else if (result == 0) {
        printf("Mode request sent.\n");
    }

    close_pixy(&pixy);
    return result;
}

static int command_get_track(void) {
    PixyHid pixy;
    int open_result = open_pixy(&pixy);
    if (open_result != 0) {
        return open_result;
    }

    uint8_t response[REPORT_SIZE];
    int result = send_frame(&pixy, HEAD_GET_TARGET_TRACK, NULL, 0, 1, response);
    if (result == 0 && response[0] == 0x09 && (response[1] & 0x1f) == 0x04 && response[2] == 0x01 && response[3] == 0x01) {
        uint8_t track_mode = response[8];
        if (track_mode != 0) {
            printf("Target tracking: on (%u) %.3f %.3f %.3f\n",
                   track_mode,
                   get_float_le(response + 9),
                   get_float_le(response + 13),
                   get_float_le(response + 17));
        } else {
            printf("Target tracking: off (0)\n");
        }
    } else if (result == 0) {
        printf("Target tracking request sent.\n");
    }

    close_pixy(&pixy);
    return result;
}

static int parse_mode(const char *arg, uint8_t *mode) {
    if (strcmp(arg, "normal") == 0 || strcmp(arg, "on") == 0 || strcmp(arg, "manual") == 0) {
        *mode = 0;
        return 0;
    }
    if (strcmp(arg, "tracking") == 0 || strcmp(arg, "track") == 0 || strcmp(arg, "ai") == 0) {
        *mode = 1;
        return 0;
    }
    if (strcmp(arg, "privacy") == 0 || strcmp(arg, "off") == 0) {
        *mode = 2;
        return 0;
    }

    char *end = NULL;
    errno = 0;
    long parsed = strtol(arg, &end, 0);
    if (errno == 0 && end != arg && *end == '\0' && parsed >= 0 && parsed <= 255) {
        *mode = (uint8_t)parsed;
        return 0;
    }

    return 1;
}

static int command_track(const char *arg);

static int command_mode(const char *arg) {
    uint8_t mode;
    if (parse_mode(arg, &mode) != 0) {
        fprintf(stderr, "Unknown mode: %s\\n", arg);
        return 1;
    }

    /*
     * PixyGuard Unified calls \"mode tracking\" from the Track control,
     * while PIXY keeps camera mode and AI target tracking as separate states.
     * Route the standard modes through command_track so both stay coherent.
     */
    if (mode == 1) {
        return command_track("on");
    }

    if (mode == 0) {
        return command_track("off");
    }

    if (mode == 2) {
        int track_result = command_track("off");
        if (track_result != 0) {
            return track_result;
        }
        /* command_track(\"off\") leaves PIXY normal; finish in privacy. */
    }

    PixyHid pixy;
    int open_result = open_pixy(&pixy);
    if (open_result != 0) {
        return open_result;
    }

    uint8_t response[REPORT_SIZE];
    int result = send_frame(&pixy, HEAD_SET_MODE, &mode, 1, 1, response);
    if (result == 0) {
        printf("Set PIXY mode: %s\\n", mode_name(mode));
    }

    close_pixy(&pixy);
    return result;
}

static int command_track(const char *arg) {
    uint8_t track_mode;
    if (strcmp(arg, "on") == 0 || strcmp(arg, "face") == 0 || strcmp(arg, "tracking") == 0) {
        track_mode = 1;
    } else if (strcmp(arg, "half") == 0 || strcmp(arg, "half-body") == 0) {
        track_mode = 2;
    } else if (strcmp(arg, "full") == 0 || strcmp(arg, "full-body") == 0) {
        track_mode = 3;
    } else if (strcmp(arg, "off") == 0 || strcmp(arg, "normal") == 0 || strcmp(arg, "manual") == 0) {
        track_mode = 0;
    } else {
        char *end = NULL;
        errno = 0;
        long parsed = strtol(arg, &end, 0);
        if (errno != 0 || end == arg || *end != '\0' || parsed < 0 || parsed > 255) {
            fprintf(stderr, "Unknown track state: %s\n", arg);
            return 1;
        }
        track_mode = (uint8_t)parsed;
    }

    PixyHid pixy;
    int open_result = open_pixy(&pixy);
    if (open_result != 0) {
        return open_result;
    }

    uint8_t response[REPORT_SIZE];
    uint8_t mode_payload = track_mode == 0 ? 0 : 1;
    int result = send_frame(&pixy, HEAD_SET_MODE, &mode_payload, 1, 1, response);
    if (result != 0) {
        close_pixy(&pixy);
        return result;
    }

    usleep(50000);

    uint8_t payload[13];
    payload[0] = track_mode;
    put_float_le(payload + 1, 0.5f);
    put_float_le(payload + 5, 0.5f);
    put_float_le(payload + 9, 1.0f);

    result = send_frame(&pixy, HEAD_SET_TARGET_TRACK, payload, sizeof(payload), 1, response);
    if (result == 0) {
        if (response[0] == 0x09 && (response[1] & 0x1f) == 0x04 && response[2] == 0x01 && response[3] == 0x00) {
            printf("Set PIXY AI tracking: %s (%u), response code: %u\n",
                   track_name(track_mode), track_mode, response[8]);
        } else {
            printf("Set PIXY AI tracking: %s (%u)\n", track_name(track_mode), track_mode);
        }
    }

    close_pixy(&pixy);
    return result;
}

static int command_move(const char *direction, const char *amount_arg) {
    float amount = 3.0f;
    if (amount_arg != NULL) {
        char *end = NULL;
        errno = 0;
        float parsed = strtof(amount_arg, &end);
        if (errno != 0 || end == amount_arg || *end != '\0' || parsed <= 0.0f || parsed > 30.0f) {
            fprintf(stderr, "Move amount must be a number from 0 to 30 degrees.\n");
            return 1;
        }
        amount = parsed;
    }

    uint8_t motor_type = 0;
    float delta = amount;
    if (strcmp(direction, "left") == 0) {
        motor_type = 1;
        delta = -amount;
    } else if (strcmp(direction, "right") == 0) {
        motor_type = 1;
        delta = amount;
    } else if (strcmp(direction, "up") == 0) {
        motor_type = 2;
        delta = amount;
    } else if (strcmp(direction, "down") == 0) {
        motor_type = 2;
        delta = -amount;
    } else {
        fprintf(stderr, "Unknown direction: %s\n", direction);
        return 1;
    }

    PixyHid pixy;
    int open_result = open_pixy(&pixy);
    if (open_result != 0) {
        return open_result;
    }

    uint8_t mode_payload = 0;
    uint8_t response[REPORT_SIZE];
    int result = send_frame(&pixy, HEAD_SET_MODE, &mode_payload, 1, 1, response);
    if (result != 0) {
        close_pixy(&pixy);
        return result;
    }

    usleep(50000);

    uint8_t payload[5];
    payload[0] = motor_type;
    put_float_le(payload + 1, delta);
    result = send_frame(&pixy, HEAD_MOTOR_RELATIVE, payload, sizeof(payload), 1, response);
    if (result == 0) {
        printf("Moved PIXY %s by %.1f degrees\n", direction, amount);
    }

    close_pixy(&pixy);
    return result;
}

static int command_recenter(void) {
    PixyHid pixy;
    int open_result = open_pixy(&pixy);
    if (open_result != 0) {
        return open_result;
    }

    uint8_t response[REPORT_SIZE];
    uint8_t mode_payload = 0;
    int result = send_frame(&pixy, HEAD_SET_MODE, &mode_payload, 1, 1, response);
    if (result != 0) {
        close_pixy(&pixy);
        return result;
    }

    usleep(50000);

    uint8_t payload[5];
    payload[0] = 1;
    put_float_le(payload + 1, 0.0f);
    result = send_frame(&pixy, HEAD_MOTOR_ABSOLUTE, payload, sizeof(payload), 1, response);
    if (result != 0) {
        close_pixy(&pixy);
        return result;
    }

    usleep(20000);

    payload[0] = 2;
    put_float_le(payload + 1, 0.0f);
    result = send_frame(&pixy, HEAD_MOTOR_ABSOLUTE, payload, sizeof(payload), 1, response);
    if (result == 0) {
        printf("Recentered PIXY\n");
    }

    close_pixy(&pixy);
    return result;
}

static int parse_degrees(const char *arg, const char *name, float *out) {
    char *end = NULL;
    errno = 0;
    float parsed = strtof(arg, &end);
    if (errno != 0 || end == arg || *end != '\0' || parsed < -90.0f || parsed > 90.0f) {
        fprintf(stderr, "%s must be a number from -90 to 90 degrees.\n", name);
        return 1;
    }

    *out = parsed;
    return 0;
}

static int command_position(const char *pan_arg, const char *tilt_arg) {
    float pan;
    float tilt;
    if (parse_degrees(pan_arg, "Pan", &pan) != 0 || parse_degrees(tilt_arg, "Tilt", &tilt) != 0) {
        return 1;
    }

    PixyHid pixy;
    int open_result = open_pixy(&pixy);
    if (open_result != 0) {
        return open_result;
    }

    uint8_t response[REPORT_SIZE];
    uint8_t mode_payload = 0;
    int result = send_frame(&pixy, HEAD_SET_MODE, &mode_payload, 1, 1, response);
    if (result != 0) {
        close_pixy(&pixy);
        return result;
    }

    usleep(50000);

    uint8_t payload[5];
    payload[0] = 1;
    put_float_le(payload + 1, pan);
    result = send_frame(&pixy, HEAD_MOTOR_ABSOLUTE, payload, sizeof(payload), 1, response);
    if (result != 0) {
        close_pixy(&pixy);
        return result;
    }

    usleep(20000);

    payload[0] = 2;
    put_float_le(payload + 1, tilt);
    result = send_frame(&pixy, HEAD_MOTOR_ABSOLUTE, payload, sizeof(payload), 1, response);
    if (result == 0) {
        printf("Set PIXY position: pan %.1f, tilt %.1f degrees\n", pan, tilt);
    }

    close_pixy(&pixy);
    return result;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        usage(stderr);
        return 1;
    }

    if (strcmp(argv[1], "status") == 0) {
        return command_status();
    }

    if (strcmp(argv[1], "list") == 0) {
        return command_list();
    }

    if (strcmp(argv[1], "get-mode") == 0) {
        return command_get_mode();
    }

    if (strcmp(argv[1], "get-track") == 0) {
        return command_get_track();
    }

    if (strcmp(argv[1], "mode") == 0) {
        if (argc < 3) {
            usage(stderr);
            return 1;
        }
        return command_mode(argv[2]);
    }

    if (strcmp(argv[1], "track") == 0) {
        if (argc < 3) {
            usage(stderr);
            return 1;
        }
        return command_track(argv[2]);
    }

    if (strcmp(argv[1], "move") == 0) {
        if (argc < 3) {
            usage(stderr);
            return 1;
        }
        return command_move(argv[2], argc >= 4 ? argv[3] : NULL);
    }

    if (strcmp(argv[1], "recenter") == 0 || strcmp(argv[1], "center") == 0) {
        return command_recenter();
    }

    if (strcmp(argv[1], "position") == 0) {
        if (argc < 4) {
            usage(stderr);
            return 1;
        }
        return command_position(argv[2], argv[3]);
    }

    usage(stderr);
    return 1;
}
