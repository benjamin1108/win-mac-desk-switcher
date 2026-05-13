#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDDevice.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <IOKit/hid/IOHIDManager.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static void usage(const char *argv0) {
    fprintf(stderr,
        "Usage:\n"
        "  %s --list\n"
        "  %s --vidpid 046D:B034 --usage-page 0xff43 --usage 0x0202 --send 0x11,...\n"
        "  %s --receiver-change-host --device 3 --target-host-index 0\n"
        "  %s --receiver-ping --device 3\n"
        "\n"
        "Options:\n"
        "  --list                  List HID devices.\n"
        "  --vidpid VID:PID         Hex vendor/product id.\n"
        "  --usage-page VALUE       Hex or decimal usage page.\n"
        "  --usage VALUE            Hex or decimal usage.\n"
        "  --product TEXT           Product substring filter.\n"
        "  --send BYTES             Comma-separated bytes, including report id.\n"
        "  --recv [MS]              Accepted for compatibility; ignored.\n"
        "  --receiver-change-host   Send Logitech receiver HID++ CHANGE_HOST.\n"
        "  --receiver-ping          Send a harmless Logitech receiver HID++ ping.\n"
        "  --device N               Receiver HID++ device/slot number.\n"
        "  --target-host-index N     Zero-based target host index.\n"
        "  --timeout-ms N           HID++ reply timeout. Default: 1500.\n",
        argv0, argv0, argv0, argv0);
}

static int parse_int(const char *text, unsigned int *value) {
    char *end = NULL;
    int base = 10;
    if (text[0] == '0' && (text[1] == 'x' || text[1] == 'X')) {
        base = 16;
    }
    unsigned long parsed = strtoul(text, &end, base);
    if (!text[0] || (end && *end)) {
        return 0;
    }
    *value = (unsigned int)parsed;
    return 1;
}

static int parse_vidpid(const char *text, unsigned short *vid, unsigned short *pid) {
    const char *colon = strchr(text, ':');
    if (!colon) return 0;
    char left[16];
    char right[16];
    size_t left_len = (size_t)(colon - text);
    if (left_len == 0 || left_len >= sizeof(left) || strlen(colon + 1) >= sizeof(right)) return 0;
    memcpy(left, text, left_len);
    left[left_len] = '\0';
    strcpy(right, colon + 1);
    char *end = NULL;
    unsigned long v = strtoul(left, &end, 16);
    if (!left[0] || (end && *end)) return 0;
    end = NULL;
    unsigned long p = strtoul(right, &end, 16);
    if (!right[0] || (end && *end)) return 0;
    *vid = (unsigned short)v;
    *pid = (unsigned short)p;
    return 1;
}

static int parse_bytes(char *text, unsigned char *bytes, size_t *length) {
    size_t count = 0;
    char *token = strtok(text, ",");
    while (token) {
        if (count >= *length) return 0;
        while (*token == ' ' || *token == '\t') token++;
        unsigned int value = 0;
        if (!parse_int(token, &value) || value > 0xff) return 0;
        bytes[count++] = (unsigned char)value;
        token = strtok(NULL, ",");
    }
    *length = count;
    return count > 0;
}

static long get_int_property(IOHIDDeviceRef device, CFStringRef key) {
    CFTypeRef value = IOHIDDeviceGetProperty(device, key);
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID()) return 0;
    long result = 0;
    CFNumberGetValue((CFNumberRef)value, kCFNumberLongType, &result);
    return result;
}

static void copy_string_property(IOHIDDeviceRef device, CFStringRef key, char *buffer, size_t buffer_len) {
    if (buffer_len == 0) return;
    buffer[0] = '\0';
    CFTypeRef value = IOHIDDeviceGetProperty(device, key);
    if (!value || CFGetTypeID(value) != CFStringGetTypeID()) return;
    if (!CFStringGetCString((CFStringRef)value, buffer, buffer_len, kCFStringEncodingUTF8)) {
        snprintf(buffer, buffer_len, "<unprintable>");
    }
}

static int product_matches(IOHIDDeviceRef device, const char *needle) {
    if (!needle || !needle[0]) return 1;
    char product[512];
    copy_string_property(device, CFSTR(kIOHIDProductKey), product, sizeof(product));
    return strstr(product, needle) != NULL;
}

