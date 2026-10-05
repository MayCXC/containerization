/*
 * Copyright © 2026 Apple Inc. and the Containerization project authors.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#if defined(__linux__) && !defined(_GNU_SOURCE)
/* glibc declares O_DIRECT only for GNU sources. */
#define _GNU_SOURCE
#endif

#include "loop_device.h"

#if defined(__linux__)

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

/*
 * The loop driver's interface, as the kernel declares it in its UAPI header
 * <linux/loop.h>, which the static Linux SDK this is built with does not
 * carry.
 * https://github.com/torvalds/linux/blob/master/include/uapi/linux/loop.h
 */
#define LO_NAME_SIZE 64
#define LO_KEY_SIZE 32
#define LO_FLAGS_READ_ONLY 1
#define LO_FLAGS_AUTOCLEAR 4
#define LO_FLAGS_DIRECT_IO 16
#define LOOP_GET_STATUS64 0x4C05
#define LOOP_CONFIGURE 0x4C0A
#define LOOP_CTL_GET_FREE 0x4C82

struct loop_info64 {
    uint64_t lo_device;
    uint64_t lo_inode;
    uint64_t lo_rdevice;
    uint64_t lo_offset;
    uint64_t lo_sizelimit;
    uint32_t lo_number;
    uint32_t lo_encrypt_type;
    uint32_t lo_encrypt_key_size;
    uint32_t lo_flags;
    uint8_t lo_file_name[LO_NAME_SIZE];
    uint8_t lo_crypt_name[LO_NAME_SIZE];
    uint8_t lo_encrypt_key[LO_KEY_SIZE];
    uint64_t lo_init[2];
};

struct loop_config {
    uint32_t fd;
    uint32_t block_size;
    struct loop_info64 info;
    uint64_t __reserved[8];
};

/*
 * util-linux's waits: a device node is opened again 25 ms apart, 16 times,
 * while it is missing or refuses us, as it does before udev has made it or
 * handed it over; an ioctl that answers EAGAIN is repeated 250 ms apart, 10
 * times (repeat_on_eagain, LOOPDEV_MAX_TRIES).
 * https://github.com/util-linux/util-linux/blob/master/lib/loopdev.c
 */
#define DEVICE_OPEN_TRIES 16
#define DEVICE_OPEN_WAIT_MS 25
#define EAGAIN_TRIES 10
#define EAGAIN_WAIT_MS 250

static void wait_ms(long ms) {
    struct timespec wait = {.tv_sec = ms / 1000, .tv_nsec = (ms % 1000) * 1000000L};
    while (nanosleep(&wait, &wait) < 0 && errno == EINTR) {
    }
}

static int open_device(const char *device, int mode) {
    int tries = 0;
    for (;;) {
        int fd = open(device, mode | O_CLOEXEC);
        if (fd >= 0 || (errno != EACCES && errno != ENOENT) || tries++ >= DEVICE_OPEN_TRIES) {
            return fd;
        }
        wait_ms(DEVICE_OPEN_WAIT_MS);
    }
}

static int configure(int loop, struct loop_config *config) {
    int tries = 0;
    for (;;) {
        int result = ioctl(loop, LOOP_CONFIGURE, config);
        if (result == 0 || errno != EAGAIN || tries++ >= EAGAIN_TRIES) {
            return result;
        }
        wait_ms(EAGAIN_WAIT_MS);
    }
}

/*
 * The device already bound to the file `st` describes, found the way
 * libmount's loopcxt_find_overlap finds one: among the devices sysfs shows a
 * backing file for, the one whose binding, read with LOOP_GET_STATUS64 on a
 * descriptor that keeps it from detaching meanwhile, names the file's device
 * and inode.
 * https://github.com/util-linux/util-linux/blob/master/lib/loopdev.c
 *
 * Returns 0 with `*number` the device's and `*held` open on it, or with
 * `*number` -1 when no device is bound to the file; or a negated errno:
 * -EBUSY for a device bound to part of the file, which libmount refuses to
 * mount a second time, and -EROFS for a read-only device asked to be
 * written.
 */
