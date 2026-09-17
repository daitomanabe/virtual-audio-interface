#include "include/audio_bridge.h"
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <string.h>
#include <stddef.h>

static VAIMeterShm *gShm = NULL;

bool abrOpen(void) {
    if (gShm) return true;
    int fd = shm_open(VAI_SHM_NAME, O_RDONLY, 0666);
    if (fd < 0) return false;
    void *p = mmap(NULL, sizeof(VAIMeterShm), PROT_READ, MAP_SHARED, fd, 0);
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