static IOHIDManagerRef create_manager(void) {
    IOHIDManagerRef manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (!manager) return NULL;
    IOHIDManagerSetDeviceMatching(manager, NULL);
    IOReturn result = IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone);
    if (result != kIOReturnSuccess) {
        CFRelease(manager);
        return NULL;
    }
    return manager;
}

static void print_device(IOHIDDeviceRef device) {
    long vid = get_int_property(device, CFSTR(kIOHIDVendorIDKey));
    long pid = get_int_property(device, CFSTR(kIOHIDProductIDKey));
    long usage_page = get_int_property(device, CFSTR(kIOHIDPrimaryUsagePageKey));
    long usage = get_int_property(device, CFSTR(kIOHIDPrimaryUsageKey));
    char product[512];
    copy_string_property(device, CFSTR(kIOHIDProductKey), product, sizeof(product));
    printf("VID=%04lX PID=%04lX usagePage=0x%04lX usage=0x%04lX interface=-1 product=%s path=IOHIDDevice:%p\n",
        vid, pid, usage_page, usage, product, device);
}

struct hid_reply_context {
    unsigned char report[256];
    CFIndex report_len;
    int got_report;
};

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}

static void input_report_callback(void *context, IOReturn result, void *sender, IOHIDReportType type,
                                  uint32_t report_id, uint8_t *report, CFIndex report_length) {
    (void)result;
    (void)sender;
    (void)type;
    (void)report_id;
    struct hid_reply_context *ctx = (struct hid_reply_context *)context;
    if (!ctx || report_length <= 0) return;
    CFIndex copy_len = report_length;
    if (copy_len > (CFIndex)sizeof(ctx->report)) copy_len = (CFIndex)sizeof(ctx->report);
    memcpy(ctx->report, report, (size_t)copy_len);
    ctx->report_len = copy_len;
    ctx->got_report = 1;
    CFRunLoopStop(CFRunLoopGetCurrent());
}

static void print_hex_to(FILE *stream, const unsigned char *bytes, size_t length) {
    for (size_t i = 0; i < length; i++) {
        fprintf(stream, "%s%02X", i == 0 ? "" : " ", bytes[i]);
    }
}

static void print_hex(const unsigned char *bytes, size_t length) {
    print_hex_to(stdout, bytes, length);
}

static int send_hidpp_request(IOHIDDeviceRef device, const unsigned char *output, size_t output_len,
                              int reply_dev, int feature_index, int function_id, int timeout_ms,
                              unsigned char *reply, size_t *reply_len) {
    struct hid_reply_context ctx;
    unsigned char input_buffer[256];
    size_t reply_capacity = *reply_len;
    memset(&ctx, 0, sizeof(ctx));
    memset(input_buffer, 0, sizeof(input_buffer));
    *reply_len = 0;

    IOHIDDeviceRegisterInputReportCallback(device, input_buffer, (CFIndex)sizeof(input_buffer),
                                           input_report_callback, &ctx);
    IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);

    IOReturn send_result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, output[0], output, (CFIndex)output_len);
    if (send_result != kIOReturnSuccess) {
        IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        fprintf(stderr, "IOHIDDeviceSetReport failed: 0x%08X\n", send_result);
        return 0;
    }

    double deadline = now_ms() + (double)timeout_ms;
    while (now_ms() < deadline) {
        ctx.got_report = 0;
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
        if (!ctx.got_report) continue;
        if (ctx.report_len < 4) continue;
        if (ctx.report[0] != 0x10 && ctx.report[0] != 0x11) continue;
        if (ctx.report[1] != (unsigned char)reply_dev && ctx.report[1] != (unsigned char)(reply_dev ^ 0xFF)) continue;
        if (ctx.report[2] == (unsigned char)(feature_index & 0xFF) &&
            ctx.report[3] == (unsigned char)((function_id & 0xF0) | 0x02)) {
            size_t copy_len = (size_t)ctx.report_len;
            if (copy_len > reply_capacity) copy_len = reply_capacity;
            memcpy(reply, ctx.report, copy_len);
            *reply_len = copy_len;
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
            return 1;
        }
        if (ctx.report_len >= 6 && ctx.report[2] == 0x8F &&
            ctx.report[3] == (unsigned char)(feature_index & 0xFF) &&
            ctx.report[4] == (unsigned char)((function_id & 0xF0) | 0x02)) {
            size_t copy_len = (size_t)ctx.report_len;
            if (copy_len > reply_capacity) copy_len = reply_capacity;
            memcpy(reply, ctx.report, copy_len);
            *reply_len = copy_len;
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
            return 0;
        }
    }

    IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    return 0;
}

