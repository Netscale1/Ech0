#include <CoreAudio/AudioServerPlugIn.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>

extern void* Ech0VirtualMic_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID);

enum {
    kObjectID_Device = 3,
    kObjectID_InputStream = 4,
    kPCMWriteSelector = 'e0wr'
};

static int check(bool condition, const char* message)
{
    if(!condition)
    {
        fprintf(stderr, "FAILED: %s\n", message);
        return 0;
    }
    return 1;
}

int main(void)
{
    AudioServerPlugInDriverRef driver =
        (AudioServerPlugInDriverRef)Ech0VirtualMic_Create(
            kCFAllocatorDefault,
            kAudioServerPlugInTypeUUID);
    if(!check(driver != NULL, "factory did not return a driver"))
    {
        return 1;
    }

    AudioObjectPropertyAddress streams = {
        kAudioDevicePropertyStreams,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    OSStatus status = (*driver)->GetPropertyDataSize(
        driver, kObjectID_Device, getpid(), &streams, 0, NULL, &size);
    if(!check(status == noErr && size == sizeof(AudioObjectID),
              "global stream list must contain exactly one stream"))
    {
        return 1;
    }

    streams.mScope = kAudioObjectPropertyScopeOutput;
    status = (*driver)->GetPropertyDataSize(
        driver, kObjectID_Device, getpid(), &streams, 0, NULL, &size);
    if(!check(status == noErr && size == 0,
              "output stream list must be empty"))
    {
        return 1;
    }

    AudioObjectPropertyAddress writer = {
        kPCMWriteSelector,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    Boolean settable = false;
    status = (*driver)->IsPropertySettable(
        driver, kObjectID_Device, getpid(), &writer, &settable);
    if(!check(status == noErr && settable,
              "PCM writer property must be settable"))
    {
        return 1;
    }

    const int16_t samples[] = { 0, 16384, -16384 };
    CFDataRef sampleData = CFDataCreate(
        kCFAllocatorDefault,
        (const UInt8*)samples,
        sizeof(samples));
    CFPropertyListRef sampleProperty = sampleData;
    AudioServerPlugInIOCycleInfo cycle = { 0 };
    status = (*driver)->SetPropertyData(
        driver,
        kObjectID_Device,
        getpid(),
        &writer,
        0,
        NULL,
        sizeof(sampleProperty),
        &sampleProperty);
    if(!check(status == noErr, "PCM samples were rejected"))
    {
        return 1;
    }

    Float32 output[6] = { 9, 9, 9, 9, 9, 9 };
    status = (*driver)->DoIOOperation(
        driver,
        kObjectID_Device,
        kObjectID_InputStream,
        1,
        kAudioServerPlugInIOOperationReadInput,
        3,
        &cycle,
        output,
        NULL);
    if(!check(status == noErr, "input read failed") ||
       !check(output[0] == 0.0f && output[1] == 0.0f,
              "zero sample was not duplicated") ||
       !check(fabsf(output[2] - 0.5f) < 0.0001f && fabsf(output[3] - 0.5f) < 0.0001f,
              "positive sample was not converted") ||
       !check(fabsf(output[4] + 0.5f) < 0.0001f && fabsf(output[5] + 0.5f) < 0.0001f,
              "negative sample was not converted"))
    {
        return 1;
    }

    CFDataRef emptyData = CFDataCreate(kCFAllocatorDefault, NULL, 0);
    CFPropertyListRef emptyProperty = emptyData;
    status = (*driver)->SetPropertyData(
        driver,
        kObjectID_Device,
        getpid(),
        &writer,
        0,
        NULL,
        sizeof(emptyProperty),
        &emptyProperty);
    if(!check(status == noErr, "ring reset failed"))
    {
        return 1;
    }

    for(size_t index = 0; index < 6; ++index)
    {
        output[index] = 9.0f;
    }
    status = (*driver)->DoIOOperation(
        driver,
        kObjectID_Device,
        kObjectID_InputStream,
        1,
        kAudioServerPlugInIOOperationReadInput,
        3,
        &cycle,
        output,
        NULL);
    if(!check(status == noErr, "input read after reset failed"))
    {
        return 1;
    }
    for(size_t index = 0; index < 6; ++index)
    {
        if(!check(output[index] == 0.0f, "reset input must produce silence"))
        {
            return 1;
        }
    }

    printf("Ech0VirtualMic smoke test passed: input-only stream and PCM handoff verified.\n");
    CFRelease(emptyData);
    CFRelease(sampleData);
    return 0;
}
