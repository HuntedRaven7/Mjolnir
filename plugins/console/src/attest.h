// SPDX-License-Identifier: Apache-2.0
#ifndef MJOLNIR_ATTEST_H
#define MJOLNIR_ATTEST_H

struct json_object;

/* Returns a json-c object describing the boot state. Caller owns the result. */
struct json_object *mjolnir_attestation(void);

#endif