static int hidpp_feature_request(IOHIDDeviceRef device, int devnumber, int feature_index, int function_id,
                                 const unsigned char *params, size_t params_len, int timeout_ms,
                                 unsigned char *reply, size_t *reply_len) {
    unsigned char output[20];
    memset(output, 0, sizeof(output));
    output[0] = 0x11;
    output[1] = (unsigned char)devnumber;
    output[2] = (unsigned char)(feature_index & 0xFF);
    output[3] = (unsigned char)((function_id & 0xF0) | 0x02);
    if (params && params_len > 0) {
        if (params_len > sizeof(output) - 4) params_len = sizeof(output) - 4;
        memcpy(output + 4, params, params_len);
    }
    return send_hidpp_request(device, output, sizeof(output), devnumber, feature_index, function_id,
                              timeout_ms, reply, reply_len);
}

static int lookup_feature_index(IOHIDDeviceRef device, int devnumber, int feature_id, int timeout_ms) {
    unsigned char params[2] = {
        (unsigned char)((feature_id >> 8) & 0xFF),
        (unsigned char)(feature_id & 0xFF)
    };
    unsigned char reply[256];
    size_t reply_len = sizeof(reply);
    if (!hidpp_feature_request(device, devnumber, 0x00, 0x00, params, sizeof(params), timeout_ms, reply, &reply_len)) {
        fprintf(stderr, "Feature lookup 0x%04X failed or timed out for device %d", feature_id, devnumber);
        if (reply_len > 0) {
            fprintf(stderr, "; reply=");
            print_hex_to(stderr, reply, reply_len);
        }
        fprintf(stderr, "\n");
        return -1;
    }
    if (reply_len < 5) {
        fprintf(stderr, "Feature lookup 0x%04X returned short reply\n", feature_id);
        return -1;
    }
    return reply[4];
}

static int receiver_ping(IOHIDDeviceRef device, int devnumber, int timeout_ms) {
    unsigned char reply[256];
    size_t reply_len = sizeof(reply);
    unsigned char mark = (unsigned char)(time(NULL) & 0xFF);
    unsigned char output[7] = { 0x10, (unsigned char)devnumber, 0x00, 0x12, 0x00, 0x00, mark };
    int success = send_hidpp_request(device, output, sizeof(output), devnumber, 0x00, 0x10,
                                     timeout_ms, reply, &reply_len);
    if (success && reply_len >= 7 && reply[6] == mark) {
        printf("PING device=%d online HID++ %d.%d reply=", devnumber, reply[4], reply[5]);
        print_hex(reply, reply_len);
        printf("\n");
        return 0;
    }
    printf("PING device=%d failed", devnumber);
    if (reply_len > 0) {
        printf(" reply=");
        print_hex(reply, reply_len);
    }
    printf("\n");
    return 1;
}

static int receiver_change_host(IOHIDDeviceRef device, int devnumber, int target_host_index, int timeout_ms) {
    int feature_index = lookup_feature_index(device, devnumber, 0x1814, timeout_ms);
    if (feature_index < 0) return 1;

    unsigned char params[1] = { (unsigned char)target_host_index };
    unsigned char reply[256];
    size_t reply_len = sizeof(reply);
    int success = hidpp_feature_request(device, devnumber, feature_index, 0x10, params, sizeof(params),
                                        timeout_ms, reply, &reply_len);
    if (success) {
        printf("Sent CHANGE_HOST device=%d featureIndex=0x%02X targetHostIndex=%d physicalChannel=%d reply=",
               devnumber, feature_index, target_host_index, target_host_index + 1);
        print_hex(reply, reply_len);
        printf("\n");
        return 0;
    }

    printf("Sent CHANGE_HOST device=%d featureIndex=0x%02X targetHostIndex=%d physicalChannel=%d; no success reply",
           devnumber, feature_index, target_host_index, target_host_index + 1);
    if (reply_len > 0) {
        printf(" reply=");
        print_hex(reply, reply_len);
    }
    printf("\n");
    return 0;
}

