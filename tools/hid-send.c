#include <hidapi/hidapi.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

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
        "  --recv [MS]              After send, read one input report (default 1000ms).\n",
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

static void print_wide(const wchar_t *text) {
    if (!text) {
        printf("");
        return;
    }
    char buffer[512];
    size_t written = wcstombs(buffer, text, sizeof(buffer) - 1);
    if (written == (size_t)-1) {
        printf("<unprintable>");
        return;
    }
    buffer[written] = '\0';
    printf("%s", buffer);
}

static int wide_contains_ascii(const wchar_t *haystack, const char *needle) {
    if (!needle || !needle[0]) return 1;
    if (!haystack) return 0;
    char buffer[512];
    size_t written = wcstombs(buffer, haystack, sizeof(buffer) - 1);
    if (written == (size_t)-1) return 0;
    buffer[written] = '\0';
    return strstr(buffer, needle) != NULL;
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
    int recv_enabled = 0;
    int recv_timeout_ms = 1000;

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
            recv_enabled = 1;
            if (i + 1 < argc && argv[i + 1][0] != '-') {
                unsigned int ms = 0;
                if (parse_int(argv[i + 1], &ms)) {
                    recv_timeout_ms = (int)ms;
                    i++;
                }
            }
        } else if (strcmp(argv[i], "-h") == 0 || strcmp(argv[i], "--help") == 0) {
            usage(argv[0]);
            return 0;
        } else {
            usage(argv[0]);
            return 2;
        }
    }

    if (hid_init() != 0) {
        fprintf(stderr, "hid_init failed\n");
        return 1;
    }

    if (list) {
        struct hid_device_info *devices = hid_enumerate(0, 0);
        for (struct hid_device_info *dev = devices; dev; dev = dev->next) {
            printf("VID=%04X PID=%04X usagePage=0x%04X usage=0x%04X interface=%d product=",
                dev->vendor_id, dev->product_id, dev->usage_page, dev->usage, dev->interface_number);
            print_wide(dev->product_string);
            printf(" path=%s\n", dev->path ? dev->path : "");
        }
        hid_free_enumeration(devices);
        hid_exit();
        return 0;
    }

    if (!have_vidpid || !send_text) {
        usage(argv[0]);
        hid_exit();
        return 2;
    }

    unsigned char bytes[256];
    size_t byte_count = sizeof(bytes);
    char *send_copy = strdup(send_text);
    if (!send_copy || !parse_bytes(send_copy, bytes, &byte_count)) {
        fprintf(stderr, "Invalid --send bytes\n");
        free(send_copy);
        hid_exit();
        return 2;
    }
    free(send_copy);

    struct hid_device_info *devices = hid_enumerate(vid, pid);
    struct hid_device_info *match = NULL;
    for (struct hid_device_info *dev = devices; dev; dev = dev->next) {
        if (have_usage_page && dev->usage_page != (unsigned short)usage_page) continue;
        if (have_usage && dev->usage != (unsigned short)usage_id) continue;
        if (!wide_contains_ascii(dev->product_string, product_filter)) continue;
        match = dev;
        break;
    }

    if (!match) {
        fprintf(stderr, "No matching HID device found\n");
        hid_free_enumeration(devices);
        hid_exit();
        return 1;
    }

    printf("Opening VID=%04X PID=%04X usagePage=0x%04X usage=0x%04X product=",
        match->vendor_id, match->product_id, match->usage_page, match->usage);
    print_wide(match->product_string);
    printf("\n");

    hid_device *handle = hid_open_path(match->path);
    if (!handle) {
        fprintf(stderr, "hid_open_path failed\n");
        fprintf(stderr, "On macOS, keyboard HID devices may require Input Monitoring permission for the terminal app running this command.\n");
        hid_free_enumeration(devices);
        hid_exit();
        return 1;
    }

    int written = hid_write(handle, bytes, byte_count);
    if (written < 0) {
        fwprintf(stderr, L"hid_write failed: %ls\n", hid_error(handle));
        hid_close(handle);
        hid_free_enumeration(devices);
        hid_exit();
        return 1;
    }

    printf("Wrote %d bytes\n", written);

    if (recv_enabled) {
        unsigned char reply[64];
        int got = hid_read_timeout(handle, reply, sizeof(reply), recv_timeout_ms);
        if (got < 0) {
            fwprintf(stderr, L"hid_read failed: %ls\n", hid_error(handle));
        } else if (got == 0) {
            printf("Recv timeout after %dms\n", recv_timeout_ms);
        } else {
            printf("Recv %d bytes:", got);
            for (int i = 0; i < got; i++) printf(" %02X", reply[i]);
            printf("\n");
        }
    }

    hid_close(handle);
    hid_free_enumeration(devices);
    hid_exit();
    return 0;
}
