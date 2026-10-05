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

#ifndef __LOOP_DEVICE_H
#define __LOOP_DEVICE_H

/*
 * Bind a loop device to the file at `path`, or take the device already bound
 * to it, and return the device's number (/dev/loop<number>), or the negated
 * errno of the step that failed: EBUSY when a device is bound to part of the
 * file, EROFS when the device bound to it is read-only and `read_only` is 0.
 *
 * A device this binds reads and writes the file directly rather than through
 * the page cache, so a filesystem mounted from it caches its blocks once, and
 * it detaches itself once nothing holds it, so an unmount is all a release
 * takes. A read-only binding refuses writes at the device, and a file that
 * cannot be opened for writing is bound read-only.
 *
 * `held` receives a read-only descriptor on the device, which is what keeps
 * it bound until something else holds it: close it once the device is
 * mounted, or once mounting it has failed, which lets the device go.
 */
int loop_device_attach(const char *path, int read_only, int *held);

#endif /* __LOOP_DEVICE_H */
