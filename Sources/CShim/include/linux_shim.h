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

// The below fall into two main categories:
// 1. Aren't exposed by Swifts glibc modulemap.
// 2. Don't have syscall wrappers/definitions in glibc/musl.

#ifndef __LINUX_SHIM_H
#define __LINUX_SHIM_H

#if defined(__linux__)

#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <sys/swap.h>
#include <sys/vfs.h>

// Discard each swap page cluster as it is freed. The kernel keeps this flag
// out of its UAPI headers, so neither C library defines it and every caller
// declares it, as util-linux does:
// https://github.com/util-linux/util-linux/blob/8a937b74de272becd891fb0d1530fc5bb0514e7e/sys-utils/swapon.c
#ifndef SWAP_FLAG_DISCARD_PAGES
#define SWAP_FLAG_DISCARD_PAGES 0x40000
#endif

#endif /* __linux__ */

#endif /* __LINUX_SHIM_H */