int main(int argc, char **argv) {
    int list = 0;
    unsigned short vid = 0;
    unsigned short pid = 0;
    int have_vidpid = 0;
    unsigned int usage_page = 0;
    unsigned int usage_id = 0;
    int have_usage_page = 0;
    int have_usage = 0;
    const char *product_filter = NULL;
    char *send_text = NULL;
    int receiver_change_host_mode = 0;
    int receiver_ping_mode = 0;
    int receiver_device = -1;
    int target_host_index = -1;
    int timeout_ms = 1500;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--list") == 0) {
            list = 1;
        } else if (strcmp(argv[i], "--vidpid") == 0 && i + 1 < argc) {
            if (!parse_vidpid(argv[++i], &vid, &pid)) {
                fprintf(stderr, "Invalid --vidpid\n");
                return 2;
            }
            have_vidpid = 1;
        } else if (strcmp(argv[i], "--usage-page") == 0 && i + 1 < argc) {
            if (!parse_int(argv[++i], &usage_page)) {
                fprintf(stderr, "Invalid --usage-page\n");
                return 2;
            }
            have_usage_page = 1;
        } else if (strcmp(argv[i], "--usage") == 0 && i + 1 < argc) {
            if (!parse_int(argv[++i], &usage_id)) {
                fprintf(stderr, "Invalid --usage\n");
                return 2;
            }
            have_usage = 1;
        } else if (strcmp(argv[i], "--product") == 0 && i + 1 < argc) {
            product_filter = argv[++i];
        } else if (strcmp(argv[i], "--send") == 0 && i + 1 < argc) {
            send_text = argv[++i];
        } else if (strcmp(argv[i], "--recv") == 0) {
            if (i + 1 < argc && argv[i + 1][0] != '-') i++;
        } else if (strcmp(argv[i], "--receiver-change-host") == 0) {
            receiver_change_host_mode = 1;
            if (!have_vidpid) {
                vid = 0x046D;
                pid = 0xC548;
                have_vidpid = 1;
            }
            if (!have_usage_page) {
                usage_page = 0xFF00;
                have_usage_page = 1;
            }
            if (!product_filter) {
                product_filter = "USB Receiver";
            }
        } else if (strcmp(argv[i], "--receiver-ping") == 0) {
            receiver_ping_mode = 1;
            if (!have_vidpid) {
                vid = 0x046D;
                pid = 0xC548;
                have_vidpid = 1;
            }
            if (!have_usage_page) {
                usage_page = 0xFF00;
                have_usage_page = 1;
            }
            if (!product_filter) {
                product_filter = "USB Receiver";
            }
        } else if (strcmp(argv[i], "--device") == 0 && i + 1 < argc) {
            unsigned int value = 0;
            if (!parse_int(argv[++i], &value)) {
                fprintf(stderr, "Invalid --device\n");
                return 2;
            }
            receiver_device = (int)value;
        } else if (strcmp(argv[i], "--target-host-index") == 0 && i + 1 < argc) {
            unsigned int value = 0;
            if (!parse_int(argv[++i], &value)) {
                fprintf(stderr, "Invalid --target-host-index\n");
                return 2;
            }
            target_host_index = (int)value;
        } else if (strcmp(argv[i], "--timeout-ms") == 0 && i + 1 < argc) {
            unsigned int value = 0;
            if (!parse_int(argv[++i], &value)) {
                fprintf(stderr, "Invalid --timeout-ms\n");
                return 2;
            }
            timeout_ms = (int)value;
        } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            usage(argv[0]);
            return 0;
        } else {
            usage(argv[0]);
            return 2;
        }
    }

    IOHIDManagerRef manager = create_manager();
    if (!manager) {
        fprintf(stderr, "IOHIDManagerOpen failed\n");
        return 1;
    }

    CFSetRef devices = IOHIDManagerCopyDevices(manager);
    if (!devices) {
        fprintf(stderr, "No HID devices found\n");
        CFRelease(manager);
        return 1;
    }

    CFIndex count = CFSetGetCount(devices);
    IOHIDDeviceRef *device_list = calloc((size_t)count, sizeof(IOHIDDeviceRef));
    if (!device_list) {
        CFRelease(devices);
        CFRelease(manager);
        return 1;
    }
    CFSetGetValues(devices, (const void **)device_list);

    if (list) {
        for (CFIndex i = 0; i < count; i++) {
            print_device(device_list[i]);
        }
        free(device_list);
        CFRelease(devices);
        CFRelease(manager);
        return 0;
    }

    if (receiver_change_host_mode || receiver_ping_mode) {
        if (receiver_device < 0 || (receiver_change_host_mode && (target_host_index < 0 || target_host_index > 2))) {
            usage(argv[0]);
            free(device_list);
            CFRelease(devices);
            CFRelease(manager);
            return 2;
        }
    } else if (!have_vidpid || !send_text) {
        usage(argv[0]);
        free(device_list);
        CFRelease(devices);
        CFRelease(manager);
        return 2;
    }

    unsigned char bytes[256];
    size_t byte_count = 0;
    if (!receiver_change_host_mode && !receiver_ping_mode) {
        byte_count = sizeof(bytes);
        char *send_copy = strdup(send_text);
        if (!send_copy || !parse_bytes(send_copy, bytes, &byte_count)) {
            fprintf(stderr, "Invalid --send bytes\n");
            free(send_copy);
            free(device_list);
            CFRelease(devices);
            CFRelease(manager);
            return 2;
        }
        free(send_copy);
    }

    IOHIDDeviceRef match = NULL;
    for (CFIndex i = 0; i < count; i++) {
        IOHIDDeviceRef device = device_list[i];
        if ((unsigned short)get_int_property(device, CFSTR(kIOHIDVendorIDKey)) != vid) continue;
        if ((unsigned short)get_int_property(device, CFSTR(kIOHIDProductIDKey)) != pid) continue;
        if (have_usage_page && (unsigned int)get_int_property(device, CFSTR(kIOHIDPrimaryUsagePageKey)) != usage_page) continue;
        if (have_usage && (unsigned int)get_int_property(device, CFSTR(kIOHIDPrimaryUsageKey)) != usage_id) continue;
        if (!product_matches(device, product_filter)) continue;
        match = device;
        break;
    }

    if (!match && (have_usage_page || have_usage)) {
        for (CFIndex i = 0; i < count; i++) {
            IOHIDDeviceRef device = device_list[i];
            if ((unsigned short)get_int_property(device, CFSTR(kIOHIDVendorIDKey)) != vid) continue;
            if ((unsigned short)get_int_property(device, CFSTR(kIOHIDProductIDKey)) != pid) continue;
            if (!product_matches(device, product_filter)) continue;
            match = device;
            break;
        }
    }

    if (!match) {
        fprintf(stderr, "No matching HID device found\n");
        free(device_list);
        CFRelease(devices);
        CFRelease(manager);
        return 1;
    }

    printf("Opening ");
    print_device(match);

    IOReturn open_result = IOHIDDeviceOpen(match, kIOHIDOptionsTypeNone);
    if (open_result != kIOReturnSuccess) {
        fprintf(stderr, "IOHIDDeviceOpen failed: 0x%08X\n", open_result);
        free(device_list);
        CFRelease(devices);
        CFRelease(manager);
        return 1;
    }

    if (receiver_ping_mode) {
        int result = receiver_ping(match, receiver_device, timeout_ms);
        IOHIDDeviceClose(match, kIOHIDOptionsTypeNone);
        free(device_list);
        CFRelease(devices);
        CFRelease(manager);
        return result;
    }

    if (receiver_change_host_mode) {
        int result = receiver_change_host(match, receiver_device, target_host_index, timeout_ms);
        IOHIDDeviceClose(match, kIOHIDOptionsTypeNone);
        free(device_list);
        CFRelease(devices);
        CFRelease(manager);
        return result;
    }

    CFIndex report_len = (CFIndex)byte_count;
    IOReturn send_result = IOHIDDeviceSetReport(match, kIOHIDReportTypeOutput, bytes[0], bytes, report_len);
    IOHIDDeviceClose(match, kIOHIDOptionsTypeNone);

    if (send_result != kIOReturnSuccess) {
        fprintf(stderr, "IOHIDDeviceSetReport failed: 0x%08X\n", send_result);
        free(device_list);
        CFRelease(devices);
        CFRelease(manager);
        return 1;
    }

    printf("Wrote %zu bytes\n", byte_count);

    free(device_list);
    CFRelease(devices);
    CFRelease(manager);
    return 0;
}
