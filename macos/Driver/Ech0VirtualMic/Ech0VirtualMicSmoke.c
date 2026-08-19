#include <CoreAudio/AudioServerPlugIn.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

extern void* Ech0VirtualMic_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID);

enum {
    kObjectID_Device = 3,
    kObjectID_InputStream = 4,
    kPCMWriteSelector = 'e0wr',
    kPCMBufferCapacity = 96000
};

static AudioServerPlugInDriverRef driver;
static AudioObjectPropertyAddress writer = {
    kPCMWriteSelector,
    kAudioObjectPropertyScopeGlobal,
    kAudioObjectPropertyElementMain
};
static int tests;
static int failures;

#define CHECK(condition) do { \
    if(!(condition)) { \
        printf("FAIL (%s:%d: %s)\n", __FILE__, __LINE__, #condition); \
        return false; \
    } \
} while(0)

static OSStatus writePCM(CFDataRef data)
{
    CFPropertyListRef property = data;
    return (*driver)->SetPropertyData(
        driver, kObjectID_Device, getpid(), &writer,
        0, NULL, sizeof(property), &property);
}

static OSStatus readPCM(UInt32 frames, Float32* output)
{
    AudioServerPlugInIOCycleInfo cycle = { 0 };
    return (*driver)->DoIOOperation(
        driver, kObjectID_Device, kObjectID_InputStream, 1,
        kAudioServerPlugInIOOperationReadInput,
        frames, &cycle, output, NULL);
}