static int find_bound(const struct stat *st, int read_only, int *number, int *held) {
    *number = -1;
    DIR *block = opendir("/sys/block");
    if (block == NULL) {
        return -errno;
    }
    int result = 0;
    struct dirent *entry;
    while ((entry = readdir(block)) != NULL) {
        if (strncmp(entry->d_name, "loop", 4) != 0) {
            continue;
        }
        char *end = NULL;
        long candidate = strtol(entry->d_name + 4, &end, 10);
        if (end == entry->d_name + 4 || *end != '\0') {
            continue;
        }
        char backing[320];
        snprintf(backing, sizeof backing, "/sys/block/%s/loop/backing_file", entry->d_name);
        if (access(backing, F_OK) != 0) {
            continue;
        }
        char device[32];
        snprintf(device, sizeof device, "/dev/%s", entry->d_name);
        int fd = open(device, O_RDONLY | O_CLOEXEC);
        if (fd < 0) {
            /* Racing the device's own detach: libmount passes it over. */
            continue;
        }
        struct loop_info64 info;
        if (ioctl(fd, LOOP_GET_STATUS64, &info) < 0 || info.lo_device != (uint64_t)st->st_dev || info.lo_inode != (uint64_t)st->st_ino) {
            close(fd);
            continue;
        }
        if (info.lo_offset != 0 || info.lo_sizelimit != 0) {
            close(fd);
            result = -EBUSY;
            break;
        }
        if ((info.lo_flags & LO_FLAGS_READ_ONLY) && !read_only) {
            close(fd);
            result = -EROFS;
            break;
        }
        *held = fd;
        *number = (int)candidate;
        break;
    }
    closedir(block);
    return result;
}

/*
 * The attachment is the one mount(8) makes for its `loop` option. A device
 * already bound to the file is taken as it is, since the kernel cannot tell
 * two devices on one file from two disks, and a filesystem mounted from
 * both would be two filesystems writing one image; libmount recycles the
 * device for that reason.
 * https://github.com/util-linux/util-linux/blob/master/libmount/src/hook_loopdev.c
 *
 * Otherwise a free device from loop-control is backed the way losetup's
 * --direct-io=on backs one, configured in one LOOP_CONFIGURE call with the
 * file opened O_DIRECT, its flags and its name. A device another binding
 * takes between its finding and its configuring answers EBUSY, and a fresh
 * one is found, as libmount does.
 * https://github.com/util-linux/util-linux/blob/master/lib/loopdev.c
 *
 * A device marked to detach itself is cleared by the kernel at its last
 * close, so before the descriptors used to configure it are closed, a
 * read-only one is opened for the caller to hold until the mount does, as
 * libmount holds one: read-only, since the kernel can refuse writers to a
 * device being mounted.
 */
int loop_device_attach(const char *path, int read_only, int *held) {
    *held = -1;
    struct stat st;
    if (stat(path, &st) < 0) {
        return -errno;
    }
    int bound = -1;
    int found = find_bound(&st, read_only, &bound, held);
    if (found < 0) {
        return found;
    }
    if (bound >= 0) {
        return bound;
    }

    /* A file that cannot be opened for writing backs a read-only device, as
     * losetup's does. */
    int mode = read_only ? O_RDONLY : O_RDWR;
    int file = open(path, mode | O_DIRECT | O_CLOEXEC);
    if (file < 0 && mode != O_RDONLY && (errno == EROFS || errno == EACCES)) {
        mode = O_RDONLY;
        file = open(path, mode | O_DIRECT | O_CLOEXEC);
    }
    if (file < 0) {
        return -errno;
    }

    int saved;
    for (;;) {
        int control = open("/dev/loop-control", O_RDWR | O_CLOEXEC);
        if (control < 0) {
            saved = errno;
            break;
        }
        int number = ioctl(control, LOOP_CTL_GET_FREE);
        saved = errno;
        close(control);
        if (number < 0) {
            break;
        }

        char device[32];
        snprintf(device, sizeof device, "/dev/loop%d", number);
        int loop = open_device(device, mode);
        if (loop < 0) {
            saved = errno;
            break;
        }

        struct loop_config config;
        memset(&config, 0, sizeof config);
        config.fd = (uint32_t)file;
        config.info.lo_flags = LO_FLAGS_AUTOCLEAR | LO_FLAGS_DIRECT_IO;
        if (mode == O_RDONLY) {
            config.info.lo_flags |= LO_FLAGS_READ_ONLY;
        }
        strncpy((char *)config.info.lo_file_name, path, LO_NAME_SIZE - 1);

        if (configure(loop, &config) < 0) {
            saved = errno;
            close(loop);
            if (saved == EBUSY) {
                continue;
            }
            break;
        }

        int hold = open(device, O_RDONLY | O_CLOEXEC);
        saved = errno;
        close(loop);
        close(file);
        if (hold < 0) {
            return -saved;
        }
        *held = hold;
        return number;
    }
    close(file);
    return -saved;
}

#else

#include <errno.h>

int loop_device_attach(const char *path, int read_only, int *held) {
    (void)path;
    (void)read_only;
    *held = -1;
    return -ENOSYS;
}

#endif /* __linux__ */
