#include <CoreAudio/AudioServerPlugIn.h>
#include <math.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

extern void* Ech0VirtualMic_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID);

enum {
    kObjectID_Device = 3,
    kObjectID_InputStream = 4,
    kPCMWriteSelector = 'e0wr',
    kPCMBufferCapacity = 96000,
    kReadFrames = 256,
    kWriteIterations = 256
};

typedef struct {
    AudioServerPlugInDriverRef driver;
    CFDataRef samples;
    CFDataRef empty;
    atomic_bool start;
    atomic_bool failed;
} Race;

static OSStatus writePCM(Race* race, CFDataRef data)
{
    AudioObjectPropertyAddress writer = {
        kPCMWriteSelector,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    CFPropertyListRef property = data;
    return (*race->driver)->SetPropertyData(
        race->driver, kObjectID_Device, getpid(), &writer,
        0, NULL, sizeof(property), &property);
}

static void waitForStart(Race* race)
{
    while(!atomic_load_explicit(&race->start, memory_order_acquire))
        sched_yield();
}

static void* writeThread(void* argument)
{
    Race* race = argument;
    waitForStart(race);

    for(size_t i = 0; i < kWriteIterations; i++)
    {
        CFDataRef data = (i % 7 == 0) ? race->empty : race->samples;
        if(writePCM(race, data) != noErr)
        {
            atomic_store_explicit(&race->failed, true, memory_order_release);
            break;
        }
    }
    return NULL;
}

static void* readThread(void* argument)
{
    Race* race = argument;
    AudioServerPlugInIOCycleInfo cycle = { 0 };
    Float32 output[kReadFrames * 2];
    waitForStart(race);

    for(size_t iteration = 0; iteration < kWriteIterations * 4; iteration++)
    {
        OSStatus status = (*race->driver)->DoIOOperation(
            race->driver, kObjectID_Device, kObjectID_InputStream, 1,
            kAudioServerPlugInIOOperationReadInput,
            kReadFrames, &cycle, output, NULL);
        if(status != noErr)
        {
            atomic_store_explicit(&race->failed, true, memory_order_release);
            break;
        }
        for(size_t frame = 0; frame < kReadFrames; frame++)
        {
            Float32 left = output[frame * 2];
            Float32 right = output[frame * 2 + 1];
            if(!isfinite(left) || left < -1.0f || left > 1.0f || left != right)
            {
                atomic_store_explicit(&race->failed, true, memory_order_release);
                return NULL;
            }
        }
    }
    return NULL;
}

int main(void)
{
    Race race = { 0 };
    pthread_t writer;
    pthread_t reader;
    int16_t* samples = malloc(kPCMBufferCapacity * sizeof(*samples));

    if(samples == NULL)
    {
        fprintf(stderr, "Unable to allocate race-test samples.\n");
        return 1;
    }
    for(size_t i = 0; i < kPCMBufferCapacity; i++)
        samples[i] = (int16_t)((i % 20001) - 10000);

    race.driver = (AudioServerPlugInDriverRef)Ech0VirtualMic_Create(
        kCFAllocatorDefault, kAudioServerPlugInTypeUUID);
    race.samples = CFDataCreate(
        kCFAllocatorDefault, (const UInt8*)samples,
        kPCMBufferCapacity * sizeof(*samples));
    race.empty = CFDataCreate(kCFAllocatorDefault, NULL, 0);
    free(samples);
    atomic_init(&race.start, false);
    atomic_init(&race.failed, false);

    if(race.driver == NULL || race.samples == NULL || race.empty == NULL ||
       pthread_create(&writer, NULL, writeThread, &race) != 0 ||
       pthread_create(&reader, NULL, readThread, &race) != 0)
    {
        fprintf(stderr, "Unable to start PCM race test.\n");
        return 1;
    }

    atomic_store_explicit(&race.start, true, memory_order_release);
    pthread_join(writer, NULL);
    pthread_join(reader, NULL);

    CFRelease(race.empty);
    CFRelease(race.samples);
    if(atomic_load_explicit(&race.failed, memory_order_acquire))
    {
        fprintf(stderr, "Concurrent write, clear, and read broke the PCM contract.\n");
        return 1;
    }

    printf("PCM write, clear, and read race test passed.\n");
    return 0;
}
