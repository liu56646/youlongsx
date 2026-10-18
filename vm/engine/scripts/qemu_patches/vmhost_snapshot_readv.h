// Read a contiguous file extent into scattered guest pages. Keep retries here
// so short reads and EINTR have the same semantics as the scalar loader.
#pragma once
#include <cerrno>
#include <cstddef>
#include <sys/uio.h>
#include <unistd.h>

static inline bool vmhostSnapshotReadv(int fd, iovec* vectors, int count,
                                      off_t offset) {
    while (count > 0) {
        ssize_t got = preadv(fd, vectors, count, offset);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) return false;
        offset += got;
        while (count && size_t(got) >= vectors->iov_len) {
            got -= vectors->iov_len;
            ++vectors;
            --count;
        }
        if (count && got) {
            vectors->iov_base = static_cast<char*>(vectors->iov_base) + got;
            vectors->iov_len -= got;
        }
    }
    return true;
}
