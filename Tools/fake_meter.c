// Writes synthetic per-channel peaks into the meter shared memory so the
// visualizer can be tested without installing the HAL plugin.
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
    shm->magic = VAI_SHM_MAGIC;
    shm->channelCount = VAI_MAX_CHANNELS;
    for (double t = 0;; t += 0.01) {
        for (int ch = 0; ch < VAI_MAX_CHANNELS; ++ch)
            shm->peakLevel[ch] = 0.5f + 0.5f * (float)sin(t * 2.0 + ch * 0.3);
        shm->updateCounter++;
        usleep(10000);
    }
}