static bool testInputOnlyTopology(void)
{
    AudioObjectPropertyAddress streams = {
        kAudioDevicePropertyStreams,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;

    CHECK((*driver)->GetPropertyDataSize(
        driver, kObjectID_Device, getpid(), &streams,
        0, NULL, &size) == noErr);
    CHECK(size == sizeof(AudioObjectID));

    streams.mScope = kAudioObjectPropertyScopeOutput;
    CHECK((*driver)->GetPropertyDataSize(
        driver, kObjectID_Device, getpid(), &streams,
        0, NULL, &size) == noErr);
    CHECK(size == 0);
    return true;
}

static bool testPCMHandoff(void)
{
    const int16_t samples[] = { 0, 16384, -16384 };
    CFDataRef data = CFDataCreate(
        kCFAllocatorDefault, (const UInt8*)samples, sizeof(samples));
    Float32 output[6];

    CHECK(data != NULL);
    OSStatus writeStatus = writePCM(data);
    OSStatus readStatus = readPCM(3, output);
    CFRelease(data);

    CHECK(writeStatus == noErr);
    CHECK(readStatus == noErr);
    CHECK(output[0] == 0.0f && output[1] == 0.0f);
    CHECK(fabsf(output[2] - 0.5f) < 0.0001f && output[2] == output[3]);
    CHECK(fabsf(output[4] + 0.5f) < 0.0001f && output[4] == output[5]);
    return true;
}

static bool testClearProducesSilence(void)
{
    const int16_t samples[] = { 123, 456, 789 };
    CFDataRef data = CFDataCreate(
        kCFAllocatorDefault, (const UInt8*)samples, sizeof(samples));
    CFDataRef empty = CFDataCreate(kCFAllocatorDefault, NULL, 0);
    Float32 output[6] = { 1, 1, 1, 1, 1, 1 };

    if(data == NULL || empty == NULL)
    {
        if(data != NULL) CFRelease(data);
        if(empty != NULL) CFRelease(empty);
        CHECK(false);
    }
    OSStatus writeStatus = writePCM(data);
    OSStatus clearStatus = writePCM(empty);
    OSStatus readStatus = readPCM(3, output);

    CFRelease(empty);
    CFRelease(data);

    CHECK(writeStatus == noErr);
    CHECK(clearStatus == noErr);
    CHECK(readStatus == noErr);
    for(size_t i = 0; i < 6; i++) CHECK(output[i] == 0.0f);
    return true;
}

static bool testOverflowDropsOldestSamples(void)
{
    int16_t* samples = malloc(kPCMBufferCapacity * sizeof(*samples));
    const int16_t tail[] = { 30000, 30001, 30002 };
    CFDataRef full;
    CFDataRef extra;
    CFDataRef empty;
    Float32 output[2];

    CHECK(samples != NULL);
    for(size_t i = 0; i < kPCMBufferCapacity; i++)
        samples[i] = (int16_t)((i % 20001) - 10000);

    full = CFDataCreate(kCFAllocatorDefault, (const UInt8*)samples,
                        kPCMBufferCapacity * sizeof(*samples));
    extra = CFDataCreate(kCFAllocatorDefault, (const UInt8*)tail, sizeof(tail));
    empty = CFDataCreate(kCFAllocatorDefault, NULL, 0);
    free(samples);

    if(full == NULL || extra == NULL || empty == NULL)
    {
        if(full != NULL) CFRelease(full);
        if(extra != NULL) CFRelease(extra);
        if(empty != NULL) CFRelease(empty);
        CHECK(false);
    }
    OSStatus clearStatus = writePCM(empty);
    OSStatus fullStatus = writePCM(full);
    OSStatus extraStatus = writePCM(extra);
    OSStatus readStatus = readPCM(1, output);

    CFRelease(empty);
    CFRelease(extra);
    CFRelease(full);

    CHECK(clearStatus == noErr);
    CHECK(fullStatus == noErr);
    CHECK(extraStatus == noErr);
    CHECK(readStatus == noErr);
    CHECK(output[0] == (Float32)-9997 / 32768.0f);
    CHECK(output[0] == output[1]);
    return true;
}

static bool testDeviceIsFixedAt48kHz(void)
{
    AudioObjectPropertyAddress available = {
        kAudioDevicePropertyAvailableNominalSampleRates,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioObjectPropertyAddress nominal = {
        kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioValueRange range = { 0 };
    Float64 unsupported = 44100.0;
    Boolean settable = true;
    UInt32 size = 0;

    CHECK((*driver)->GetPropertyDataSize(
        driver, kObjectID_Device, getpid(), &available,
        0, NULL, &size) == noErr);
    CHECK(size == sizeof(range));
    CHECK((*driver)->GetPropertyData(
        driver, kObjectID_Device, getpid(), &available,
        0, NULL, sizeof(range), &size, &range) == noErr);
    CHECK(range.mMinimum == 48000.0 && range.mMaximum == 48000.0);
    CHECK((*driver)->IsPropertySettable(
        driver, kObjectID_Device, getpid(), &nominal, &settable) == noErr);
    CHECK(!settable);
    CHECK((*driver)->SetPropertyData(
        driver, kObjectID_Device, getpid(), &nominal,
        0, NULL, sizeof(unsupported), &unsupported) != noErr);
    return true;
}

static bool testStreamIsFixedAt48kHz(void)
{
    AudioObjectPropertyAddress available = {
        kAudioStreamPropertyAvailablePhysicalFormats,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioObjectPropertyAddress physical = {
        kAudioStreamPropertyPhysicalFormat,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioStreamRangedDescription format = { 0 };
    Boolean settable = true;
    UInt32 size = 0;

    CHECK((*driver)->GetPropertyDataSize(
        driver, kObjectID_InputStream, getpid(), &available,
        0, NULL, &size) == noErr);
    CHECK(size == sizeof(format));
    CHECK((*driver)->GetPropertyData(
        driver, kObjectID_InputStream, getpid(), &available,
        0, NULL, sizeof(format), &size, &format) == noErr);
    CHECK(format.mFormat.mSampleRate == 48000.0);
    CHECK(format.mSampleRateRange.mMinimum == 48000.0);
    CHECK(format.mSampleRateRange.mMaximum == 48000.0);
    CHECK((*driver)->IsPropertySettable(
        driver, kObjectID_InputStream, getpid(), &physical, &settable) == noErr);
    CHECK(!settable);

    format.mFormat.mSampleRate = 44100.0;
    CHECK((*driver)->SetPropertyData(
        driver, kObjectID_InputStream, getpid(), &physical,
        0, NULL, sizeof(format.mFormat), &format.mFormat) != noErr);
    return true;
}

static void runTest(const char* name, bool (*test)(void))
{
    tests++;
    printf("  %-48s ", name);
    fflush(stdout);
    if(test())
    {
        printf("OK\n");
    }
    else
    {
        failures++;
    }
}

int main(void)
{
    driver = (AudioServerPlugInDriverRef)Ech0VirtualMic_Create(
        kCFAllocatorDefault, kAudioServerPlugInTypeUUID);
    if(driver == NULL)
    {
        fprintf(stderr, "Driver factory failed.\n");
        return 1;
    }

    printf("Ech0VirtualMic:\n");
    runTest("device exposes one input stream", testInputOnlyTopology);
    runTest("PCM16 is converted to stereo Float32", testPCMHandoff);
    runTest("clearing the ring produces silence", testClearProducesSilence);
    runTest("overflow drops the oldest samples", testOverflowDropsOldestSamples);
    runTest("device sample rate is fixed at 48 kHz", testDeviceIsFixedAt48kHz);
    runTest("stream format is fixed at 48 kHz", testStreamIsFixedAt48kHz);

    printf("%d tests, %d failures\n", tests, failures);
    return failures != 0;
}
