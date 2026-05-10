#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDDevice.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <IOKit/hid/IOHIDManager.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void usage(const char *argv0) {
    fprintf(stderr,
        "Usage:\n"
        "  %s --list\n"
        "  %s --vidpid 046D:B034 --usage-page 0xff43 --usage 0x0202 --send 0x11,...\n"
        "\n"
        "Options:\n"
        "  --list                  List HID devices.\n"
        "  --vidpid VID:PID         Hex vendor/product id.\n"
        "  --usage-page VALUE       Hex or decimal usage page.\n"
        "  --usage VALUE            Hex or decimal usage.\n"
        "  --product TEXT           Product substring filter.\n"
        "  --send BYTES             Comma-separated bytes, including report id.\n"
        "  --recv [MS]              Accepted for compatibility; ignored.\n",
        argv0, argv0);
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

    if (!have_vidpid || !send_text) {
        usage(argv[0]);
        free(device_list);
        CFRelease(devices);
        CFRelease(manager);
        return 2;
    }

    unsigned char bytes[256];
    size_t byte_count = sizeof(bytes);
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
