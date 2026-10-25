// Protocol regression tests: all IOKit report operations below are fakes.
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDDevice.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>

static IOHIDReportCallback callback;
static void *callback_context;
static uint8_t *queued_buffer;
static IOHIDReportCallback queued_callback;
static void *queued_context;
static unsigned char pending[20];
static int scenario, writes, changes;

enum { NORMAL, UNSUPPORTED, WRITE_ERROR, HIDPP1_ERROR, HIDPP2_ERROR, TIMEOUT };

static void fake_register(IOHIDDeviceRef d, uint8_t *b, CFIndex n,
                          IOHIDReportCallback cb, void *ctx) {
    (void)d; (void)n;
    if (cb) { queued_buffer = b; queued_callback = cb; queued_context = ctx; }
    callback = cb;
    callback_context = ctx;
}
static void fake_schedule(IOHIDDeviceRef d, CFRunLoopRef l, CFStringRef m) {
    (void)d; (void)l; (void)m;
}
static IOReturn fake_send(IOHIDDeviceRef d, IOHIDReportType t, CFIndex id,
                         const uint8_t *out, CFIndex n) {
    (void)d; (void)t; (void)id; (void)n;
    writes++;
    memset(pending, 0, sizeof(pending));
    memcpy(pending, out, 4);
    if (out[2] == 0) {
        // ROOT.getFeature: name=5, CHANGE_HOST=14, HOSTS_INFO=15.
        pending[4] = out[4] == 0 ? 5 : (out[5] == 0x14 ? 14 : 15);
        if (scenario == UNSUPPORTED) pending[4] = 0;
    } else if (out[2] == 5) {
        if (out[3] == 0x02) pending[4] = 11;
        else memcpy(pending + 4, "MX Master 4", 11);
    } else if (out[2] == 15) {
        pending[6] = 3; pending[7] = 1;
    } else if (out[2] == 14) {
        changes++;
        if (scenario == WRITE_ERROR) return kIOReturnError;
        if (scenario == HIDPP1_ERROR || scenario == HIDPP2_ERROR) {
            pending[2] = scenario == HIDPP1_ERROR ? 0x8f : 0xff;
            pending[3] = out[2]; pending[4] = out[3]; pending[5] = 2;
        }
    }
    return kIOReturnSuccess;
}
static SInt32 fake_run(CFStringRef m, CFTimeInterval seconds, Boolean once) {
    (void)m; (void)seconds; (void)once;
    if (callback && !(scenario == TIMEOUT && pending[2] == 14))
        callback(callback_context, kIOReturnSuccess, NULL, kIOHIDReportTypeInput,
                 pending[0], pending, sizeof(pending));
    return kCFRunLoopRunHandledSource;
}

#define IOHIDDeviceRegisterInputReportCallback fake_register
#define IOHIDDeviceScheduleWithRunLoop fake_schedule
#define IOHIDDeviceUnscheduleFromRunLoop fake_schedule
#define IOHIDDeviceSetReport fake_send
#define CFRunLoopRunInMode fake_run
#define main hid_send_cli_main
#include "../tools/hid-send-macos.c"
#undef main

static void reset(int mode) { scenario = mode; writes = changes = 0; }

int main(void) {
    reset(NORMAL);
    assert(receiver_info(NULL, 3, 5, "MX Master 4") == 0);
    assert(changes == 0);
    assert(check_device_name(NULL, 3, 5, "MX Master 3S") != 0);
    assert(changes == 0);
    reset(UNSUPPORTED);
    assert(receiver_change_host(NULL, 3, 0, 5) != 0);
    assert(writes == 1 && changes == 0);
    for (int mode = WRITE_ERROR; mode <= HIDPP2_ERROR; mode++) {
        reset(mode);
        assert(receiver_change_host(NULL, 3, 0, 5) != 0);
        assert(changes == 1);
    }
    reset(NORMAL);
    assert(receiver_change_host(NULL, 3, 0, 5) == 0);
    assert(changes == 1);
    reset(TIMEOUT);
    assert(receiver_change_host(NULL, 3, 0, 1) == 0);
    assert(changes == 1);
    // Emulate a queued report delivered after the request frame has returned.
    // ASan detects stack-use-after-return if callback storage is request-local.
    memcpy(queued_buffer, pending, sizeof(pending));
    queued_callback(queued_context, kIOReturnSuccess, NULL, kIOHIDReportTypeInput,
             pending[0], queued_buffer, sizeof(pending));
    unsigned int value;
    assert(!parse_int("-1", &value));
    assert(!parse_int("4294967296", &value));
    puts("PASS: names, read-only info, unsupported feature, write/errors, timeout, cleanup, numeric bounds");
    return 0;
}
