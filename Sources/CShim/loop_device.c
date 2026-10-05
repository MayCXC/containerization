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

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
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
 * The attachment is the one mount(8) makes for its `loop` option, backed the
 * way losetup's --direct-io=on backs a device: a free device from
 * loop-control, configured in one LOOP_CONFIGURE call with the file opened
 * O_DIRECT, its flags and its name.
 * https://github.com/util-linux/util-linux/blob/master/lib/loopdev.c
 *
 * A device marked to detach itself is cleared by the kernel at its last
 * close, so before the descriptors used to configure it are closed, a
 * read-only one is opened for the caller to hold until the mount does, as
 * libmount holds one: read-only, since the kernel can refuse writers to a
 * device being mounted.
 * https://github.com/util-linux/util-linux/blob/master/libmount/src/hook_loopdev.c
 */
int loop_device_attach(const char *path, int read_only, int *held) {
    *held = -1;
    int control = open("/dev/loop-control", O_RDWR | O_CLOEXEC);
    if (control < 0) {
        return -errno;
    }
    int number = ioctl(control, LOOP_CTL_GET_FREE);
    int saved = errno;
    close(control);
    if (number < 0) {
        return -saved;
    }

    int mode = read_only ? O_RDONLY : O_RDWR;
    char device[32];
    snprintf(device, sizeof device, "/dev/loop%d", number);
    int loop = open(device, mode | O_CLOEXEC);
    if (loop < 0 && errno == ENOENT) {
        /* A device node the kernel made but nothing populated yet. */
        if (mknod(device, S_IFBLK | 0600, makedev(7, number)) < 0 && errno != EEXIST) {
            return -errno;
        }
        loop = open(device, mode | O_CLOEXEC);
    }
    if (loop < 0) {
        return -errno;
    }

    int file = open(path, mode | O_DIRECT | O_CLOEXEC);
    if (file < 0) {
        saved = errno;
        close(loop);
        return -saved;
    }

    struct loop_config config;
    memset(&config, 0, sizeof config);
    config.fd = file;
    config.info.lo_flags = LO_FLAGS_AUTOCLEAR | LO_FLAGS_DIRECT_IO;
    if (read_only) {
        config.info.lo_flags |= LO_FLAGS_READ_ONLY;
    }
    strncpy((char *)config.info.lo_file_name, path, LO_NAME_SIZE - 1);

    int result = ioctl(loop, LOOP_CONFIGURE, &config);
    saved = errno;
    close(file);
    if (result < 0) {
        close(loop);
        return -saved;
    }

    int hold = open(device, O_RDONLY | O_CLOEXEC);
    saved = errno;
    close(loop);
    if (hold < 0) {
        return -saved;
    }
    *held = hold;
    return number;
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
