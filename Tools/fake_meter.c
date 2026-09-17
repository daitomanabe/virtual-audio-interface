// Writes synthetic per-channel peaks + plausible status values into the
// meter shared memory so the visualizer (including the Settings tab) can be
// tested without installing the HAL plugin. Also honors config writes from
// the app (requestedChannelCount) so the channel-count UI can be exercised
// without a real driver.
// Build: clang -o /tmp/fake_meter Tools/fake_meter.c   Run: /tmp/fake_meter
#include "../Shared/MeterShm.h"
#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

int main(void) {
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

        for (int ch = 0; ch < VAI_MAX_CHANNELS; ++ch)
            shm->peakLevel[ch] = 0.5f + 0.5f * (float)sin(t * 2.0 + ch * 0.3);
        shm->updateCounter++;
        usleep(10000);
    }
}
