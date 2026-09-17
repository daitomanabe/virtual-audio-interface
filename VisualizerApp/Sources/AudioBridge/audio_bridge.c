#include "include/audio_bridge.h"
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <string.h>
#include <stddef.h>

static VAIMeterShm *gShm = NULL;

bool abrOpen(void) {
    if (gShm) return true;
    // O_RDWR: the app also writes the config half (see abrWriteConfig).
    int fd = shm_open(VAI_SHM_NAME, O_RDWR, 0666);
    if (fd < 0) return false;
    void *p = mmap(NULL, sizeof(VAIMeterShm), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED) return false;
    VAIMeterShm *shm = (VAIMeterShm *)p;
    if (shm->magic != VAI_SHM_MAGIC) {
        munmap(p, sizeof(VAIMeterShm));
        return false;
    }
    gShm = shm;
    return true;
}

void abrClose(void) {
    if (gShm) {
        munmap(gShm, sizeof(VAIMeterShm));
        gShm = NULL;
    }
}

uint32_t abrReadLevels(float *outLevels, uint32_t maxOut) {
    if (!gShm && !abrOpen()) return 0;
    uint32_t n = gShm->channelCount;
    if (n > maxOut) n = maxOut;
    if (n > VAI_MAX_CHANNELS) n = VAI_MAX_CHANNELS;
    memcpy(outLevels, gShm->peakLevel, sizeof(float) * n);
    return n;
}

bool abrReadStatus(VAIStatus *outStatus) {
    if (!outStatus) return false;
    if (!gShm && !abrOpen()) return false;
    outStatus->channelCount = gShm->channelCount;
    outStatus->sampleRate = gShm->sampleRate;
    outStatus->ioBufferFrameSize = gShm->ioBufferFrameSize;
    outStatus->isRunning = gShm->isRunning;
    outStatus->clientCount = gShm->clientCount;
    outStatus->zeroTimeStampPeriod = gShm->zeroTimeStampPeriod;
    outStatus->hostRequestedSampleRate = gShm->hostRequestedSampleRate;
    outStatus->updateCounter = gShm->updateCounter;
    outStatus->configAppliedCounter = gShm->configAppliedCounter;
    outStatus->configCounter = gShm->configCounter;
    return true;
}

bool abrWriteConfig(uint32_t channelCount, double sampleRate) {
    if (!gShm && !abrOpen()) return false;
    gShm->requestedChannelCount = channelCount;
    gShm->requestedSampleRate = sampleRate;
    gShm->configCounter++;
    return true;
}
