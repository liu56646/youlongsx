#include <sys/uio.h>
#include <unistd.h>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

static int faultMode = 0;
static ssize_t testPreadv(int fd, const iovec* vectors, int count, off_t offset) {
    if (faultMode == 1) {
        faultMode = 2;
        errno = EINTR;
        return -1;
    }
    if (faultMode == 2) {
        // Force partial reads both within a page and at page boundaries.
        iovec shortRead = vectors[0];
        if (shortRead.iov_len > 17) shortRead.iov_len = 17;
        return preadv(fd, &shortRead, 1, offset);
    }
    return preadv(fd, vectors, count, offset);
}
#define preadv testPreadv
#include "../scripts/qemu_patches/vmhost_snapshot_readv.h"
#undef preadv

static void require(bool ok) { if (!ok) std::abort(); }
int main() {
    FILE* file = tmpfile();
    require(file != nullptr);
    std::vector<unsigned char> source(4096 * 256 + 13);
    for (size_t i = 0; i < source.size(); ++i) source[i] = (i * 71 + i / 4096) & 255;
    require(fwrite(source.data(), 1, source.size(), file) == source.size());
    require(fflush(file) == 0);
    for (int fault : {0, 1}) {
        std::vector<std::vector<unsigned char>> pages(256,
                std::vector<unsigned char>(4098, 0xa5));
        iovec vectors[256];
        for (int i = 0; i < 256; ++i) vectors[i] = {pages[i].data() + 1, 4096};
        faultMode = fault;
        require(vmhostSnapshotReadv(fileno(file), vectors, 256, 13));
        for (int i = 0; i < 256; ++i) {
            require(pages[i].front() == 0xa5 && pages[i].back() == 0xa5);
            require(memcmp(pages[i].data() + 1, source.data() + 13 + i * 4096, 4096) == 0);
        }
    }
    unsigned char buffer[32];
    iovec beyondEof = {buffer, sizeof(buffer)};
    faultMode = 0;
    require(!vmhostSnapshotReadv(fileno(file), &beyondEof, 1, source.size() - 4));
    fclose(file);
    puts("PASS: scatter reads, EINTR, partial reads, guard bytes, truncated input");
}
