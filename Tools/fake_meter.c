// Writes synthetic per-channel peak/rms/clip values plus plausible status
// values into the meter shared memory so the visualizer (including the
// Settings tab) can be tested without installing the HAL plugin. Also
// honors config writes from the app (requestedChannelCount) so the
// channel-count UI can be exercised without a real driver.
// Build: clang -o /tmp/fake_meter Tools/fake_meter.c
// Run:   /tmp/fake_meter [sine|sweep|clip]   (default: sweep)
#include "../Shared/MeterShm.h"
#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

typedef enum { MODE_SINE, MODE_SWEEP, MODE_CLIP } Mode;

int main(int argc, char **argv) {
    Mode mode = MODE_SWEEP;
    if (argc > 1) {
        if (strcmp(argv[1], "sine") == 0) mode = MODE_SINE;
        else if (strcmp(argv[1], "clip") == 0) mode = MODE_CLIP;
        else mode = MODE_SWEEP;
    }

    int fd = shm_open(VAI_SHM_NAME, O_CREAT | O_RDWR, 0666);
    if (fd < 0) { perror("shm_open"); return 1; }
    ftruncate(fd, sizeof(VAIMeterShm));
    VAIMeterShm *shm = mmap(NULL, sizeof(VAIMeterShm), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (shm == MAP_FAILED) { perror("mmap"); return 1; }
    memset(shm, 0, sizeof(*shm));
    shm->magic = VAI_SHM_MAGIC;
    shm->channelCount = VAI_MAX_CHANNELS;
    shm->sampleRate = 48000.0;
    shm->ioBufferFrameSize = 512;
    shm->isRunning = 1;
    shm->clientCount = 1;
    shm->zeroTimeStampPeriod = 16384;
    shm->hostRequestedSampleRate = 0.0;

    const float sweepPeak = 0.5f; // -6 dBFS
    for (double t = 0;; t += 0.01) {
        // Reflect app-requested channel count so the Settings UI has
        // something real to observe without a driver present.
        if (shm->requestedChannelCount >= 1 && shm->requestedChannelCount <= VAI_MAX_CHANNELS) {
            shm->channelCount = shm->requestedChannelCount;
        }
        if (shm->requestedSampleRate > 0) {
            shm->sampleRate = shm->requestedSampleRate;
        }
        shm->configAppliedCounter = shm->configCounter;

        uint32_t n = shm->channelCount;
        switch (mode) {
            case MODE_SINE:
                for (uint32_t ch = 0; ch < n; ++ch) {
                    float v = 0.5f + 0.5f * (float)sin(t * 2.0 + ch * 0.3);
                    shm->peakLevel[ch] = v;
                    shm->rmsLevel[ch] = v * 0.7f;
                }
                break;
            case MODE_CLIP:
                for (uint32_t ch = 0; ch < n; ++ch) {
                    if (ch == 0) {
                        shm->peakLevel[ch] = 1.2f;
                        shm->rmsLevel[ch] = 0.9f;
                        shm->clipCount[ch]++;
                    } else {
                        shm->peakLevel[ch] = 0.f;
                        shm->rmsLevel[ch] = 0.f;
                    }
                }
                break;
            case MODE_SWEEP:
            default: {
                // One channel at a time, 0.5s each, -6 dBFS; everything else silent.
                uint32_t active = n > 0 ? ((uint32_t)(t / 0.5) % n) : 0;
                for (uint32_t ch = 0; ch < n; ++ch) {
                    float v = (ch == active) ? sweepPeak : 0.f;
                    shm->peakLevel[ch] = v;
                    shm->rmsLevel[ch] = v;
                }
                break;
            }
        }
        shm->updateCounter++;
        usleep(10000);
    }
}
